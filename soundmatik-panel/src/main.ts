// soundMatik panel logic: paste URL -> sidecar downloads/extracts audio next to
// the open project -> import the file into the SOUND_EFFECTS bin.

import type {
  premierepro,
  Project,
  ProjectItem,
  FolderItem,
} from "@adobe/premierepro";

declare const require: (module: string) => any;

const ppro = require("premierepro") as premierepro;
const uxp = require("uxp");

const SIDECAR_BASE = "http://127.0.0.1:41320";
const BIN_NAME = "SOUND_EFFECTS";
const POLL_INTERVAL_MS = 1000;
const MAX_JOB_MINUTES = 30;
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

let format: AudioFormat = loadSavedFormat();
let running = false;

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
  return Promise.race([
    fetch(url, init),
    new Promise<Response>((_, reject) =>
      setTimeout(() => reject(new Error("timeout")), timeoutMs)
    ),
  ]);
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

/// Possible helper locations, in order: dev checkout (repo sibling of the
/// plugin folder), then the per-user install used by the share package.
async function getSidecarCandidatePaths(): Promise<string[]> {
  const candidates: string[] = [];
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
    /* plugin folder unavailable — fall through to the installed location */
  }
  try {
    const home: string = require("os").homedir().replace(/[\\/]+$/, "");
    if (home.includes("\\")) {
      candidates.push(`${home}\\AppData\\Local\\soundMatik\\soundmatik-sidecar.exe`);
    } else {
      candidates.push(`${home}/Library/Application Support/soundMatik/soundmatik-sidecar`);
    }
  } catch {
    /* os module unavailable — dev path only */
  }
  return candidates;
}

async function ensureSidecar(): Promise<void> {
  if (await sidecarHealthy()) return;

  const candidates = await getSidecarCandidatePaths();
  for (const exePath of candidates) {
    try {
      // Launches the helper invisibly (it has no console window). Requires the
      // manifest's launchProcess permission. Nonexistent paths just fail here
      // and we move on to the next candidate.
      await uxp.shell.openPath(exePath);
    } catch {
      /* try next candidate after the poll below */
    }
    const deadline = Date.now() + 6_000;
    while (Date.now() < deadline) {
      await sleep(500);
      if (await sidecarHealthy(1000)) return;
    }
  }

  throw new Error(
    `Can't reach the soundMatik helper on 127.0.0.1:41320. Start it manually by double-clicking:\n${
      candidates.join("\nor: ") || "soundmatik-sidecar(.exe)"
    }`
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
  const project = await ppro.Project.getActiveProject();
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

async function importIntoBin(project: Project, filePath: string): Promise<void> {
  const bin = await findOrCreateSoundEffectsBin(project);
  const ok = await project.importFiles(
    [filePath],
    true, // suppressUI
    bin, // target bin
    false // asNumberedStills
  );
  if (!ok) {
    throw new Error(
      `Premiere reported the import failed. The file is on disk at:\n${filePath}`
    );
  }
}

// ---------------------------------------------------------------------------
// Job flow

interface JobStatusResponse {
  state: "downloading" | "converting" | "done" | "error";
  progress?: number;
  filePath?: string;
  fileName?: string;
  error?: string;
}

async function startJob(url: string, targetFolder: string): Promise<string> {
  const res = await fetchWithTimeout(
    `${SIDECAR_BASE}/download`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ url, format, targetFolder }),
    },
    10_000
  );
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
        const pct =
          typeof status.progress === "number" && status.progress > 0
            ? ` ${status.progress.toFixed(0)}%`
            : "…";
        setStatus("busy", "Downloading", `Grabbing audio${pct}`);
        break;
      }
      case "converting":
        setStatus("busy", "Converting", `Extracting ${format.toUpperCase()} audio…`);
        break;
      case "done":
      case "error":
        return status;
    }
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

    // 4. Import into the SOUND_EFFECTS bin.
    setStatus("busy", "Importing", `Adding "${finalStatus.fileName}" to the ${BIN_NAME} bin…`);
    await importIntoBin(project, finalStatus.filePath);

    setStatus(
      "done",
      "Done",
      `"${finalStatus.fileName}" is in the ${BIN_NAME} bin — drag it onto your timeline.`
    );
    urlInput.value = "";
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    setStatus("error", "Error", message);
  } finally {
    setBusy(false);
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
$<HTMLElement>("site-link").addEventListener("click", () => {
  try {
    uxp.shell.openExternal("https://catheadai.com");
  } catch {
    /* non-critical */
  }
});

setFormat(format);
