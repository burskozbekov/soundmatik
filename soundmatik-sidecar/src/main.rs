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
    // macOS: the exe lives inside the signed .app bundle — writing a log next
    // to it would modify the bundle after signing (breaking strict codesign /
    // Gatekeeper re-validation), so log under ~/Library/Logs instead.
    #[cfg(target_os = "macos")]
    let path = {
        let dir = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| exe_dir.to_path_buf())
            .join("Library/Logs/soundMatik");
        let _ = std::fs::create_dir_all(&dir);
        dir.join("soundmatik-sidecar.log")
    };
    #[cfg(not(target_os = "macos"))]
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
    speed: Option<String>, // transfer rate, e.g. "5.2MiB/s"
    #[serde(skip_serializing_if = "Option::is_none")]
    total: Option<String>, // total size, e.g. "3.52MiB"
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
            // If we can't determine the age, KEEP it — never risk deleting a
            // concurrent in-flight job's temp dir.
            .unwrap_or(false);
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
    } else if lower.contains("no space left") || lower.contains("disk full") {
        "The disk is full — free up space on the drive that holds your project, then try again."
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

/// Decrements active_jobs on drop so a panic anywhere in run_job can't leak the
/// count — a leaked count would keep active_jobs >= 1 forever, so the idle
/// watchdog never fires, the process never exits, and it holds port 41320
/// (relaunches then quietly exit and the panel silently can't work).
struct ActiveJobGuard<'a>(&'a AtomicUsize);
impl Drop for ActiveJobGuard<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

async fn run_job(state: Arc<AppState>, job_id: String, req: DownloadReq) {
    state.active_jobs.fetch_add(1, Ordering::SeqCst);
    let _active = ActiveJobGuard(&state.active_jobs);
    let result = run_pipeline(&state, &job_id, &req).await;
    match result {
        Ok((path, name)) => {
            log(&format!("job {job_id}: done -> {}", path.display()));
            state.set_job(
                &job_id,
                JobStatus {
                    state: "done".into(),
                    progress: Some(100.0),
                    speed: None,
                    total: None,
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
                    speed: None,
                    total: None,
                    file_path: None,
                    file_name: None,
                    error: Some(msg),
                },
            );
        }
    }
    state.touch();
    // _active (ActiveJobGuard) drops here, decrementing active_jobs even on panic.
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
                let rest = line["[download]".len()..].trim_start();
                if let Some((pct, size, rate)) = parse_download_progress(rest) {
                    state.update_job(job_id, |j| {
                        j.state = "downloading".into();
                        j.progress = Some(pct);
                        j.speed = rate.clone();
                        j.total = size.clone();
                    });
                }
            } else if line.starts_with("[ExtractAudio]") || line.starts_with("[Fixup") {
                state.update_job(job_id, |j| {
                    j.state = "converting".into();
                    j.progress = None;
                    j.speed = None;
                    j.total = None;
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
            j.speed = None;
            j.total = None;
        }
    });
    Ok(())
}

/// Parse the tail of a "[download] ..." progress line (prefix already removed),
/// e.g. " 42.7% of    3.52MiB at    1.21MiB/s ETA 00:02"
///   or "100% of 3.52MiB in 00:00:02 at 1.5MiB/s".
/// Returns (percent, total size like "3.52MiB", transfer rate like "1.21MiB/s").
fn parse_download_progress(rest: &str) -> Option<(f32, Option<String>, Option<String>)> {
    let pct_str = rest.split('%').next()?.trim();
    let pct = pct_str.parse::<f32>().ok().filter(|p| (0.0..=100.0).contains(p))?;

    let tokens: Vec<&str> = rest.split_whitespace().collect();
    let mut size: Option<String> = None;
    let mut rate: Option<String> = None;
    let mut i = 0;
    while i < tokens.len() {
        match tokens[i] {
            "of" if size.is_none() => {
                if let Some(next) = tokens.get(i + 1) {
                    if *next == "~" {
                        if let Some(n2) = tokens.get(i + 2) {
                            size = Some(format!("~{n2}"));
                            i += 2;
                        }
                    } else {
                        size = Some(next.trim_start_matches('~').to_string());
                        i += 1;
                    }
                }
            }
            "at" if rate.is_none() => {
                if let Some(next) = tokens.get(i + 1) {
                    if next.ends_with("/s") {
                        rate = Some(next.to_string());
                        i += 1;
                    }
                }
            }
            _ => {}
        }
        i += 1;
    }

    Some((pct, size, rate))
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

    // Never overwrite. Two same-titled jobs can finish at once, and
    // std::fs::rename REPLACES an existing destination on both Unix and
    // Windows — so we can't just rename onto a name unique_target_path picked
    // (a concurrent job may have grabbed the same name in the TOCTOU window).
    // Instead claim the name atomically with create_new (only one job can win
    // that), then move the produced file onto the placeholder we own.
    let mut last_err: Option<std::io::Error> = None;
    for _ in 0..1000 {
        let dest = unique_target_path(target, &stem, &ext);
        match std::fs::OpenOptions::new().write(true).create_new(true).open(&dest) {
            Ok(_) => {
                // We own `dest`. Move the produced file onto it (fast rename on
                // the same filesystem, else copy across mounts). Both replace
                // our empty placeholder — safe, since no other job can hold it.
                if std::fs::rename(&produced_path, &dest).is_ok() {
                    return Ok((dest.clone(), file_name_of(&dest, &stem, &ext)));
                }
                match std::fs::copy(&produced_path, &dest) {
                    Ok(_) => {
                        let _ = std::fs::remove_file(&produced_path);
                        return Ok((dest.clone(), file_name_of(&dest, &stem, &ext)));
                    }
                    Err(e) => {
                        let _ = std::fs::remove_file(&dest); // drop the placeholder
                        return Err(format!(
                            "Could not move file into {}: {e}",
                            target.display()
                        ));
                    }
                }
            }
            // Name taken between check and create — recompute a fresh one.
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => {
                last_err = Some(e);
                break;
            }
        }
    }
    Err(format!(
        "Could not find a free filename for \"{stem}.{ext}\" in {} ({:?})",
        target.display(),
        last_err
    ))
}

fn file_name_of(dest: &Path, stem: &str, ext: &str) -> String {
    dest.file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| format!("{stem}.{ext}"))
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
    headers: axum::http::HeaderMap,
    Json(req): Json<DownloadReq>,
) -> (StatusCode, Json<Value>) {
    // DNS-rebinding defense: only accept requests whose Host is loopback. The
    // server binds 127.0.0.1, but a malicious web page can rebind its own
    // hostname to 127.0.0.1 to reach us same-origin — it would still send its
    // own Host header (e.g. "evil.example"), not a loopback one. /download is
    // the only state-changing endpoint (it spawns yt-dlp and writes files), so
    // it's the one worth guarding.
    let host_ok = headers
        .get(axum::http::header::HOST)
        .and_then(|h| h.to_str().ok())
        .map(|h| {
            let bare = h.trim().split(':').next().unwrap_or("");
            bare == "127.0.0.1" || bare == "localhost"
        })
        .unwrap_or(false);
    if !host_ok {
        return (StatusCode::FORBIDDEN, Json(json!({ "error": "Forbidden." })));
    }

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
            speed: None,
            total: None,
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
