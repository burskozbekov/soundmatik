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
5. In Premiere: **Window → UXP Plugins → soundMatik** if it isn't already visible.

Note: UDT-loaded plugins disappear when Premiere restarts — that's expected dev
behavior. For a **permanent** install use the release installer
(`soundMatik-mac.dmg` / `soundMatik-Setup.exe`, see Distribution below); don't
keep both a UDT-loaded and an installed copy active at the same time (same
plugin id).

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
- Log file (installed): macOS `~/Library/Logs/soundMatik/soundmatik-sidecar.log`;
  Windows `%LOCALAPPDATA%\soundMatik\soundmatik-sidecar.log`. In a dev build the
  log sits next to wherever the exe runs from.
- Env overrides: `SOUNDMATIK_BIN_DIR` (binary folder), `SOUNDMATIK_IDLE_SECS`
  (idle-exit timeout, default 900)
- The panel launches the exe at
  `<repo>\soundmatik-sidecar\target\release\soundmatik-sidecar.exe`
  (path derived from the panel's own location — keep the two folders siblings).
  If auto-launch is blocked, double-click that exe yourself; everything else
  works the same.

## macOS build (signed + notarized)

Everything is cross-platform by construction. The Mac build ships as one
**signed + notarized + stapled `soundMatik-mac.dmg`** — the user opens it and
double-clicks `Install soundMatik.app` inside; no security warnings at any step.
This needs an Apple Developer account and must run **on a Mac**. The macOS
package is **Apple Silicon only** (M1+); Intel Macs are not supported.

```bash
# one-time: rustup, xcode-select --install, node, a Developer ID Application cert,
# and a stored notary profile (see the header of the script for exact commands)
export SM_SIGN_ID="Developer ID Application: Your Name (TEAMID)"
export SM_NOTARY_PROFILE="soundmatik-notary"
./scripts/make-mac-package.sh
```

The script fetches the mac binaries, builds the sidecar, assembles the helper `.app`
(sidecar in `Contents/MacOS/`, yt-dlp/ffmpeg/deno in `Contents/Resources/bin/mac/`),
codesigns everything with Hardened Runtime + `soundmatik-sidecar/mac/entitlements.plist`,
notarizes via `notarytool` and staples. It then builds a **tiny** `Install soundMatik.app`
AppleScript applet and packages it into a DMG whose volume also carries a hidden
`.payload/` (the notarized helper `.app` + the `.ccx`). Finally it signs the DMG
(Developer ID Application + `--timestamp` only — a disk image is data, not code),
notarizes the DMG directly, and staples it (three notarization submissions total:
helper, applet, DMG). At install time the applet copies the helper out of `.payload`
into `~/Library/Application Support/soundMatik/`, pre-launches it, and opens the `.ccx`.

> Why a tiny applet + a hidden `.payload` instead of embedding the helper in the
> applet: a quarantined app run from a downloaded DMG is **App-Translocated**
> (copied to a random read-only mount and re-verified), and a ~130 MB embedded
> payload stalls Gatekeeper for minutes at `_dyld_start` on first launch. A
> few-KB applet launches instantly and copies the payload from the DMG volume.
> (A notarizable `.pkg` would need a *Developer ID Installer* cert we don't have;
> a signed DMG only needs the *Developer ID Application* cert, which we do.)

The bundled runtimes need JIT/unsigned-memory entitlements (deno's V8, yt-dlp's
embedded Python). If notarization rejects a specific binary, read the notary log
(`xcrun notarytool log <id> ...`) and adjust `entitlements.plist` — the three
default keys cover the usual cases but this is the one step that may need a pass
or two the first time.

ffmpeg/ffprobe are native arm64 static builds from ffmpeg.martin-riedl.de, so the
whole bundle runs arm64-native (no Rosetta). This is why the macOS package is Apple
Silicon only.

## Distribution (GitHub Releases)

Personal tool, shared with friends via a GitHub Release. **One double-click file
per platform** — no zip to unpack, no `INSTALL.bat` to hunt for:

- **Windows:** `scripts/build-windows-installer.sh` (macOS/Linux) or
  `scripts/make-share-package.ps1` (Windows) → `dist-share/soundMatik-Setup.exe`,
  a per-user NSIS installer (no admin). It installs the helper to
  `%LOCALAPPDATA%\soundMatik`, the panel to a versioned
  `%APPDATA%\Adobe\UXP\Plugins\External\com.soundmatik.panel_<version>`, and
  **registers it in `%APPDATA%\Adobe\UXP\PluginsInfo\v1\premierepro.json`** (which
  is what Premiere actually reads — copying files under `Plugins\External` alone
  is not enough) via the bundled `register-panel.ps1`. Writes an HKCU
  Add/Remove-Programs uninstaller. Unsigned — friends click through SmartScreen's
  *More info → Run anyway* once, and may need to allow `yt-dlp.exe` past an
  antivirus false-positive.
- **macOS:** `scripts/make-mac-package.sh` → `dist-share/soundMatik-mac.dmg`
  (signed + notarized — no warnings; open it and double-click `Install soundMatik.app`).

The release assets are always named exactly `soundMatik-mac.dmg` and
`soundMatik-Setup.exe`, so
`…/releases/latest/download/soundMatik-mac.dmg` (and `-Setup.exe`) are permanent
links that never change across versions.

Publishing an update: bump the version in `soundmatik-panel/manifest.json`,
`soundmatik-panel/package.json`, `soundmatik-panel/src/main.ts` (`VERSION`),
`soundmatik-sidecar/Cargo.toml`, and `soundmatik-sidecar/mac/Info.plist` together,
rebuild both installers, and create a new GitHub release tagged `vX.Y.Z`. The
panel's footer **Check for updates** control compares against the latest release
tag and points users at the download page.

> The Windows release bundles a GPL ffmpeg build (yt-dlp/FFmpeg-Builds). Its source
> is at <https://github.com/yt-dlp/FFmpeg-Builds> / <https://ffmpeg.org>.

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
