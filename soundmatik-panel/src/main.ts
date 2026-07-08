// soundMatik panel logic: paste URL -> sidecar downloads/extracts audio next to
// the open project -> import the file into the SOUND_EFFECTS bin.

import type {
  premierepro,
  Project,
  ProjectItem,
  FolderItem,
} from "@adobe/premierepro";

declare const require: (module: string) => any;
declare const process: any;

const ppro = require("premierepro") as premierepro;
const uxp = require("uxp");

const VERSION = "1.1.1"; // keep in sync with manifest.json
const RELEASES_API =
  "https://api.github.com/repos/burskozbekov/soundmatik/releases/latest";
const RELEASES_PAGE = "https://github.com/burskozbekov/soundmatik/releases/latest";

const SIDECAR_BASE = "http://127.0.0.1:41320";
const BIN_NAME = "SOUND_EFFECTS";
const POLL_INTERVAL_MS = 1000;
// Strictly GREATER than the sidecar's 60-minute yt-dlp limit (our poll clock
// starts a touch earlier and the helper's final file-move runs outside its
// timeout), so we don't give up while the helper is still finishing and leave
// the file unimported. pollUntilDone also does a final status check on timeout.
const MAX_JOB_MINUTES = 65;
const FORMAT_STORAGE_KEY = "soundmatik.format";

type AudioFormat = "wav" | "mp3";
type UiState = "idle" | "busy" | "done" | "error";

// ---------------------------------------------------------------------------
// UI plumbing

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

const urlInput = $<HTMLInputElement>("url");
const wavBtn = $<HTMLElement>("fmt-wav");
const mp3Btn = $<HTMLElement>("fmt-mp3");
const formatHint = $<HTMLElement>("fmt-hint");
const downloadBtn = $<HTMLElement>("download");
const statusBox = $<HTMLElement>("status");
const progressBox = $<HTMLElement>("progress");
const progressFill = $<HTMLElement>("progress-fill");
const progressPct = $<HTMLElement>("progress-pct");
const progressSpeed = $<HTMLElement>("progress-speed");

let format: AudioFormat = loadSavedFormat();
let running = false;
// Tracks the input length so a paste (big jump) can be told apart from typing.
let lastInputLen = 0;

function setStatus(ui: UiState, state: string, message: string) {
  statusBox.className = ui;
  // UXP ignores text-transform, so uppercase the badge here.
  (statusBox.querySelector(".state") as HTMLElement).textContent = state.toUpperCase();
  (statusBox.querySelector(".msg") as HTMLElement).textContent = message;
}

function setFormat(next: AudioFormat) {
  format = next;
  wavBtn.classList.toggle("selected", next === "wav");
  mp3Btn.classList.toggle("selected", next === "mp3");
  formatHint.textContent =
    next === "wav"
      ? "Lossless PCM — full quality, larger files"
      : "192 kbps — small files, fine for most SFX";
  try {
    window.localStorage.setItem(FORMAT_STORAGE_KEY, next);
  } catch {
    // localStorage unavailable -> format just won't persist across sessions
  }
}

function loadSavedFormat(): AudioFormat {
  try {
    const saved = window.localStorage.getItem(FORMAT_STORAGE_KEY);
    if (saved === "wav" || saved === "mp3") return saved;
  } catch {
    /* ignore */
  }
  return "wav";
}

function setBusy(busy: boolean) {
  running = busy;
  downloadBtn.classList.toggle("disabled", busy);
  urlInput.disabled = busy;
  wavBtn.classList.toggle("disabled", busy);
  mp3Btn.classList.toggle("disabled", busy);
}

// ---------------------------------------------------------------------------
// Download progress bar

function hideProgress() {
  progressBox.classList.add("hidden");
  progressFill.classList.remove("indeterminate");
  progressFill.style.width = "0%";
  progressPct.textContent = "0%";
  progressSpeed.textContent = "";
}

/// Known percentage: fill the bar and show percent + transfer speed.
function showProgress(pct: number, speed?: string) {
  progressBox.classList.remove("hidden");
  progressFill.classList.remove("indeterminate");
  const clamped = Math.max(0, Math.min(100, pct));
  progressFill.style.width = `${clamped}%`;
  progressPct.textContent = `${clamped.toFixed(0)}%`;
  progressSpeed.textContent = speed ? speed : "";
}

/// Unknown percentage (download just started, or converting): show a moving
/// stripe and a label instead of a stuck 0%.
function showProgressBusy(label: string) {
  progressBox.classList.remove("hidden");
  progressFill.style.width = "";
  progressFill.classList.add("indeterminate");
  progressPct.textContent = label;
  progressSpeed.textContent = "";
}

// ---------------------------------------------------------------------------
// Small fetch helpers (with timeout — UXP supports AbortController, but keep a
// Promise.race fallback in case the host build doesn't)

async function fetchWithTimeout(
  url: string,
  init: RequestInit | undefined,
  timeoutMs: number
): Promise<Response> {
  if (typeof AbortController !== "undefined") {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      return await fetch(url, { ...(init || {}), signal: ctrl.signal });
    } finally {
      clearTimeout(timer);
    }
  }
  const timeout = new Promise<Response>((_, reject) =>
    setTimeout(() => reject(new Error("timeout")), timeoutMs)
  );
  // Pre-handle the loser so a fetch win doesn't leave an unhandled rejection.
  timeout.catch(() => {});
  return Promise.race([fetch(url, init), timeout]);
}

async function sidecarHealthy(timeoutMs = 1500): Promise<boolean> {
  try {
    const res = await fetchWithTimeout(`${SIDECAR_BASE}/health`, undefined, timeoutMs);
    if (!res.ok) return false;
    const body = await res.json();
    // Identity check: some other app squatting on port 41320 must not be
    // mistaken for our helper.
    return body && body.ok === true && body.service === "soundmatik-sidecar";
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Sidecar lifecycle: health-check, and lazily launch the executable on demand.
// The sidecar exits itself after an idle timeout, so this can happen any time.

function joinPath(sep: string, ...parts: string[]): string {
  return parts.join(sep);
}

/// The user's home directory. Primary source is the UXP os module; if that's
/// unavailable, derive it from the plugin folder's native path (which lives
/// under ~/Library/... on macOS and %USERPROFILE%\AppData\... on Windows).
async function resolveHomeDir(): Promise<string | null> {
  try {
    const home: string = require("os").homedir();
    if (home) return home.replace(/[\\/]+$/, "");
  } catch {
    /* os module unavailable — fall through */
  }
  try {
    const pluginFolder = await uxp.storage.localFileSystem.getPluginFolder();
    const native: string = pluginFolder.nativePath;
    const m = native.match(/^(.*?)[\\/](Library|AppData)[\\/]/);
    if (m) return m[1];
  } catch {
    /* no plugin folder either */
  }
  return null;
}

/// Possible helper locations, most likely first: the per-user install used by
/// the share packages, then the dev checkout (repo sibling of the plugin
/// folder) as a development fallback.
async function getSidecarCandidatePaths(): Promise<string[]> {
  const candidates: string[] = [];
  const home = await resolveHomeDir();
  if (home) {
    if (home.includes("\\")) {
      // %LOCALAPPDATA% can be relocated (roaming profiles / folder
      // redirection) — prefer it over the homedir-derived default when set.
      try {
        const lad =
          typeof process !== "undefined" && process.env && process.env.LOCALAPPDATA;
        if (lad && typeof lad === "string") {
          candidates.push(`${lad.replace(/[\\/]+$/, "")}\\soundMatik\\soundmatik-sidecar.exe`);
        }
      } catch {
        /* process unavailable in this host — use the default below */
      }
      const fallback = `${home}\\AppData\\Local\\soundMatik\\soundmatik-sidecar.exe`;
      if (!candidates.includes(fallback)) candidates.push(fallback);
    } else {
      // On macOS the helper ships as a .app bundle so `open` actually launches
      // it (opening a raw Unix executable would not run it).
      candidates.push(
        `${home}/Library/Application Support/soundMatik/soundMatik Helper.app`
      );
    }
  }
  try {
    const pluginFolder = await uxp.storage.localFileSystem.getPluginFolder();
    // nativePath can come back with a trailing separator (UDT does this) —
    // trim it, or the "go one folder up" step silently goes nowhere.
    const native: string = pluginFolder.nativePath.replace(/[\\/]+$/, "");
    const sep = native.includes("\\") ? "\\" : "/";
    const repoRoot = native.split(sep).slice(0, -1).join(sep);
    const exeName =
      sep === "\\" ? "soundmatik-sidecar.exe" : "soundmatik-sidecar";
    candidates.push(
      joinPath(sep, repoRoot, "soundmatik-sidecar", "target", "release", exeName)
    );
  } catch {
    /* plugin folder unavailable — installed location only */
  }
  return candidates;
}

// How long to wait for the helper to answer /health after launching it. The
// ~240MB helper's cold start (first run after boot/install) includes a full
// Gatekeeper signature check and can take 10-20s — a short window makes the
// first click fail with a confusing error while the helper is still starting.
const LAUNCH_WAIT_MS = 30_000;
// A candidate whose launch failed (nonexistent path / denied) still gets a
// short poll window in case something else brought the helper up meanwhile.
const DEAD_CANDIDATE_WAIT_MS = 2_000;
// uxp.shell.openPath stays pending while the host shows its launch-permission
// consent dialog — race it against a timer so it can never wedge the panel.
const OPEN_PATH_TIMEOUT_MS = 5_000;
const CONSENT_PENDING: unique symbol = Symbol("consent-pending");

async function ensureSidecar(): Promise<void> {
  if (await sidecarHealthy()) return;

  const candidates = await getSidecarCandidatePaths();
  const launchErrors: string[] = [];
  let sawConsentDialog = false;
  for (const exePath of candidates) {
    // Launches the helper invisibly (it has no console window). Requires the
    // manifest's launchProcess permission. Per UXP docs openPath does NOT
    // reject: it resolves "" on success or a non-empty error message on
    // failure/denial — and stays pending while the consent dialog is up.
    let outcome: string | typeof CONSENT_PENDING;
    try {
      outcome = await Promise.race([
        uxp.shell.openPath(
          exePath,
          "soundMatik needs to start its local helper app to download audio."
        ),
        sleep(OPEN_PATH_TIMEOUT_MS).then(() => CONSENT_PENDING),
      ]);
    } catch (e) {
      // Not documented to throw, but treat a throw like a failed candidate.
      outcome = e instanceof Error ? e.message : String(e);
    }

    let waitMs: number;
    if (outcome === CONSENT_PENDING) {
      // Most likely Premiere is showing its launch-permission dialog.
      sawConsentDialog = true;
      setStatus(
        "busy",
        "Starting",
        "If Premiere asks for permission to start the soundMatik helper, click Allow…"
      );
      waitMs = LAUNCH_WAIT_MS;
    } else if (typeof outcome === "string" && outcome.length > 0) {
      // Candidate missing, or the user denied the launch permission.
      launchErrors.push(outcome);
      waitMs = DEAD_CANDIDATE_WAIT_MS;
    } else {
      // Launch dispatched — give the cold start plenty of time.
      waitMs = LAUNCH_WAIT_MS;
    }

    const start = Date.now();
    let toldSlow = false;
    while (Date.now() - start < waitMs) {
      await sleep(500);
      if (await sidecarHealthy(1000)) return;
      if (
        waitMs === LAUNCH_WAIT_MS &&
        outcome !== CONSENT_PENDING &&
        !toldSlow &&
        Date.now() - start > 4_000
      ) {
        toldSlow = true;
        setStatus(
          "busy",
          "Starting",
          "Starting the soundMatik helper — the first launch after a restart can take ~20 seconds…"
        );
      }
    }
  }

  // Only claim Premiere "blocked" it if a permission dialog actually appeared;
  // if every candidate path was simply missing (helper not installed), tell the
  // user to install instead — a "click Allow" message would never come true.
  if (sawConsentDialog) {
    throw new Error(
      "Premiere blocked soundMatik from starting its helper app. Click DOWNLOAD AUDIO again and choose Allow when Premiere asks for permission."
    );
  }
  throw new Error(
    "The soundMatik helper isn't installed (or couldn't be started). Please run the soundMatik installer once, then try again."
  );
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

// ---------------------------------------------------------------------------
// Premiere side

interface ProjectTarget {
  project: Project;
  targetFolder: string;
}

async function getProjectTarget(): Promise<ProjectTarget> {
  let project: Project | null = null;
  try {
    project = await ppro.Project.getActiveProject();
  } catch {
    /* some hosts reject instead of resolving null — same meaning */
  }
  if (!project) {
    throw new Error("No project is open in Premiere Pro.");
  }
  const projectPath = project.path;
  // An unsaved/untitled project has no usable file path to put audio next to.
  if (!projectPath || !/\.prproj$/i.test(projectPath)) {
    throw new Error(
      "This project hasn't been saved yet. Save it first (File → Save), then try again — soundMatik puts audio next to the .prproj file."
    );
  }
  const sep = projectPath.includes("\\") ? "\\" : "/";
  const lastSep = projectPath.lastIndexOf(sep);
  const projectFolder = projectPath.slice(0, lastSep);
  return { project, targetFolder: `${projectFolder}${sep}${BIN_NAME}` };
}

async function findSoundEffectsBin(project: Project): Promise<ProjectItem | null> {
  const rootItem: FolderItem = await project.getRootItem();
  const items: ProjectItem[] = await rootItem.getItems();
  for (const item of items) {
    if (item.type === ppro.ProjectItem.TYPE_BIN && item.name === BIN_NAME) {
      return item;
    }
  }
  return null;
}

async function findOrCreateSoundEffectsBin(project: Project): Promise<ProjectItem> {
  const existing = await findSoundEffectsBin(project);
  if (existing) return existing;

  const rootItem: FolderItem = await project.getRootItem();
  let transactionOk = false;
  project.lockedAccess(() => {
    transactionOk = project.executeTransaction((compoundAction) => {
      compoundAction.addAction(rootItem.createBinAction(BIN_NAME, true));
    }, "Create SOUND_EFFECTS bin");
  });
  if (!transactionOk) {
    throw new Error("Premiere refused to create the SOUND_EFFECTS bin.");
  }

  const created = await findSoundEffectsBin(project);
  if (!created) {
    throw new Error("Created the SOUND_EFFECTS bin but couldn't find it afterwards.");
  }
  return created;
}

async function importIntoBin(
  project: Project,
  filePath: string,
  fileName: string
): Promise<void> {
  const bin = await findOrCreateSoundEffectsBin(project);
  const ok = await project.importFiles(
    [filePath],
    true, // suppressUI
    bin, // target bin
    false // asNumberedStills
  );
  if (!ok) {
    throw new Error(
      `Premiere couldn't import "${fileName}". The audio was downloaded — open the SOUND_EFFECTS folder next to your project file and drag it in manually.`
    );
  }
}

// ---------------------------------------------------------------------------
// Job flow

interface JobStatusResponse {
  state: "downloading" | "converting" | "done" | "error";
  progress?: number;
  speed?: string;
  total?: string;
  filePath?: string;
  fileName?: string;
  error?: string;
}

async function startJob(url: string, targetFolder: string): Promise<string> {
  let res: Response;
  try {
    res = await fetchWithTimeout(
      `${SIDECAR_BASE}/download`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ url, format, targetFolder }),
      },
      10_000
    );
  } catch {
    throw new Error(
      "The helper didn't respond to the download request — wait a few seconds and try again."
    );
  }
  const body = await res.json().catch(() => ({}));
  if (!res.ok || !body.jobId) {
    throw new Error(body.error || `Helper rejected the request (HTTP ${res.status}).`);
  }
  return body.jobId as string;
}

async function pollUntilDone(jobId: string): Promise<JobStatusResponse> {
  const deadline = Date.now() + MAX_JOB_MINUTES * 60_000;
  let consecutiveFailures = 0;

  while (Date.now() < deadline) {
    await sleep(POLL_INTERVAL_MS);
    let status: JobStatusResponse;
    try {
      const res = await fetchWithTimeout(`${SIDECAR_BASE}/status/${jobId}`, undefined, 5000);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      status = (await res.json()) as JobStatusResponse;
      consecutiveFailures = 0;
    } catch {
      consecutiveFailures += 1;
      if (consecutiveFailures >= 5) {
        throw new Error("Lost contact with the soundMatik helper mid-download.");
      }
      continue;
    }

    switch (status.state) {
      case "downloading": {
        const known =
          typeof status.progress === "number" && status.progress > 0;
        if (known) {
          const pct = status.progress as number;
          showProgress(pct, status.speed);
          const size = status.total ? ` of ${status.total}` : "";
          const spd = status.speed ? ` · ${status.speed}` : "";
          setStatus("busy", "Downloading", `Grabbing audio ${pct.toFixed(0)}%${size}${spd}`);
        } else {
          showProgressBusy("Starting…");
          setStatus("busy", "Downloading", "Grabbing audio…");
        }
        break;
      }
      case "converting":
        showProgressBusy("Converting…");
        setStatus("busy", "Converting", `Extracting ${format.toUpperCase()} audio…`);
        break;
      case "done":
      case "error":
        return status;
    }
  }
  // Deadline hit. The helper's own timeout starts slightly later than ours and
  // its final file-move runs outside it, so the job may have just finished —
  // do one last status check before giving up, or we'd strand a downloaded
  // file in SOUND_EFFECTS without importing it.
  try {
    const res = await fetchWithTimeout(`${SIDECAR_BASE}/status/${jobId}`, undefined, 5000);
    if (res.ok) {
      const status = (await res.json()) as JobStatusResponse;
      if (status.state === "done" || status.state === "error") return status;
    }
  } catch {
    /* fall through to the give-up error */
  }
  throw new Error(`Gave up after ${MAX_JOB_MINUTES} minutes — the download never finished.`);
}

async function onDownloadClicked(): Promise<void> {
  if (running) return;

  const url = urlInput.value.trim();
  if (!url) {
    setStatus("error", "Error", "Paste a video URL first.");
    return;
  }
  if (!/^https?:\/\//i.test(url)) {
    setStatus("error", "Error", "That doesn't look like a link — it should start with http:// or https://.");
    return;
  }

  setBusy(true);
  hideProgress();
  try {
    // 1. Where does the audio go? (fails fast if the project isn't saved)
    const { project, targetFolder } = await getProjectTarget();

    // 2. Make sure the helper is up (starts it if needed).
    setStatus("busy", "Starting", "Contacting the soundMatik helper…");
    await ensureSidecar();

    // 3. Kick off the download job and poll it.
    setStatus("busy", "Downloading", "Requesting download…");
    const jobId = await startJob(url, targetFolder);
    const finalStatus = await pollUntilDone(jobId);

    if (finalStatus.state === "error" || !finalStatus.filePath) {
      throw new Error(finalStatus.error || "Download failed for an unknown reason.");
    }

    // 4. The download can take a while — make sure the SAME project is still
    //    active before importing, or we'd import into the wrong project (or let
    //    a raw native error reach the user). If it changed, the file is safe on
    //    disk; tell the user where it is.
    let active: Project | null = null;
    try {
      active = await ppro.Project.getActiveProject();
    } catch {
      /* treated as no active project */
    }
    if (!active || active.path !== project.path) {
      setStatus(
        "done",
        "Saved",
        `"${finalStatus.fileName}" was saved to the ${BIN_NAME} folder next to your project. The active project changed during the download, so drag it in from there.`
      );
      urlInput.value = "";
      lastInputLen = 0;
      return;
    }

    // 5. Import into the SOUND_EFFECTS bin.
    setStatus("busy", "Importing", `Adding "${finalStatus.fileName}" to the ${BIN_NAME} bin…`);
    await importIntoBin(
      active,
      finalStatus.filePath,
      finalStatus.fileName || "the audio file"
    );

    setStatus(
      "done",
      "Done",
      `"${finalStatus.fileName}" is in the ${BIN_NAME} bin — drag it onto your timeline.`
    );
    urlInput.value = "";
    lastInputLen = 0; // field cleared programmatically — don't treat next type as a paste
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    setStatus("error", "Error", message);
  } finally {
    setBusy(false);
    hideProgress();
    // Keep the paste-detection tracker in sync with the field after every run
    // (0 on the success/clear path, the leftover URL's length after an error) so
    // the next paste is still detected as a big length jump.
    lastInputLen = urlInput.value.length;
  }
}

// ---------------------------------------------------------------------------
// Wire up

wavBtn.addEventListener("click", () => {
  if (!running) setFormat("wav");
});
mp3Btn.addEventListener("click", () => {
  if (!running) setFormat("mp3");
});
downloadBtn.addEventListener("click", () => {
  void onDownloadClicked();
});
urlInput.addEventListener("keydown", (e: KeyboardEvent) => {
  if (e.key === "Enter") void onDownloadClicked();
});

/// Auto-start when a link lands in the input. Reads the field on the next tick
/// so pasted text has been applied. The running-guard in onDownloadClicked
/// makes firing this more than once per paste harmless.
function autoStartIfUrl() {
  setTimeout(() => {
    if (running) return;
    const url = urlInput.value.trim();
    if (/^https?:\/\//i.test(url)) {
      void onDownloadClicked();
    }
  }, 0);
}

// Paste = go. UXP is inconsistent about which of these it delivers, so we
// listen to all of them and let the running-guard de-dupe:
//   1. the "paste" event (when the host fires it),
//   2. the "input" event with an insertFromPaste/Drop inputType,
//   3. any "input" where the value suddenly jumps by many characters (a paste
//      or drag-drop looks like a big jump; typing adds one char at a time) and
//      now looks like a full URL — the catch-all when inputType is absent,
//   4. Cmd/Ctrl+V keydown as a last resort.
urlInput.addEventListener("paste", () => autoStartIfUrl());
urlInput.addEventListener("input", (e: Event) => {
  const value = urlInput.value;
  const jumped = value.length - lastInputLen >= 8;
  lastInputLen = value.length;
  const inputType = (e as InputEvent).inputType;
  const pasteLike =
    inputType === "insertFromPaste" || inputType === "insertFromDrop";
  if (pasteLike || (jumped && /^https?:\/\//i.test(value.trim()))) {
    autoStartIfUrl();
  }
});
urlInput.addEventListener("keydown", (e: KeyboardEvent) => {
  if ((e.metaKey || e.ctrlKey) && (e.key === "v" || e.key === "V")) {
    autoStartIfUrl();
  }
});

$<HTMLElement>("site-link").addEventListener("click", () => {
  try {
    uxp.shell.openExternal("https://catheadai.com");
  } catch {
    /* non-critical */
  }
});

// ---------------------------------------------------------------------------
// Update check (GitHub Releases)

function isNewerVersion(candidate: string, current: string): boolean {
  const pa = candidate.split(".").map((n) => parseInt(n, 10) || 0);
  const pb = current.split(".").map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < 3; i++) {
    if ((pa[i] || 0) > (pb[i] || 0)) return true;
    if ((pa[i] || 0) < (pb[i] || 0)) return false;
  }
  return false;
}

let updateAvailable = false;
const updateLink = $<HTMLElement>("update-link");

async function checkForUpdates(): Promise<void> {
  if (updateAvailable) {
    // Second click: take the user to the download page.
    try {
      uxp.shell.openExternal(RELEASES_PAGE);
    } catch {
      /* non-critical */
    }
    return;
  }
  updateLink.textContent = "Checking…";
  try {
    // GitHub's REST API rejects requests with no User-Agent (HTTP 403), which
    // would make every update check silently fall through to "open releases
    // page" and never actually compare versions. Send a UA + Accept header.
    const res = await fetchWithTimeout(
      RELEASES_API,
      {
        headers: {
          "User-Agent": "soundMatik-panel",
          Accept: "application/vnd.github+json",
        },
      },
      8000
    );
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const body = await res.json();
    // tag like "v1.2.0" (possibly with a suffix) -> "1.2.0"
    const latest = String(body.tag_name || "")
      .replace(/^v/i, "")
      .split("-")[0];
    if (latest && isNewerVersion(latest, VERSION)) {
      updateAvailable = true;
      updateLink.textContent = `Get v${latest} ↗`;
      setStatus(
        "done",
        "Update",
        `soundMatik v${latest} is available — click "Get v${latest}" below to download it.`
      );
    } else {
      updateLink.textContent = "Up to date ✓";
      setTimeout(() => {
        updateLink.textContent = "Check for updates";
      }, 4000);
    }
  } catch {
    // Offline or rate-limited — just point at the releases page.
    updateAvailable = true;
    updateLink.textContent = "Open releases page ↗";
  }
}

updateLink.addEventListener("click", () => {
  void checkForUpdates();
});
$<HTMLElement>("version").textContent = `v${VERSION}`;

setFormat(format);
