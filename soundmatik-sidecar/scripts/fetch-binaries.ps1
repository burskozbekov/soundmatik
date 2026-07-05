# Downloads the Windows binaries the sidecar drives (yt-dlp, ffmpeg, deno)
# into soundmatik-sidecar\bin\win\. Re-run any time to update them.
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot   # soundmatik-sidecar/
$binDir = Join-Path $root "bin\win"
$dl = Join-Path $root "bin\_downloads"
New-Item -ItemType Directory -Force $binDir | Out-Null
New-Item -ItemType Directory -Force $dl | Out-Null

Write-Host "Downloading yt-dlp..."
curl.exe -sL -o (Join-Path $dl "yt-dlp.exe") https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe
Copy-Item (Join-Path $dl "yt-dlp.exe") $binDir -Force

Write-Host "Downloading deno..."
curl.exe -sL -o (Join-Path $dl "deno-win.zip") https://github.com/denoland/deno/releases/latest/download/deno-x86_64-pc-windows-msvc.zip
Expand-Archive -Path (Join-Path $dl "deno-win.zip") -DestinationPath (Join-Path $dl "deno-tmp") -Force
Copy-Item (Join-Path $dl "deno-tmp\deno.exe") $binDir -Force

Write-Host "Downloading ffmpeg (yt-dlp's recommended build, ~160 MB)..."
curl.exe -sL -o (Join-Path $dl "ffmpeg-win.zip") https://github.com/yt-dlp/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip
Expand-Archive -Path (Join-Path $dl "ffmpeg-win.zip") -DestinationPath (Join-Path $dl "ffmpeg-tmp") -Force
$ffbin = Get-ChildItem (Join-Path $dl "ffmpeg-tmp") -Directory | Select-Object -First 1
Copy-Item (Join-Path $ffbin.FullName "bin\ffmpeg.exe") $binDir -Force
Copy-Item (Join-Path $ffbin.FullName "bin\ffprobe.exe") $binDir -Force

Remove-Item $dl -Recurse -Force
Write-Host "Done. Binaries in $binDir :"
Get-ChildItem $binDir | Format-Table Name, Length
