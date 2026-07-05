#!/usr/bin/env bash
# Downloads the macOS binaries the sidecar drives (yt-dlp, ffmpeg, deno)
# into soundmatik-sidecar/bin/mac/. Re-run any time to update them.
#
# ffmpeg/ffprobe come from evermeet.cx (x86_64; runs on Apple Silicon via
# Rosetta). If you want native arm64 ffmpeg instead, install it via
# `brew install ffmpeg` and copy the binaries into bin/mac/ yourself.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/mac"
DL="$ROOT/bin/_downloads"
mkdir -p "$BIN" "$DL"

echo "Downloading yt-dlp (universal macOS build)..."
curl -sL -o "$BIN/yt-dlp" https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos

echo "Downloading deno..."
ARCH="$(uname -m)"   # arm64 or x86_64
if [ "$ARCH" = "arm64" ]; then
  DENO_ZIP="deno-aarch64-apple-darwin.zip"
else
  DENO_ZIP="deno-x86_64-apple-darwin.zip"
fi
curl -sL -o "$DL/deno.zip" "https://github.com/denoland/deno/releases/latest/download/$DENO_ZIP"
unzip -oq "$DL/deno.zip" -d "$DL/deno-tmp"
cp "$DL/deno-tmp/deno" "$BIN/"

echo "Downloading ffmpeg + ffprobe (evermeet.cx)..."
curl -sL -o "$DL/ffmpeg.zip" "https://evermeet.cx/ffmpeg/getrelease/ffmpeg/zip"
curl -sL -o "$DL/ffprobe.zip" "https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip"
unzip -oq "$DL/ffmpeg.zip" -d "$BIN"
unzip -oq "$DL/ffprobe.zip" -d "$BIN"

chmod +x "$BIN/yt-dlp" "$BIN/deno" "$BIN/ffmpeg" "$BIN/ffprobe"
rm -rf "$DL"

echo "Done. Binaries in $BIN:"
ls -la "$BIN"
