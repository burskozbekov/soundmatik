# Builds the friend-shareable soundMatik package:
#   dist-share\soundMatik\
#     soundMatik.ccx        (panel — double-click installs via Creative Cloud)
#     helper\               (sidecar exe + yt-dlp/ffmpeg/deno binaries)
#     KURULUM.bat           (one-click installer)
#     OKU-BENI.txt          (Turkish install/usage notes)
#   dist-share\soundMatik-kurulum.zip
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot   # repo root (G:\SOUNDMATIK)
$out = Join-Path $root "dist-share"
$pkg = Join-Path $out "soundMatik"
if (Test-Path $pkg) { Remove-Item $pkg -Recurse -Force }
New-Item -ItemType Directory -Force $pkg | Out-Null

Write-Host "1/4 Panel derleniyor..."
Push-Location (Join-Path $root "soundmatik-panel")
npm run build | Out-Null
Pop-Location

Write-Host "2/4 soundMatik.ccx paketleniyor..."
$stage = Join-Path $out "_ccx-stage"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage, (Join-Path $stage "dist") | Out-Null
Copy-Item (Join-Path $root "soundmatik-panel\manifest.json") $stage
Copy-Item (Join-Path $root "soundmatik-panel\index.html") $stage
Copy-Item (Join-Path $root "soundmatik-panel\dist\index.js") (Join-Path $stage "dist")
Copy-Item (Join-Path $root "soundmatik-panel\icons") $stage -Recurse
$ccxZip = Join-Path $out "soundMatik.zip"
if (Test-Path $ccxZip) { Remove-Item $ccxZip -Force }
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $ccxZip
Move-Item $ccxZip (Join-Path $pkg "soundMatik.ccx") -Force
Remove-Item $stage -Recurse -Force

Write-Host "3/4 Helper kopyalaniyor..."
$helper = Join-Path $pkg "helper"
New-Item -ItemType Directory -Force (Join-Path $helper "bin\win") | Out-Null
Copy-Item (Join-Path $root "soundmatik-sidecar\target\release\soundmatik-sidecar.exe") $helper
Copy-Item (Join-Path $root "soundmatik-sidecar\bin\win\*") (Join-Path $helper "bin\win")

Write-Host "4/4 Kurulum dosyalari + zip..."
@'
@echo off
echo soundMatik kurulumu basliyor...
taskkill /IM soundmatik-sidecar.exe /F >nul 2>&1
set "DEST=%LOCALAPPDATA%\soundMatik"
xcopy /E /I /Y "%~dp0helper" "%DEST%" >nul
echo Yardimci program kuruldu: %DEST%
echo.
echo Simdi panel yuklenecek. Acilan Creative Cloud penceresinden onaylayin.
start "" "%~dp0soundMatik.ccx"
echo.
echo Bitti! Premiere'i (aciksa) yeniden baslatin ve
echo Window - Extensions (UXP) - soundMatik menusunden paneli acin.
pause
'@ | Out-File (Join-Path $pkg "KURULUM.bat") -Encoding ascii

@'
soundMatik — video linkinden ses indirme paneli (Premiere Pro 2026+)
by Sevki Bugra Ozbek · catheadai.com

KURULUM
1) Bu klasordeki KURULUM.bat dosyasina cift tiklayin.
2) Acilan Creative Cloud penceresinde eklenti kurulumunu onaylayin.
   ("Dogrulanmamis eklenti" uyarisi gelirse kabul edin — kisisel paylasim.)
3) Premiere Pro'yu yeniden baslatin.
4) Premiere'de: Window > Extensions (UXP) > soundMatik

KULLANIM
- Video linkini yapistirin, WAV veya MP3 secin, DOWNLOAD AUDIO'ya basin.
- Ses dosyasi <proje klasoru>\SOUND_EFFECTS\ icine iner ve Project
  panelindeki SOUND_EFFECTS bin'ine otomatik eklenir.
- Projenizin en az bir kez kaydedilmis olmasi gerekir.

SORUN GIDERME
- "Can't reach the soundMatik helper" derse: %LOCALAPPDATA%\soundMatik
  klasorundeki soundmatik-sidecar.exe dosyasina bir kez cift tiklayip
  tekrar deneyin.
- YouTube indirmeleri bozulursa yt-dlp guncellemesi gerekiyordur —
  paketi gonderen kisiden yeni surum isteyin.
'@ | Out-File (Join-Path $pkg "OKU-BENI.txt") -Encoding utf8

$zip = Join-Path $out "soundMatik-kurulum.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $pkg -DestinationPath $zip

Write-Host "Tamam:"
Write-Host "  Klasor: $pkg"
Write-Host ("  Zip   : {0}  ({1:N0} MB)" -f $zip, ((Get-Item $zip).Length / 1MB))
