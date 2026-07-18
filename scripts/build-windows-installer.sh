#!/usr/bin/env bash
#
# Builds the single-file Windows installer  dist-share/soundMatik-Setup.exe
# with NSIS (makensis). Runs on macOS/Linux OR Windows — makensis is
# cross-platform. This is the mac/linux-side counterpart to the makensis call
# in scripts/make-share-package.ps1 (which does the same on Windows).
#
# Prerequisites:
#   - makensis on PATH               (macOS: `brew install makensis`)
#   - The Windows helper exe built:  soundmatik-sidecar/target/x86_64-pc-windows-gnu/release/soundmatik-sidecar.exe
#       (cross-compile: `cargo +<toolchain> zigbuild --release --target x86_64-pc-windows-gnu`)
#   - The 4 Windows binaries:        soundmatik-sidecar/bin/win/{yt-dlp,ffmpeg,ffprobe,deno}.exe
#       (fetch on Windows with soundmatik-sidecar/scripts/fetch-binaries.ps1)
#   - The panel built:               soundmatik-panel/dist/index.js  (npm run build)
#
# Note: makensis 3.12 on macOS 26 crashes in its UNICODE output writer, so the
# .nsi builds in ANSI mode (Unicode false) — fine, all paths are ASCII.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIDE="$ROOT/soundmatik-sidecar"
PANEL="$ROOT/soundmatik-panel"
NSI="$ROOT/scripts/windows/soundmatik-setup.nsi"
REGPS1="$ROOT/scripts/windows/register-panel.ps1"
OUT="$ROOT/dist-share"
STAGE="$OUT/_win-payload"
EXE_OUT="$OUT/soundMatik-Setup.exe"

log() { printf '\n\033[1;36m▸ %s\033[0m\n' "$1"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

command -v makensis >/dev/null || die "makensis not found (brew install makensis)"

VERSION="$(python3 -c "import json;print(json.load(open('$PANEL/manifest.json'))['version'])")"
[ -n "$VERSION" ] || die "could not read version from manifest.json"
log "Building soundMatik-Setup.exe  (version $VERSION)"

WINEXE="$SIDE/target/x86_64-pc-windows-gnu/release/soundmatik-sidecar.exe"
[ -f "$WINEXE" ] || die "missing $WINEXE — cross-compile the Windows helper first"
for b in yt-dlp ffmpeg ffprobe deno; do
  [ -f "$SIDE/bin/win/$b.exe" ] || die "missing soundmatik-sidecar/bin/win/$b.exe — fetch the Windows binaries first"
done
[ -f "$PANEL/dist/index.js" ] || die "missing panel build — run 'npm run build' in soundmatik-panel"

# ── Stage the PAYLOAD in the exact layout the .nsi expects ──────────────────
log "Staging payload..."
rm -rf "$STAGE"
mkdir -p "$STAGE/helper/bin/win" "$STAGE/panel/dist" "$STAGE/panel/icons"
cp "$WINEXE" "$STAGE/helper/soundmatik-sidecar.exe"
cp "$SIDE/bin/win/"{yt-dlp,ffmpeg,ffprobe,deno}.exe "$STAGE/helper/bin/win/"
cp "$PANEL/manifest.json" "$PANEL/index.html" "$STAGE/panel/"
cp "$PANEL/dist/index.js" "$STAGE/panel/dist/"
cp "$PANEL/icons/"{icon.png,icon@2x.png,plugin-icon.png,plugin-icon@2x.png} "$STAGE/panel/icons/"
cp "$REGPS1" "$STAGE/register-panel.ps1"

# Build the .ccx the installer hands to Adobe's UPIA (the real load path). A
# .ccx is just a flat zip of the panel (manifest + index.html + dist + icons).
log "Building soundMatik.ccx ..."
CCXSTAGE="$OUT/_ccx"; rm -rf "$CCXSTAGE"; mkdir -p "$CCXSTAGE/dist"
cp "$PANEL/manifest.json" "$PANEL/index.html" "$CCXSTAGE/"
cp "$PANEL/dist/index.js" "$CCXSTAGE/dist/"
cp -R "$PANEL/icons" "$CCXSTAGE/"; rm -rf "$CCXSTAGE/icons/source"
( cd "$CCXSTAGE" && zip -qr "$STAGE/soundMatik.ccx" . )
rm -rf "$CCXSTAGE"

# ── Compile ────────────────────────────────────────────────────────────────
log "Compiling with makensis (LZMA solid on ~330MB — takes a couple of minutes)..."
rm -f "$EXE_OUT"
makensis -DVERSION="$VERSION" -DPAYLOAD="$STAGE" -DOUTFILE="$EXE_OUT" "$NSI"
rm -rf "$STAGE"

[ -f "$EXE_OUT" ] || die "makensis did not produce $EXE_OUT"
SIZE_MB=$(( $(stat -f%z "$EXE_OUT" 2>/dev/null || stat -c%s "$EXE_OUT") / 1000000 ))
log "Done: $EXE_OUT  (${SIZE_MB} MB)"
file "$EXE_OUT" || true
