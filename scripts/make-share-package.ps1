# Builds the shareable Windows package:
#   dist-share\soundMatik\
#     panel\                (UXP panel: manifest, index.html, dist, icons)
#     helper\               (sidecar exe + yt-dlp/ffmpeg/deno binaries)
#     INSTALL.bat           (one-click installer)
#     UNINSTALL.bat
#     README.txt
#   dist-share\soundMatik-windows.zip
#
# Install mechanism: the panel folder is copied into
#   %APPDATA%\Adobe\UXP\Plugins\External\com.soundmatik.panel
# which Premiere scans automatically (same mechanism as other locally
# installed UXP plugins) — no Creative Cloud / ccx involved.
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot   # repo root (G:\SOUNDMATIK)
$out = Join-Path $root "dist-share"
$pkg = Join-Path $out "soundMatik"
if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
New-Item -ItemType Directory -Force $pkg | Out-Null

Write-Host "1/4 Building panel..."
Push-Location (Join-Path $root "soundmatik-panel")
npm run build | Out-Null
Pop-Location

Write-Host "2/4 Staging panel..."
$panelDst = Join-Path $pkg "panel"
New-Item -ItemType Directory -Force $panelDst, (Join-Path $panelDst "dist") | Out-Null
Copy-Item (Join-Path $root "soundmatik-panel\manifest.json") $panelDst
Copy-Item (Join-Path $root "soundmatik-panel\index.html") $panelDst
Copy-Item (Join-Path $root "soundmatik-panel\dist\index.js") (Join-Path $panelDst "dist")
Copy-Item (Join-Path $root "soundmatik-panel\icons") $panelDst -Recurse
# the 1024px sources aren't needed at runtime
Remove-Item (Join-Path $panelDst "icons\source") -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "3/4 Staging helper..."
$helper = Join-Path $pkg "helper"
New-Item -ItemType Directory -Force (Join-Path $helper "bin\win") | Out-Null
Copy-Item (Join-Path $root "soundmatik-sidecar\target\release\soundmatik-sidecar.exe") $helper
Copy-Item (Join-Path $root "soundmatik-sidecar\bin\win\*") (Join-Path $helper "bin\win")

Write-Host "4/4 Writing installer files + zip..."
@'
@echo off
echo Installing soundMatik...
echo.

rem -- helper (downloader) ---------------------------------------------------
taskkill /IM soundmatik-sidecar.exe /F >nul 2>&1
set "HELPER_DEST=%LOCALAPPDATA%\soundMatik"
xcopy /E /I /Y "%~dp0helper" "%HELPER_DEST%" >nul
if errorlevel 1 goto :fail
echo   Helper installed:  %HELPER_DEST%

rem -- Premiere UXP panel ----------------------------------------------------
set "PANEL_DEST=%APPDATA%\Adobe\UXP\Plugins\External\com.soundmatik.panel"
if exist "%PANEL_DEST%" rmdir /S /Q "%PANEL_DEST%"
xcopy /E /I /Y "%~dp0panel" "%PANEL_DEST%" >nul
if errorlevel 1 goto :fail
echo   Panel installed:   %PANEL_DEST%

echo.
echo Done! Now:
echo   1. Restart Premiere Pro (close it completely, then open it again)
echo   2. Open the panel:  Window ^> UXP Plugins ^> soundMatik
echo.
pause
exit /b 0

:fail
echo.
echo Something went wrong during the copy step. Try running INSTALL.bat again.
pause
exit /b 1
'@ | Out-File (Join-Path $pkg "INSTALL.bat") -Encoding ascii

@'
@echo off
echo Removing soundMatik...
taskkill /IM soundmatik-sidecar.exe /F >nul 2>&1
rmdir /S /Q "%LOCALAPPDATA%\soundMatik" 2>nul
rmdir /S /Q "%APPDATA%\Adobe\UXP\Plugins\External\com.soundmatik.panel" 2>nul
echo Done. Restart Premiere Pro to make it disappear from the menu.
echo (Downloaded audio files in your projects are NOT touched.)
pause
'@ | Out-File (Join-Path $pkg "UNINSTALL.bat") -Encoding ascii

@'
soundMatik - pull audio from any online video straight into Premiere Pro
by Sevki Bugra Ozbek · catheadai.com

REQUIREMENTS
- Adobe Premiere Pro 2026 (version 26.0 or newer), Windows 10/11

INSTALL
1) Double-click INSTALL.bat
2) Restart Premiere Pro completely
3) In Premiere:  Window > UXP Plugins > soundMatik

USAGE
- Paste a video link, pick WAV or MP3, hit DOWNLOAD AUDIO.
- The audio file is saved to <your project folder>\SOUND_EFFECTS\ and
  imported into a SOUND_EFFECTS bin in the Project panel automatically.
- Your project must have been saved at least once.

UPDATES
- Click "Check for updates" at the bottom of the panel. If a newer version
  exists, download the new zip and run INSTALL.bat again - it replaces the
  old version cleanly.

TROUBLESHOOTING
- Panel not in the menu? Make sure Premiere was fully closed and reopened
  after install.
- "Can't reach the soundMatik helper": double-click
  %LOCALAPPDATA%\soundMatik\soundmatik-sidecar.exe once, then try again.
- A specific video fails? Some videos are private, age-gated or login-only;
  those can't be downloaded. If ALL YouTube videos suddenly fail, grab the
  newest soundMatik zip (yt-dlp inside needs updating) via
  https://github.com/burskozbekov/soundmatik/releases

UNINSTALL
- Double-click UNINSTALL.bat
'@ | Out-File (Join-Path $pkg "README.txt") -Encoding ascii

$zip = Join-Path $out "soundMatik-windows.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $pkg -DestinationPath $zip

Write-Host "Done:"
Write-Host "  Folder: $pkg"
Write-Host ("  Zip   : {0}  ({1:N0} MB)" -f $zip, ((Get-Item $zip).Length / 1MB))
