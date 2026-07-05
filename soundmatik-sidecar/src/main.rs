// soundMatik sidecar — local helper server for the soundMatik Premiere Pro UXP panel.
//
// The UXP sandbox cannot spawn processes or write outside its virtual filesystem,
// so this small HTTP server (127.0.0.1 only) does the real work: it runs the
// bundled yt-dlp (+ ffmpeg + deno) to extract audio from a video URL and writes
// the result into the Premiere project's SOUND_EFFECTS folder.
//
// Endpoints:
//   GET  /health          -> { ok, version, binaries }
//   POST /download        -> { jobId }         body: { url, format: "wav"|"mp3", targetFolder }
//   GET  /status/{jobId}  -> { state, progress?, filePath?, fileName?, error? }
//
// Release builds have no console window (launched invisibly from the panel);
// diagnostics go to soundmatik-sidecar.log next to the executable.

#![cfg_attr(
    all(target_os = "windows", not(debug_assertions)),
    windows_subsystem = "windows"
)]

use std::collections::HashMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

use axum::extract::{Path as AxPath, State};
use axum::http::StatusCode;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, BufReader};

const PORT: u16 = 41320;
const DEFAULT_IDLE_EXIT_SECS: u64 = 15 * 60;

fn idle_exit_secs() -> u64 {
    std::env::var("SOUNDMATIK_IDLE_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(DEFAULT_IDLE_EXIT_SECS)
}
const STALE_TMP_MAX_AGE_SECS: u64 = 24 * 60 * 60;

// ---------------------------------------------------------------------------
// Logging (release builds are windowless, so a log file is the only trace)

static LOG_FILE: OnceLock<Option<Mutex<std::fs::File>>> = OnceLock::new();

fn init_log(exe_dir: &Path) {
    let path = exe_dir.join("soundmatik-sidecar.log");
    let file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .ok()
        .map(Mutex::new);
    let _ = LOG_FILE.set(file);
}

fn log(msg: &str) {
    let stamp = chrono::Local::now().format("%Y-%m-%d %H:%M:%S");
    let line = format!("[{stamp}] {msg}");
    eprintln!("{line}");
    if let Some(Some(file)) = LOG_FILE.get().map(|f| f.as_ref()) {
        if let Ok(mut f) = file.lock() {
            let _ = writeln!(f, "{line}");
        }
    }
}

// ---------------------------------------------------------------------------
// State

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct JobStatus {
    state: String, // downloading | converting | done | error
    #[serde(skip_serializing_if = "Option::is_none")]
    progress: Option<f32>, // download percent 0..100 while downloading
    #[serde(skip_serializing_if = "Option::is_none")]
    file_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    file_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

struct AppState {
    jobs: Mutex<HashMap<String, JobStatus>>,
    active_jobs: AtomicUsize,
    job_counter: AtomicU64,
    last_activity: Mutex<Instant>,
    bin_dir: PathBuf,
}

impl AppState {
    fn touch(&self) {
        *self.last_activity.lock().unwrap() = Instant::now();
    }
    fn idle_secs(&self) -> u64 {
        self.last_activity.lock().unwrap().elapsed().as_secs()
    }
    fn set_job(&self, id: &str, status: JobStatus) {
        self.jobs.lock().unwrap().insert(id.to_string(), status);
    }
    fn update_job(&self, id: &str, f: impl FnOnce(&mut JobStatus)) {
        if let Some(job) = self.jobs.lock().unwrap().get_mut(id) {
            f(job);
        }
    }
}

// ---------------------------------------------------------------------------
// Binary resolution

#[cfg(target_os = "windows")]
const PLATFORM_BIN_SUBDIR: &str = "win";
#[cfg(not(target_os = "windows"))]
const PLATFORM_BIN_SUBDIR: &str = "mac";

#[cfg(target_os = "windows")]
const YTDLP_NAME: &str = "yt-dlp.exe";
#[cfg(not(target_os = "windows"))]
const YTDLP_NAME: &str = "yt-dlp";

#[cfg(target_os = "windows")]
const FFMPEG_NAME: &str = "ffmpeg.exe";
#[cfg(not(target_os = "windows"))]
const FFMPEG_NAME: &str = "ffmpeg";

#[cfg(target_os = "windows")]
const DENO_NAME: &str = "deno.exe";
#[cfg(not(target_os = "windows"))]
const DENO_NAME: &str = "deno";

/// Locate the platform bin dir (containing yt-dlp/ffmpeg/deno). Honors the
/// SOUNDMATIK_BIN_DIR env override, otherwise walks up from the executable
/// so both `target/release/soundmatik-sidecar` and a flat deploy layout work.
fn resolve_bin_dir(exe_dir: &Path) -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("SOUNDMATIK_BIN_DIR") {
        let p = PathBuf::from(dir);
        if p.join(YTDLP_NAME).is_file() {
            return Some(p);
        }
    }
    let mut cursor = Some(exe_dir);
    for _ in 0..5 {
        let dir = cursor?;
        // Flat/dev layout: <dir>/bin/<platform>/
        let candidate = dir.join("bin").join(PLATFORM_BIN_SUBDIR);
        if candidate.join(YTDLP_NAME).is_file() {
            return Some(candidate);
        }
        // macOS .app bundle: exe is in Contents/MacOS/, binaries in
        // Contents/Resources/bin/mac/ — check the sibling Resources dir.
        let resources = dir.join("Resources").join("bin").join(PLATFORM_BIN_SUBDIR);
        if resources.join(YTDLP_NAME).is_file() {
            return Some(resources);
        }
        cursor = dir.parent();
    }
    None
}

// ---------------------------------------------------------------------------
// Filename handling

/// Defensive sanitize on top of yt-dlp's --windows-filenames.
fn sanitize_file_stem(stem: &str) -> String {
    let mut out: String = stem
        .chars()
        .map(|c| match c {
            '<' | '>' | ':' | '"' | '/' | '\\' | '|' | '?' | '*' => '_',
            c if (c as u32) < 0x20 => '_',
            c => c,
        })
        .collect();
    out = out.trim().trim_end_matches(['.', ' ']).to_string();

    // Windows reserved device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9)
    let upper = out.to_ascii_uppercase();
    let reserved = matches!(upper.as_str(), "CON" | "PRN" | "AUX" | "NUL")
        || (upper.len() == 4
            && (upper.starts_with("COM") || upper.starts_with("LPT"))
            && upper.chars().nth(3).is_some_and(|c| c.is_ascii_digit()));
    if reserved {
        out.insert(0, '_');
    }
    if out.is_empty() {
        out = "audio".to_string();
    }
    out
}

/// `name.ext`, or `name (2).ext`, `name (3).ext`... if already taken.
fn unique_target_path(dir: &Path, stem: &str, ext: &str) -> PathBuf {
    let first = dir.join(format!("{stem}.{ext}"));
    if !first.exists() {
        return first;
    }
    for n in 2..1000 {
        let candidate = dir.join(format!("{stem} ({n}).{ext}"));
        if !candidate.exists() {
            return candidate;
        }
    }
    dir.join(format!("{stem} ({}).{ext}", std::process::id()))
}

fn sweep_stale_tmp_dirs(target: &Path) {
    let Ok(entries) = std::fs::read_dir(target) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if !name.starts_with(".soundmatik-tmp-") {
            continue;
        }
        let age_ok = entry
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| SystemTime::now().duration_since(t).ok())
            .map(|age| age.as_secs() > STALE_TMP_MAX_AGE_SECS)
            .unwrap_or(true);
        if age_ok {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
}

// ---------------------------------------------------------------------------
// Error classification

fn friendly_error(exit_note: &str, tail: &[String]) -> String {
    let joined = tail.join("\n");
    let lower = joined.to_lowercase();

    let hint = if lower.contains("unsupported url") || lower.contains("is not a valid url") {
        "This link isn't a downloadable video URL (yt-dlp doesn't support it)."
    } else if lower.contains("video unavailable") || lower.contains("this video is not available")
    {
        "The video is unavailable (removed, region-locked, or wrong link)."
    } else if lower.contains("private video") || lower.contains("sign in") || lower.contains("login required")
    {
        "The video requires a sign-in / is private, so it can't be downloaded."
    } else if lower.contains("live event") || lower.contains("is live") || lower.contains("premieres in")
    {
        "The video is a live stream or premiere that hasn't finished — try again once it's a normal video."
    } else if lower.contains("getaddrinfo")
        || lower.contains("unable to download")
        || lower.contains("timed out")
        || lower.contains("connection")
    {
        "Network problem while downloading — check your internet connection and try again."
    } else if lower.contains("ffmpeg") && lower.contains("not found") {
        "Bundled ffmpeg was not found — re-run the fetch-binaries script."
    } else {
        "Download failed."
    };

    // Last yt-dlp ERROR line is usually the most specific message.
    let detail = tail
        .iter()
        .rev()
        .find(|l| l.contains("ERROR"))
        .cloned()
        .unwrap_or_else(|| tail.last().cloned().unwrap_or_else(|| exit_note.to_string()));

    format!("{hint} [{detail}]")
}

// ---------------------------------------------------------------------------
// Job pipeline

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DownloadReq {
    url: String,
    format: String,
    target_folder: String,
}

async fn run_job(state: Arc<AppState>, job_id: String, req: DownloadReq) {
    state.active_jobs.fetch_add(1, Ordering::SeqCst);
    let result = run_pipeline(&state, &job_id, &req).await;
    match result {
        Ok((path, name)) => {
            log(&format!("job {job_id}: done -> {}", path.display()));
            state.set_job(
                &job_id,
                JobStatus {
                    state: "done".into(),
                    progress: Some(100.0),
                    file_path: Some(path.to_string_lossy().to_string()),
                    file_name: Some(name),
                    error: None,
                },
            );
        }
        Err(msg) => {
            log(&format!("job {job_id}: error -> {msg}"));
            state.set_job(
                &job_id,
                JobStatus {
                    state: "error".into(),
                    progress: None,
                    file_path: None,
                    file_name: None,
                    error: Some(msg),
                },
            );
        }
    }
    state.active_jobs.fetch_sub(1, Ordering::SeqCst);
    state.touch();
}

async fn run_pipeline(
    state: &Arc<AppState>,
    job_id: &str,
    req: &DownloadReq,
) -> Result<(PathBuf, String), String> {
    let target = PathBuf::from(&req.target_folder);
    std::fs::create_dir_all(&target)
        .map_err(|e| format!("Could not create target folder {}: {e}", target.display()))?;
    sweep_stale_tmp_dirs(&target);

    let tmp_dir = target.join(format!(".soundmatik-tmp-{job_id}"));
    std::fs::create_dir_all(&tmp_dir)
        .map_err(|e| format!("Could not create temp folder: {e}"))?;

    let outcome = run_ytdlp(state, job_id, req, &tmp_dir).await;
    let result = match outcome {
        Ok(()) => finalize_output(&tmp_dir, &target, &req.format),
        Err(e) => Err(e),
    };
    let _ = std::fs::remove_dir_all(&tmp_dir);
    result
}

async fn run_ytdlp(
    state: &Arc<AppState>,
    job_id: &str,
    req: &DownloadReq,
    tmp_dir: &Path,
) -> Result<(), String> {
    let bin_dir = &state.bin_dir;
    let ytdlp = bin_dir.join(YTDLP_NAME);
    let bin_dir_str = bin_dir.to_string_lossy().to_string();

    let mut cmd = tokio::process::Command::new(&ytdlp);
    // --no-playlist only applies to video+list URLs; --playlist-items 1 is the
    // backstop so a pure playlist URL can't trigger a bulk download.
    cmd.arg("--no-playlist")
        .arg("--playlist-items")
        .arg("1")
        .arg("--newline")
        .arg("--windows-filenames")
        .arg("--ffmpeg-location")
        .arg(&bin_dir_str)
        .arg("--js-runtimes")
        .arg(format!("deno:{bin_dir_str}"))
        .arg("-f")
        .arg("bestaudio/best")
        .arg("--extract-audio")
        .arg("--audio-format")
        .arg(&req.format);
    if req.format == "mp3" {
        cmd.arg("--audio-quality").arg("192K");
    }
    cmd.arg("--output")
        .arg("%(title).180B.%(ext)s")
        .arg("--paths")
        .arg(tmp_dir)
        .arg("--")
        .arg(&req.url);

    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    #[cfg(target_os = "windows")]
    cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW: no console flash, inherited by ffmpeg/deno children

    log(&format!("job {job_id}: yt-dlp start, url={} format={}", req.url, req.format));

    let mut child = cmd
        .spawn()
        .map_err(|e| format!("Could not start bundled yt-dlp ({}): {e}", ytdlp.display()))?;

    let stdout = child.stdout.take().expect("stdout piped");
    let stderr = child.stderr.take().expect("stderr piped");

    // stderr: collect a rolling tail for error reporting
    let stderr_task = tokio::spawn(async move {
        let mut tail: Vec<String> = Vec::new();
        let mut lines = BufReader::new(stderr).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if tail.len() >= 40 {
                tail.remove(0);
            }
            tail.push(line);
        }
        tail
    });

    // stdout: parse progress -> job state. Hard time limit so a wedged
    // yt-dlp/ffmpeg can't pin the job as "active" forever (which would also
    // block the idle-exit watchdog).
    let mut stdout_tail: Vec<String> = Vec::new();
    let run = async {
        let mut lines = BufReader::new(stdout).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if stdout_tail.len() >= 40 {
                stdout_tail.remove(0);
            }
            stdout_tail.push(line.clone());

            if line.starts_with("[download]") {
                if let Some(pct) = parse_download_percent(&line) {
                    state.update_job(job_id, |j| {
                        j.state = "downloading".into();
                        j.progress = Some(pct);
                    });
                }
            } else if line.starts_with("[ExtractAudio]") || line.starts_with("[Fixup") {
                state.update_job(job_id, |j| {
                    j.state = "converting".into();
                    j.progress = None;
                });
            }
        }
        child.wait().await
    };
    let status = match tokio::time::timeout(Duration::from_secs(60 * 60), run).await {
        Ok(res) => res.map_err(|e| format!("yt-dlp process error: {e}"))?,
        Err(_elapsed) => {
            let _ = child.kill().await;
            return Err(
                "Download ran for over an hour and was cancelled — try a shorter video or check your connection."
                    .to_string(),
            );
        }
    };
    let stderr_tail = stderr_task.await.unwrap_or_default();

    if !status.success() {
        let mut tail = stdout_tail;
        tail.extend(stderr_tail);
        let code = status.code().map(|c| c.to_string()).unwrap_or_else(|| "?".into());
        return Err(friendly_error(&format!("yt-dlp exited with code {code}"), &tail));
    }

    // Download finished; conversion (if any) already happened inside yt-dlp.
    state.update_job(job_id, |j| {
        if j.state == "downloading" {
            j.state = "converting".into();
            j.progress = None;
        }
    });
    Ok(())
}

fn parse_download_percent(line: &str) -> Option<f32> {
    // e.g. "[download]  42.7% of    3.52MiB at  1.21MiB/s ETA 00:02"
    let after = line.strip_prefix("[download]")?.trim_start();
    let pct_str = after.split('%').next()?.trim();
    pct_str.parse::<f32>().ok().filter(|p| (0.0..=100.0).contains(p))
}

/// Move the produced audio file from the temp dir into the target folder,
/// deduplicating the name with a numeric suffix instead of overwriting.
fn finalize_output(tmp_dir: &Path, target: &Path, format: &str) -> Result<(PathBuf, String), String> {
    let entries = std::fs::read_dir(tmp_dir)
        .map_err(|e| format!("Could not read temp folder: {e}"))?
        .flatten()
        .filter(|e| e.path().is_file())
        .collect::<Vec<_>>();

    let produced = entries
        .iter()
        .find(|e| {
            e.path()
                .extension()
                .map(|x| x.to_string_lossy().eq_ignore_ascii_case(format))
                .unwrap_or(false)
        })
        .or_else(|| entries.first())
        .ok_or_else(|| "yt-dlp finished but produced no output file.".to_string())?;

    let produced_path = produced.path();
    let stem = produced_path
        .file_stem()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| "audio".to_string());
    let stem = sanitize_file_stem(&stem);
    let ext = produced_path
        .extension()
        .map(|x| x.to_string_lossy().to_lowercase())
        .unwrap_or_else(|| format.to_string());

    // Two same-titled jobs can finish at once: rename fails if the freshly
    // recomputed unique name got taken in between, so retry with a new name
    // rather than ever overwriting anything.
    let mut last_err: Option<std::io::Error> = None;
    for _ in 0..25 {
        let dest = unique_target_path(target, &stem, &ext);
        match std::fs::rename(&produced_path, &dest) {
            Ok(()) => {
                let name = file_name_of(&dest, &stem, &ext);
                return Ok((dest, name));
            }
            Err(e) => {
                if dest.exists() {
                    // lost the name race — loop recomputes a free name
                    continue;
                }
                last_err = Some(e);
                break;
            }
        }
    }

    // Fallback for setups where rename fails outright (e.g. cross-mount):
    // copy with create_new so a race still can't clobber an existing file.
    for _ in 0..25 {
        let dest = unique_target_path(target, &stem, &ext);
        match copy_no_overwrite(&produced_path, &dest) {
            Ok(()) => {
                let _ = std::fs::remove_file(&produced_path);
                let name = file_name_of(&dest, &stem, &ext);
                return Ok((dest, name));
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => {
                return Err(format!(
                    "Could not move file into {}: {e} (earlier rename error: {:?})",
                    target.display(),
                    last_err
                ))
            }
        }
    }
    Err(format!(
        "Could not find a free filename for \"{stem}.{ext}\" in {}",
        target.display()
    ))
}

fn file_name_of(dest: &Path, stem: &str, ext: &str) -> String {
    dest.file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| format!("{stem}.{ext}"))
}

fn copy_no_overwrite(src: &Path, dest: &Path) -> std::io::Result<()> {
    let mut out = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(dest)?;
    let mut inp = std::fs::File::open(src)?;
    std::io::copy(&mut inp, &mut out)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// HTTP handlers

async fn health(State(state): State<Arc<AppState>>) -> Json<Value> {
    state.touch();
    let bin = &state.bin_dir;
    Json(json!({
        "ok": true,
        "service": "soundmatik-sidecar",
        "version": env!("CARGO_PKG_VERSION"),
        "binDir": bin.to_string_lossy(),
        "binaries": {
            "ytDlp": bin.join(YTDLP_NAME).is_file(),
            "ffmpeg": bin.join(FFMPEG_NAME).is_file(),
            "deno": bin.join(DENO_NAME).is_file(),
        }
    }))
}

async fn post_download(
    State(state): State<Arc<AppState>>,
    Json(req): Json<DownloadReq>,
) -> (StatusCode, Json<Value>) {
    state.touch();

    let url = req.url.trim().to_string();
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "Please paste a full http(s) video URL." })),
        );
    }
    if req.format != "wav" && req.format != "mp3" {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "format must be \"wav\" or \"mp3\"" })),
        );
    }
    if !Path::new(&req.target_folder).is_absolute() {
        return (
            StatusCode::BAD_REQUEST,
            Json(json!({ "error": "targetFolder must be an absolute path" })),
        );
    }
    if !state.bin_dir.join(YTDLP_NAME).is_file() {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(json!({ "error": "Bundled yt-dlp not found — run the fetch-binaries script, then try again." })),
        );
    }

    let n = state.job_counter.fetch_add(1, Ordering::SeqCst);
    let job_id = format!("job-{}-{n}", std::process::id());
    state.set_job(
        &job_id,
        JobStatus {
            state: "downloading".into(),
            progress: None,
            file_path: None,
            file_name: None,
            error: None,
        },
    );

    let req = DownloadReq { url, ..req };
    tokio::spawn(run_job(state.clone(), job_id.clone(), req));

    (StatusCode::OK, Json(json!({ "jobId": job_id })))
}

async fn get_status(
    State(state): State<Arc<AppState>>,
    AxPath(job_id): AxPath<String>,
) -> (StatusCode, Json<Value>) {
    state.touch();
    match state.jobs.lock().unwrap().get(&job_id) {
        Some(job) => (StatusCode::OK, Json(serde_json::to_value(job).unwrap())),
        None => (
            StatusCode::NOT_FOUND,
            Json(json!({ "error": format!("unknown job id {job_id}") })),
        ),
    }
}

// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() {
    let exe_dir = std::env::current_exe()
        .ok()
        .and_then(|p| p.parent().map(|d| d.to_path_buf()))
        .unwrap_or_else(|| PathBuf::from("."));
    init_log(&exe_dir);

    let bin_dir = match resolve_bin_dir(&exe_dir) {
        Some(dir) => dir,
        None => {
            // Still start the server so the panel gets a useful /health answer;
            // /download reports the missing binaries explicitly.
            log("WARNING: bin/<platform>/yt-dlp not found near the executable — run scripts/fetch-binaries");
            exe_dir.join("bin").join(PLATFORM_BIN_SUBDIR)
        }
    };

    let listener = match tokio::net::TcpListener::bind(("127.0.0.1", PORT)).await {
        Ok(l) => l,
        Err(e) if e.kind() == std::io::ErrorKind::AddrInUse => {
            log(&format!(
                "port {PORT} already in use — another soundmatik-sidecar is running, exiting quietly"
            ));
            return;
        }
        Err(e) => {
            log(&format!("FATAL: could not bind 127.0.0.1:{PORT}: {e}"));
            std::process::exit(1);
        }
    };

    log(&format!(
        "soundmatik-sidecar v{} listening on 127.0.0.1:{PORT}, bin dir: {}",
        env!("CARGO_PKG_VERSION"),
        bin_dir.display()
    ));

    let state = Arc::new(AppState {
        jobs: Mutex::new(HashMap::new()),
        active_jobs: AtomicUsize::new(0),
        job_counter: AtomicU64::new(1),
        last_activity: Mutex::new(Instant::now()),
        bin_dir,
    });

    // Idle watchdog: exit once nothing has happened for the idle timeout and no
    // job is running. The panel relaunches the sidecar on demand.
    {
        let state = state.clone();
        let idle_limit = idle_exit_secs();
        let check_every = (idle_limit / 4).clamp(5, 60);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(check_every)).await;
                let active = state.active_jobs.load(Ordering::SeqCst);
                if active == 0 && state.idle_secs() >= idle_limit {
                    log("idle timeout reached, exiting");
                    std::process::exit(0);
                }
            }
        });
    }

    let app = Router::new()
        .route("/health", get(health))
        .route("/download", post(post_download))
        .route("/status/{job_id}", get(get_status))
        .with_state(state);

    if let Err(e) = axum::serve(listener, app).await {
        log(&format!("server error: {e}"));
    }
}
