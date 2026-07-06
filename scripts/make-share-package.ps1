# Builds the shareable Windows package:
#   dist-share\soundMatik\
#     panel\                (UXP panel: manifest, index.html, dist, icons)
#     helper\               (sidecar exe + yt-dlp/ffmpeg/deno binaries)
#     soundMatik.ccx        (fallback: double-click installs via Creative Cloud)
#     INSTALL.bat           (one-click installer)
#     UNINSTALL.bat
#     register-panel.ps1    (registers/unregisters the panel with Premiere's UXP loader)
#     README.txt
#   dist-share\soundMatik-windows.zip
#
# Install mechanism: Premiere Pro does NOT scan
# %APPDATA%\Adobe\UXP\Plugins\External by itself — third-party UXP panels only
# appear in Window > Extensions (UXP) when they are listed in
# %APPDATA%\Adobe\UXP\PluginsInfo\v1\premierepro.json. INSTALL.bat therefore
# copies the panel to a versioned folder AND merges that registry file (via
# register-panel.ps1) — the same layout Creative Cloud's own .ccx install
# produces.
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot   # repo root (G:\SOUNDMATIK)
$out = Join-Path $root "dist-share"
$pkg = Join-Path $out "soundMatik"
if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
New-Item -ItemType Directory -Force $pkg | Out-Null

$manifest = Get-Content (Join-Path $root "soundmatik-panel\manifest.json") -Raw | ConvertFrom-Json
$version = $manifest.version
Write-Host "Packaging soundMatik $version for Windows"

Write-Host "1/4 Building panel..."
Push-Location (Join-Path $root "soundmatik-panel")
npm run build | Out-Null
Pop-Location

Write-Host "2/4 Staging panel + soundMatik.ccx..."
$panelDst = Join-Path $pkg "panel"
New-Item -ItemType Directory -Force $panelDst, (Join-Path $panelDst "dist") | Out-Null
Copy-Item (Join-Path $root "soundmatik-panel\manifest.json") $panelDst
Copy-Item (Join-Path $root "soundmatik-panel\index.html") $panelDst
Copy-Item (Join-Path $root "soundmatik-panel\dist\index.js") (Join-Path $panelDst "dist")
Copy-Item (Join-Path $root "soundmatik-panel\icons") $panelDst -Recurse
# the 1024px sources aren't needed at runtime
Remove-Item (Join-Path $panelDst "icons\source") -Recurse -Force -ErrorAction SilentlyContinue
$ccxZip = Join-Path $out "soundMatik.zip"
if (Test-Path $ccxZip) { Remove-Item $ccxZip -Force }
Compress-Archive -Path (Join-Path $panelDst "*") -DestinationPath $ccxZip
Move-Item $ccxZip (Join-Path $pkg "soundMatik.ccx") -Force

Write-Host "3/4 Staging helper..."
$helper = Join-Path $pkg "helper"
New-Item -ItemType Directory -Force (Join-Path $helper "bin\win") | Out-Null
Copy-Item (Join-Path $root "soundmatik-sidecar\target\release\soundmatik-sidecar.exe") $helper
Copy-Item (Join-Path $root "soundmatik-sidecar\bin\win\*") (Join-Path $helper "bin\win")

Write-Host "4/4 Writing installer files + zip..."

# Registers (or removes) the panel in Premiere's UXP plugin registry. Kept as
# a separate file so INSTALL.bat/UNINSTALL.bat stay free of quoting gymnastics.
@'
param([string]$Version = "0.0.0", [switch]$Remove)
$ErrorActionPreference = "Stop"
$pluginId = "com.soundmatik.panel"
$infoDir = Join-Path $env:APPDATA "Adobe\UXP\PluginsInfo\v1"
$infoFile = Join-Path $infoDir "premierepro.json"
New-Item -ItemType Directory -Force $infoDir | Out-Null
$data = $null
if (Test-Path $infoFile) {
    try { $data = Get-Content $infoFile -Raw | ConvertFrom-Json } catch { $data = $null }
}
if (-not $data -or -not $data.PSObject.Properties["plugins"]) {
    $data = [pscustomobject]@{ plugins = @() }
}
$plugins = @($data.plugins | Where-Object { $_.pluginId -ne $pluginId })
if (-not $Remove) {
    $plugins += [pscustomobject]@{
        hostMinVersion = "26.0"
        name           = "soundMatik"
        path           = "`$localPlugins/External/${pluginId}_$Version"
        pluginId       = $pluginId
        status         = "enabled"
        type           = "uxp"
        versionString  = $Version
    }
}
$json = ConvertTo-Json -InputObject ([pscustomobject]@{ plugins = @($plugins) }) -Depth 10
[System.IO.File]::WriteAllText($infoFile, $json, (New-Object System.Text.UTF8Encoding($false)))
'@ | Out-File (Join-Path $pkg "register-panel.ps1") -Encoding ascii

@"
@echo off
setlocal
echo Installing soundMatik...
echo.

rem -- helper (downloader) ---------------------------------------------------
taskkill /IM soundmatik-sidecar.exe /F >nul 2>&1
set "HELPER_DEST=%LOCALAPPDATA%\soundMatik"
xcopy /E /I /Y "%~dp0helper" "%HELPER_DEST%" >nul
if errorlevel 1 goto fail
echo   Helper installed:  %HELPER_DEST%

rem -- Premiere UXP panel (versioned folder + registry entry) -----------------
set "PANEL_BASE=%APPDATA%\Adobe\UXP\Plugins\External"
set "PANEL_DEST=%PANEL_BASE%\com.soundmatik.panel_$version"
if exist "%PANEL_BASE%\com.soundmatik.panel" rd /S /Q "%PANEL_BASE%\com.soundmatik.panel"
for /D %%D in ("%PANEL_BASE%\com.soundmatik.panel_*") do rd /S /Q "%%D"
xcopy /E /I /Y "%~dp0panel" "%PANEL_DEST%" >nul
if errorlevel 1 goto fail
echo   Panel installed:   %PANEL_DEST%

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0register-panel.ps1" -Version $version
if errorlevel 1 goto fail
echo   Panel registered with Premiere Pro.

echo.
echo Done! Now:
echo   1. Restart Premiere Pro (close it completely, then open it again)
echo   2. Open the panel:  Window ^> Extensions (UXP) ^> soundMatik
echo.
pause
exit /b 0

:fail
echo.
echo Something went wrong during installation.
echo Try running INSTALL.bat again. If it keeps failing, install the panel
echo manually by double-clicking soundMatik.ccx (needs Adobe Creative Cloud),
echo and start the helper once via %LOCALAPPDATA%\soundMatik\soundmatik-sidecar.exe
echo.
pause
exit /b 1
"@ | Out-File (Join-Path $pkg "INSTALL.bat") -Encoding ascii

@"
@echo off
echo Removing soundMatik...
taskkill /IM soundmatik-sidecar.exe /F >nul 2>&1
rd /S /Q "%LOCALAPPDATA%\soundMatik" 2>nul
set "PANEL_BASE=%APPDATA%\Adobe\UXP\Plugins\External"
if exist "%PANEL_BASE%\com.soundmatik.panel" rd /S /Q "%PANEL_BASE%\com.soundmatik.panel"
for /D %%D in ("%PANEL_BASE%\com.soundmatik.panel_*") do rd /S /Q "%%D"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0register-panel.ps1" -Remove
echo Done. Restart Premiere Pro to make it disappear from the menu.
echo (Downloaded audio files in your projects are NOT touched.)
pause
"@ | Out-File (Join-Path $pkg "UNINSTALL.bat") -Encoding ascii

@'
soundMatik - pull audio from any online video straight into Premiere Pro
by Sevki Bugra Ozbek - catheadai.com

REQUIREMENTS
- Adobe Premiere Pro 2026 (version 26.0 or newer), Windows 10/11

INSTALL
1) Double-click INSTALL.bat
   (If Windows SmartScreen warns you: More info > Run anyway.)
2) Restart Premiere Pro completely
3) In Premiere:  Window > Extensions (UXP) > soundMatik

USAGE
- Paste a video link, pick WAV or MP3, hit DOWNLOAD AUDIO.
- The audio file is saved to a SOUND_EFFECTS folder next to your project
  file and imported into a SOUND_EFFECTS bin in the Project panel
  automatically.
- Your project must have been saved at least once.

UPDATES
- Click "Check for updates" at the bottom of the panel. If a newer version
  exists, download the new zip and run INSTALL.bat again - it replaces the
  old version cleanly.

TROUBLESHOOTING
- Panel not in the menu? Run INSTALL.bat again, then make sure Premiere was
  fully closed and reopened. As a fallback, double-click soundMatik.ccx to
  install the panel via Adobe Creative Cloud.
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
