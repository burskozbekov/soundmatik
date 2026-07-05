#!/usr/bin/env bash
# Downloads the macOS binaries the sidecar drives (yt-dlp, ffmpeg, deno)
# into soundmatik-sidecar/bin/mac/. Re-run any time to update them.
#
# ffmpeg/ffprobe are native arm64 static builds from ffmpeg.martin-riedl.de
# (Apple Silicon only — this package does not support Intel Macs). deno is
# arch-matched and yt-dlp is universal, so the whole bundle runs arm64-native
# without Rosetta.
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

echo "Downloading ffmpeg + ffprobe (arm64 static, martin-riedl.de)..."
curl -sL -o "$DL/ffmpeg.zip" "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip"
curl -sL -o "$DL/ffprobe.zip" "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffprobe.zip"
unzip -oq "$DL/ffmpeg.zip" -d "$BIN"
unzip -oq "$DL/ffprobe.zip" -d "$BIN"

chmod +x "$BIN/yt-dlp" "$BIN/deno" "$BIN/ffmpeg" "$BIN/ffprobe"
rm -rf "$DL"

echo "Done. Binaries in $BIN:"
ls -la "$BIN"
