# Builds the single-file Windows installer  dist-share\soundMatik-Setup.exe
# with NSIS (makensis). Run this ON WINDOWS. The mac/linux counterpart is
# scripts/build-windows-installer.sh (identical payload + same .nsi).
#
# One double-click file for the user — no zip, no INSTALL.bat to hunt for.
# The installer is per-user (no admin): it copies the helper to
# %LOCALAPPDATA%\soundMatik, the panel to a versioned folder under
# %APPDATA%\Adobe\UXP\Plugins\External, merges premierepro.json (preserving
# other plugins), and writes an uninstaller under HKCU Add/Remove Programs.
#
# Prerequisites:
#   - NSIS on PATH (makensis).            https://nsis.sourceforge.net/
#   - Rust (cargo) to build the helper exe.
#   - Node (npm) to build the panel.
#   - The bundled Windows binaries (yt-dlp/ffmpeg/ffprobe/deno) — fetched below.
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot   # repo root
$side = Join-Path $root "soundmatik-sidecar"
$panel = Join-Path $root "soundmatik-panel"
$out = Join-Path $root "dist-share"
$stage = Join-Path $out "_win-payload"
$nsi = Join-Path $root "scripts\windows\soundmatik-setup.nsi"
$regps1 = Join-Path $root "scripts\windows\register-panel.ps1"
New-Item -ItemType Directory -Force $out | Out-Null

$manifest = Get-Content (Join-Path $panel "manifest.json") -Raw | ConvertFrom-Json
$version = $manifest.version
Write-Host "Building soundMatik-Setup.exe  (version $version)"

if (-not (Get-Command makensis -ErrorAction SilentlyContinue)) {
    throw "makensis not found on PATH. Install NSIS from https://nsis.sourceforge.net/"
}

Write-Host "1/5 Fetching bundled Windows binaries (if missing)..."
$needed = @("yt-dlp.exe","ffmpeg.exe","ffprobe.exe","deno.exe")
$haveAll = $true
foreach ($b in $needed) { if (-not (Test-Path (Join-Path $side "bin\win\$b"))) { $haveAll = $false } }
if (-not $haveAll) {
    & (Join-Path $side "scripts\fetch-binaries.ps1")
}
foreach ($b in $needed) {
    if (-not (Test-Path (Join-Path $side "bin\win\$b"))) { throw "missing bundled binary: bin\win\$b" }
}

Write-Host "2/5 Building the helper (cargo release)..."
Push-Location $side
cargo build --release | Out-Null
Pop-Location
$winexe = Join-Path $side "target\release\soundmatik-sidecar.exe"
if (-not (Test-Path $winexe)) { throw "helper build missing: $winexe" }

Write-Host "3/5 Building the panel..."
Push-Location $panel
npm run build | Out-Null
Pop-Location

Write-Host "4/5 Staging payload..."
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force `
    (Join-Path $stage "helper\bin\win"), (Join-Path $stage "panel\dist"), (Join-Path $stage "panel\icons") | Out-Null
Copy-Item $winexe (Join-Path $stage "helper\soundmatik-sidecar.exe")
Copy-Item (Join-Path $side "bin\win\*") (Join-Path $stage "helper\bin\win")
Copy-Item (Join-Path $panel "manifest.json") (Join-Path $stage "panel")
Copy-Item (Join-Path $panel "index.html") (Join-Path $stage "panel")
Copy-Item (Join-Path $panel "dist\index.js") (Join-Path $stage "panel\dist")
Copy-Item (Join-Path $panel "icons\icon.png") (Join-Path $stage "panel\icons")
Copy-Item (Join-Path $panel "icons\icon@2x.png") (Join-Path $stage "panel\icons")
Copy-Item (Join-Path $panel "icons\plugin-icon.png") (Join-Path $stage "panel\icons")
Copy-Item (Join-Path $panel "icons\plugin-icon@2x.png") (Join-Path $stage "panel\icons")
Copy-Item $regps1 (Join-Path $stage "register-panel.ps1")

# Build the .ccx the installer hands to Adobe's UPIA (the real load path):
# a flat zip of the panel (manifest + index.html + dist + icons).
$ccxStage = Join-Path $out "_ccx"
if (Test-Path $ccxStage) { Remove-Item $ccxStage -Recurse -Force }
New-Item -ItemType Directory -Force (Join-Path $ccxStage "dist") | Out-Null
Copy-Item (Join-Path $panel "manifest.json") $ccxStage
Copy-Item (Join-Path $panel "index.html") $ccxStage
Copy-Item (Join-Path $panel "dist\index.js") (Join-Path $ccxStage "dist")
Copy-Item (Join-Path $panel "icons") $ccxStage -Recurse
Remove-Item (Join-Path $ccxStage "icons\source") -Recurse -Force -ErrorAction SilentlyContinue
$ccxZip = Join-Path $out "soundMatik.zip"
if (Test-Path $ccxZip) { Remove-Item $ccxZip -Force }
Compress-Archive -Path (Join-Path $ccxStage "*") -DestinationPath $ccxZip
Move-Item $ccxZip (Join-Path $stage "soundMatik.ccx") -Force
Remove-Item $ccxStage -Recurse -Force

Write-Host "5/5 Compiling installer with makensis..."
$exeOut = Join-Path $out "soundMatik-Setup.exe"
if (Test-Path $exeOut) { Remove-Item $exeOut -Force }
makensis "-DVERSION=$version" "-DPAYLOAD=$stage" "-DOUTFILE=$exeOut" $nsi
Remove-Item $stage -Recurse -Force
if (-not (Test-Path $exeOut)) { throw "makensis did not produce $exeOut" }

Write-Host "Done:"
Write-Host ("  {0}  ({1:N0} MB)" -f $exeOut, ((Get-Item $exeOut).Length / 1MB))
