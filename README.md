# soundMatik

Paste a link to any online video into a panel inside **Adobe Premiere Pro (2026, v26+)**,
and the audio shows up seconds later as a WAV or MP3 in a `SOUND_EFFECTS` bin of your
open project — saved next to the `.prproj` on disk, ready to drag onto the timeline.

Personal single-user tool. No marketplace packaging, no licensing, no telemetry.

---

## How it works

```
┌────────────────────────────┐        HTTP (127.0.0.1:41320)
│  Premiere Pro              │       ┌──────────────────────────────┐
│  ┌──────────────────────┐  │ fetch │  soundmatik-sidecar (Rust)   │
│  │ soundMatik UXP panel │──┼──────▶│  POST /download → jobId      │
│  │ (soundmatik-panel/)  │◀─┼───────│  GET  /status/:jobId (poll)  │
│  └──────────────────────┘  │       │  runs bundled binaries:      │
│   imports finished file    │       │  yt-dlp + ffmpeg + deno      │
│   into SOUND_EFFECTS bin   │       │  writes <project>/SOUND_EFFECTS/ │
└────────────────────────────┘       └──────────────────────────────┘
```

The UXP sandbox can't spawn processes or write to arbitrary folders, so the panel
delegates to a tiny local HTTP server (the *sidecar*). The sidecar drives a bundled
`yt-dlp` (with explicit paths to bundled `ffmpeg` and `deno` — deno is required for
YouTube's JS challenges), extracts audio, sanitizes the video title into a filename
(deduplicating with ` (2)`, ` (3)`… instead of overwriting), and writes it into
`<project folder>/SOUND_EFFECTS/`. The panel then finds-or-creates the
`SOUND_EFFECTS` bin under the project root and imports the file into it.

- Sidecar starts **on demand** (the panel launches it on first download) and
  **exits itself** after 15 idle minutes.
- Fixed port `41320`, bound to `127.0.0.1` only.
- One instance max: a second launch sees the port taken and exits quietly.

## Repo layout

| Path | What |
|---|---|
| `soundmatik-panel/` | UXP panel (TypeScript, manifestVersion 5, host `premierepro`) |
| `soundmatik-sidecar/` | Rust HTTP server (axum) that does the downloading |
| `soundmatik-sidecar/bin/win/` | Bundled `yt-dlp.exe`, `ffmpeg.exe`, `ffprobe.exe`, `deno.exe` |
| `soundmatik-sidecar/scripts/` | `fetch-binaries.ps1` (Windows) / `fetch-binaries.sh` (macOS) |

## One-time setup (Windows — already done in this checkout)

Everything below has already been run in this repo; listed for rebuilds/new machines.

```powershell
# 1. Fetch/update the bundled binaries (yt-dlp, ffmpeg, deno)
powershell -File soundmatik-sidecar\scripts\fetch-binaries.ps1

# 2. Build the sidecar
cd soundmatik-sidecar
cargo build --release          # → target\release\soundmatik-sidecar.exe

# 3. Build the panel bundle
cd ..\soundmatik-panel
npm install
npm run build                  # → dist\index.js   (npm run watch for auto-rebuild)
```

## Loading the panel in Premiere (UXP Developer Tool)

1. Start **Premiere Pro 2026** and open (or create+save) a project.
2. Start **Adobe UXP Developer Tools** (installed at
   `C:\Program Files\Adobe\Adobe UXP Developer Tools`). Enable *Developer Mode*
   if it asks (Settings → toggle).
3. **Add Plugin** → select `G:\SOUNDMATIK\soundmatik-panel\manifest.json`.
4. In the plugin row: **⋯ → Load** (or **Load & Watch** while developing —
   pair it with `npm run watch`).
5. In Premiere: **Window → Extensions (UXP) → soundMatik** if it isn't already visible.

For a permanent install on your own machines, UDT's **⋯ → Package** produces a
`.ccx` you can double-click to install via Creative Cloud. (Skip signing /
marketplace — not needed for personal use.)

## Using it

1. Paste a video URL (single video — playlists are out of scope by design).
2. Pick **WAV** (lossless PCM) or **MP3** (192 kbps). The choice is remembered.
3. **Download audio.** Status walks through *Starting → Downloading (with %) →
   Converting → Importing → Done*.
4. Drag the clip from the `SOUND_EFFECTS` bin onto your timeline.

Requirements at download time: a project is open **and has been saved at least
once** (the audio is stored next to the `.prproj`; the panel tells you if not).

## Sidecar details

- Health probe: `curl http://127.0.0.1:41320/health`
- Log file: `soundmatik-sidecar\target\release\soundmatik-sidecar.log`
  (next to wherever the exe runs from)
- Env overrides: `SOUNDMATIK_BIN_DIR` (binary folder), `SOUNDMATIK_IDLE_SECS`
  (idle-exit timeout, default 900)
- The panel launches the exe at
  `<repo>\soundmatik-sidecar\target\release\soundmatik-sidecar.exe`
  (path derived from the panel's own location — keep the two folders siblings).
  If auto-launch is blocked, double-click that exe yourself; everything else
  works the same.

## macOS notes

Untested here, but everything is cross-platform by construction:

```bash
./soundmatik-sidecar/scripts/fetch-binaries.sh   # binaries → bin/mac/
cd soundmatik-sidecar && cargo build --release
```

ffmpeg comes from evermeet.cx (x86_64; fine under Rosetta — or drop in a Homebrew
arm64 build). If the panel can't auto-start the bare executable on macOS, start it
manually (`./target/release/soundmatik-sidecar`) — it lingers 15 min per use.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Can't reach the soundMatik helper" | Start the exe manually (path in the error). Check the log file. Windows Firewall shouldn't prompt for loopback-only servers, but allow it if it does. |
| YouTube errors mentioning "JS challenge" / "runtime" | Re-run `fetch-binaries.ps1` — updates yt-dlp *and* deno. YouTube changes constantly; a stale yt-dlp is the usual culprit. |
| "Video unavailable / requires sign-in" | The video is private, region-locked, or age-gated — cookies/logins are out of scope. |
| Import fails but the file exists | Drag it in from `<project>\SOUND_EFFECTS\` manually; check the panel's exact error. |
| Panel loads but looks stale after edits | `npm run build` again, or use Load & Watch + `npm run watch`. |

## Design notes / deviations

- **`launchProcess` permission is in the panel manifest** even though the original
  plan hoped to avoid it: it's what lets the panel auto-start the sidecar via
  `shell.openPath()`. Without it you'd have to start the sidecar by hand every
  time. The panel still does zero filesystem writing and zero process *management* —
  the sidecar self-manages (single instance, idle exit).
- `network.domains` is `"all"` per the plan (documented UXP quirks with literal
  loopback whitelisting); the panel only ever calls `127.0.0.1:41320`.
- Manifest host/app id and structure were taken from Adobe's official
  `uxp-premiere-pro-samples` (`premiere-api` + `oauth-workflow-sample`), and all
  Premiere calls (`getActiveProject`, `project.path`, `getRootItem`,
  `createBinAction` inside `lockedAccess`/`executeTransaction`,
  `importFiles(paths, suppressUI, targetBin, asNumberedStills)`) were verified
  against `@adobe/premierepro@26.3.0` type declarations.
