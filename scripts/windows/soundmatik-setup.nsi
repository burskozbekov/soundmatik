; soundmatik-setup.nsi
; Per-user (no admin) single-file installer for soundMatik
;   soundMatik = Adobe Premiere Pro 2026 UXP panel + local Rust helper.
;
; Build (on macOS or Windows) with stock makensis 3.x:
;   makensis -DVERSION=0.1.5 -DPAYLOAD=/abs/path/to/staging \
;            -DOUTFILE=/abs/path/soundMatik-Setup.exe scripts/windows/soundmatik-setup.nsi
;
; Produces: soundMatik-Setup.exe  (per-user, RequestExecutionLevel user)
;
; PAYLOAD staging-dir layout:
;   <PAYLOAD>/
;     helper/
;       soundmatik-sidecar.exe
;       bin/win/{yt-dlp.exe,ffmpeg.exe,ffprobe.exe,deno.exe}
;     panel/
;       manifest.json
;       index.html
;       dist/index.js
;       icons/{icon.png,icon@2x.png,plugin-icon.png,plugin-icon@2x.png}
;     register-panel.ps1

;--------------------------------------------------------------------------
; Required parameters (passed by the packaging script via -D)
;--------------------------------------------------------------------------
!ifndef VERSION
  !error "VERSION is not defined. Compile with -DVERSION=0.1.5"
!endif
!ifndef PAYLOAD
  !error "PAYLOAD is not defined. Compile with -DPAYLOAD=<staging dir>"
!endif

!ifndef OUTFILE
  !define OUTFILE "soundMatik-Setup.exe"
!endif

;--------------------------------------------------------------------------
; Constants
;--------------------------------------------------------------------------
!define PRODUCT       "soundMatik"
!define PUBLISHER     "Sevki Bugra Ozbek"
!define PANEL_ID      "com.soundmatik.panel"
!define HELPER_EXE    "soundmatik-sidecar.exe"
!define WEBSITE       "https://github.com/burskozbekov/soundmatik"

; Panel lives here (per-user Adobe UXP "external" plugins root)
!define PANEL_ROOT    "$APPDATA\Adobe\UXP\Plugins\External"
!define PANEL_DIR     "${PANEL_ROOT}\${PANEL_ID}_${VERSION}"

; HKCU Add/Remove Programs key (per-user, no admin needed)
!define UNINST_KEY    "Software\Microsoft\Windows\CurrentVersion\Uninstall\${PRODUCT}"

;--------------------------------------------------------------------------
; Global installer settings
;--------------------------------------------------------------------------
; ANSI, not Unicode: makensis 3.12's UNICODE output writer aborts with
; std::bad_alloc on macOS 26 (reproduced on a 3-line script; the ANSI writer
; works). All of soundMatik's install paths/strings are pure ASCII
; (com.soundmatik.panel, soundMatik, %APPDATA%...), so ANSI is lossless here.
; The panel's premierepro.json is still written as BOM-less UTF-8 by
; register-panel.ps1 (PowerShell), independent of the installer's charset.
Unicode false
Name "${PRODUCT} ${VERSION}"
OutFile "${OUTFILE}"
RequestExecutionLevel user          ; per-user; never elevate
InstallDir "$LOCALAPPDATA\soundMatik"
SetCompressor /SOLID lzma
ShowInstDetails show
ShowUninstDetails show
AutoCloseWindow false
BrandingText "${PRODUCT} ${VERSION}"

; Optional custom icons (pass -DICON=... / -DUNICON=... a .ico each). Safe to omit.
!ifdef ICON
  !define MUI_ICON "${ICON}"
!endif
!ifdef UNICON
  !define MUI_UNICON "${UNICON}"
!endif

;--------------------------------------------------------------------------
; Version info (embedded in the .exe). VERSION must be numeric X.Y.Z.
;--------------------------------------------------------------------------
VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName"     "${PRODUCT}"
VIAddVersionKey "FileDescription" "${PRODUCT} installer"
VIAddVersionKey "CompanyName"     "${PUBLISHER}"
VIAddVersionKey "LegalCopyright"  "(c) ${PUBLISHER}"
VIAddVersionKey "FileVersion"     "${VERSION}.0"
VIAddVersionKey "ProductVersion"  "${VERSION}"

;--------------------------------------------------------------------------
; Includes
;--------------------------------------------------------------------------
!include "MUI2.nsh"
!include "FileFunc.nsh"   ; ${GetSize}
!include "LogicLib.nsh"   ; ${If}/${Else}, ${FileExists}

; Full path to Adobe's Unified Plugin Installer Agent, or "" if Creative Cloud
; Desktop isn't installed. Set by FindUPIA.
Var UPIA

;--------------------------------------------------------------------------
; MUI pages
;--------------------------------------------------------------------------
!define MUI_ABORTWARNING

!define MUI_WELCOMEPAGE_TITLE "Install ${PRODUCT} ${VERSION}"
!define MUI_WELCOMEPAGE_TEXT "This will install the ${PRODUCT} panel for Adobe Premiere Pro 2026 and its local download helper.$\r$\n$\r$\nNo administrator rights are needed - everything is installed for the current user only.$\r$\n$\r$\nPlease quit Adobe Premiere Pro before continuing."
!insertmacro MUI_PAGE_WELCOME

!insertmacro MUI_PAGE_INSTFILES

!define MUI_FINISHPAGE_TITLE "${PRODUCT} is installed"
!define MUI_FINISHPAGE_TEXT "Almost done!$\r$\n$\r$\n1. Fully quit Adobe Premiere Pro (close every window), then reopen it.$\r$\n$\r$\n2. Open the panel from:   Window > UXP Plugins > soundMatik$\r$\n$\r$\nThen paste a video link into the panel to pull its audio (WAV or MP3) straight into your project's SOUND_EFFECTS bin."
!define MUI_FINISHPAGE_LINK "${PRODUCT} on GitHub"
!define MUI_FINISHPAGE_LINK_LOCATION "${WEBSITE}"
!insertmacro MUI_PAGE_FINISH

; Uninstaller pages
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

;--------------------------------------------------------------------------
; Helpers
;--------------------------------------------------------------------------

; Locate Adobe's Unified Plugin Installer Agent (ships with Creative Cloud
; Desktop). It's the ONLY reliable way to register a UXP panel so Premiere
; loads it -- a hand-written premierepro.json entry is not a load path Premiere
; honors. Checks the 64- and 32-bit Common Files roots. Sets $UPIA ("" if none).
!macro FindUPIA
  StrCpy $UPIA ""
  StrCpy $R6 "$PROGRAMFILES64\Common Files\Adobe\Adobe Desktop Common\RemoteComponents\UPI\UnifiedPluginInstallerAgent\UnifiedPluginInstallerAgent.exe"
  ${If} ${FileExists} "$R6"
    StrCpy $UPIA "$R6"
  ${Else}
    StrCpy $R6 "$PROGRAMFILES32\Common Files\Adobe\Adobe Desktop Common\RemoteComponents\UPI\UnifiedPluginInstallerAgent\UnifiedPluginInstallerAgent.exe"
    ${If} ${FileExists} "$R6"
      StrCpy $UPIA "$R6"
    ${EndIf}
  ${EndIf}
!macroend

; Stop a running helper so its .exe files aren't locked during copy/removal.
; /T kills the ffmpeg/deno child tree too; then give the OS + any AV real-time
; scan a moment to release the exe handles before we overwrite them.
!macro KillHelper
  DetailPrint "Stopping ${HELPER_EXE} (if running)..."
  nsExec::Exec 'taskkill /IM ${HELPER_EXE} /F /T'
  Pop $0
  Sleep 1500
!macroend

; Remove every previously-installed panel folder:
;   com.soundmatik.panel        (old unversioned Creative-Cloud style)
;   com.soundmatik.panel_<any>  (any versioned install)
; Two-phase (collect-then-delete): deleting entries mid-FindNext can make the
; enumeration skip siblings, so first push all matching names onto the stack
; (below a sentinel), close the search, then pop and delete each. UID keeps
; labels unique per expansion site (install vs uninstall).
!macro RemovePanelFolders UID
  DetailPrint "Removing previous soundMatik panel folders..."
  RMDir /r "${PANEL_ROOT}\${PANEL_ID}"
  StrCpy $R0 "${PANEL_ROOT}"
  Push "___rpf_end_${UID}___"
  FindFirst $R1 $R2 "$R0\${PANEL_ID}_*"
  rpf_collect_${UID}:
    StrCmp $R2 "" rpf_collected_${UID}
    Push "$R2"
    FindNext $R1 $R2
    Goto rpf_collect_${UID}
  rpf_collected_${UID}:
  FindClose $R1
  rpf_del_${UID}:
    Pop $R2
    StrCmp $R2 "___rpf_end_${UID}___" rpf_done_${UID}
    RMDir /r "$R0\$R2"
    Goto rpf_del_${UID}
  rpf_done_${UID}:
!macroend

; Clear the per-plugin UXP storage caches for every Premiere version
; (PluginsStorage\PPRO\<ver>\{External,Developer}\<id>). A stale storage
; entry left by an older install (or a UXP Developer Tool session) can
; reference a now-deleted panel path and keep the freshly registered panel
; from ever appearing in Window > Extensions (UXP). Deleting it is safe -
; the host recreates it on the next successful load.
!macro RemoveStorageFolders UID
  DetailPrint "Clearing stale UXP plugin storage..."
  StrCpy $R3 "$APPDATA\Adobe\UXP\PluginsStorage\PPRO"
  Push "___rsf_end_${UID}___"
  FindFirst $R4 $R5 "$R3\*"
  rsf_collect_${UID}:
    StrCmp $R5 "" rsf_collected_${UID}
    StrCmp $R5 "." rsf_next_${UID}
    StrCmp $R5 ".." rsf_next_${UID}
    Push "$R5"
  rsf_next_${UID}:
    FindNext $R4 $R5
    Goto rsf_collect_${UID}
  rsf_collected_${UID}:
  FindClose $R4
  rsf_del_${UID}:
    Pop $R5
    StrCmp $R5 "___rsf_end_${UID}___" rsf_done_${UID}
    RMDir /r "$R3\$R5\External\${PANEL_ID}"
    RMDir /r "$R3\$R5\Developer\${PANEL_ID}"
    Goto rsf_del_${UID}
  rsf_done_${UID}:
!macroend

;--------------------------------------------------------------------------
; Install
;--------------------------------------------------------------------------
Section "soundMatik" SecMain
  SetShellVarContext current        ; $APPDATA / $LOCALAPPDATA = current user
  SetOverwrite on

  ; 1) Stop any running helper
  !insertmacro KillHelper

  ; 2) Helper -> %LOCALAPPDATA%\soundMatik  (sidecar at root, exes in bin\win)
  ; NOTE: File SOURCE paths use forward slashes so this compiles on macOS/Linux
  ; hosts too (POSIX makensis does not convert backslashes in source paths).
  ; DESTINATION paths (SetOutPath, $INSTDIR\...) stay backslashed - they are
  ; Windows runtime paths.
  DetailPrint "Installing helper to $INSTDIR ..."
  SetOutPath "$INSTDIR"
  File "${PAYLOAD}/helper/${HELPER_EXE}"
  File "${PAYLOAD}/register-panel.ps1"       ; bundled for the manual fallback
  File "${PAYLOAD}/soundMatik.ccx"           ; panel package for the UPIA install
  SetOutPath "$INSTDIR\bin\win"
  File "${PAYLOAD}/helper/bin/win/yt-dlp.exe"
  File "${PAYLOAD}/helper/bin/win/ffmpeg.exe"
  File "${PAYLOAD}/helper/bin/win/ffprobe.exe"
  File "${PAYLOAD}/helper/bin/win/deno.exe"

  ; 3) Clean up any older panel copies (folders + stale UXP storage) first.
  !insertmacro RemovePanelFolders "install"
  !insertmacro RemoveStorageFolders "install"

  ; 4) Install the panel the way Adobe actually loads it: hand the .ccx to the
  ;    Unified Plugin Installer Agent -- exactly what double-clicking the .ccx in
  ;    Creative Cloud does. Premiere does NOT honor a hand-written
  ;    premierepro.json entry, so UPIA is the primary path.
  !insertmacro FindUPIA
  ${If} $UPIA != ""
    DetailPrint "Installing panel via Adobe Creative Cloud plugin installer..."
    nsExec::ExecToLog '"$UPIA" /install "$INSTDIR\soundMatik.ccx"'
    Pop $0
    ${If} $0 == "0"
      DetailPrint "Panel installed and registered with Premiere Pro."
      Goto panel_done
    ${EndIf}
    DetailPrint "UPIA returned $0 - falling back to a manual install."
  ${Else}
    DetailPrint "Creative Cloud plugin installer not found - manual install."
  ${EndIf}

  ; 4b) Fallback (no Creative Cloud, or UPIA failed): copy the panel into the
  ;     External folder and register it. This route needs the user to enable
  ;     Developer Mode in Premiere.
  DetailPrint "Installing panel to ${PANEL_DIR} ..."
  SetOutPath "${PANEL_DIR}"
  File "${PAYLOAD}/panel/manifest.json"
  File "${PAYLOAD}/panel/index.html"
  SetOutPath "${PANEL_DIR}\dist"
  File "${PAYLOAD}/panel/dist/index.js"
  SetOutPath "${PANEL_DIR}\icons"
  File "${PAYLOAD}/panel/icons/icon.png"
  File "${PAYLOAD}/panel/icons/icon@2x.png"
  File "${PAYLOAD}/panel/icons/plugin-icon.png"
  File "${PAYLOAD}/panel/icons/plugin-icon@2x.png"
  nsExec::ExecToLog 'powershell -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\register-panel.ps1" -Version "${VERSION}"'
  Pop $0
  MessageBox MB_OK|MB_ICONINFORMATION "soundMatik's panel files are installed, but Adobe Creative Cloud wasn't available to register the panel automatically.$\r$\n$\r$\nTo make the panel appear:$\r$\n1. Open Premiere Pro > Settings > Plugins$\r$\n2. Tick 'Enable developer mode'$\r$\n3. Fully quit and reopen Premiere Pro$\r$\n$\r$\nThen: Window > UXP Plugins > soundMatik"
  panel_done:

  ; 6) Write uninstaller + Add/Remove Programs (HKCU, per-user)
  SetOutPath "$INSTDIR"
  WriteUninstaller "$INSTDIR\Uninstall.exe"

  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0

  WriteRegStr   HKCU "${UNINST_KEY}" "DisplayName"     "${PRODUCT}"
  WriteRegStr   HKCU "${UNINST_KEY}" "DisplayVersion"  "${VERSION}"
  WriteRegStr   HKCU "${UNINST_KEY}" "Publisher"       "${PUBLISHER}"
  WriteRegStr   HKCU "${UNINST_KEY}" "DisplayIcon"     "$INSTDIR\Uninstall.exe"
  WriteRegStr   HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr   HKCU "${UNINST_KEY}" "URLInfoAbout"    "${WEBSITE}"
  WriteRegStr   HKCU "${UNINST_KEY}" "UninstallString"      '"$INSTDIR\Uninstall.exe"'
  WriteRegStr   HKCU "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\Uninstall.exe" /S'
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1
  WriteRegDWORD HKCU "${UNINST_KEY}" "EstimatedSize" $0
SectionEnd

;--------------------------------------------------------------------------
; Uninstall
;--------------------------------------------------------------------------
Section "Uninstall"
  SetShellVarContext current

  ; Stop the helper
  DetailPrint "Stopping ${HELPER_EXE} (if running)..."
  nsExec::Exec 'taskkill /IM ${HELPER_EXE} /F /T'
  Pop $0
  Sleep 600

  ; Un-register the panel. First via UPIA (undoes the Creative Cloud install),
  ; then the manual premierepro.json entry (undoes the fallback path). Both are
  ; harmless no-ops if that path wasn't used. Must run before we delete $INSTDIR.
  !insertmacro FindUPIA
  ${If} $UPIA != ""
    DetailPrint "Removing panel via Adobe Creative Cloud plugin installer..."
    nsExec::ExecToLog '"$UPIA" /remove com.soundmatik.panel'
    Pop $0
  ${EndIf}
  IfFileExists "$INSTDIR\register-panel.ps1" 0 skip_unreg
    DetailPrint "Removing manual panel registration..."
    nsExec::ExecToLog 'powershell -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\register-panel.ps1" -Remove'
    Pop $0
  skip_unreg:

  ; Remove panel folder(s)
  !insertmacro RemovePanelFolders "uninstall"
  !insertmacro RemoveStorageFolders "uninstall"

  ; Remove the helper folder (also holds register-panel.ps1 and Uninstall.exe;
  ; the running uninstaller has already relocated itself to %TEMP%, so this
  ; deletes cleanly).
  DetailPrint "Removing helper..."
  RMDir /r "$INSTDIR"

  ; Remove Add/Remove Programs entry
  DeleteRegKey HKCU "${UNINST_KEY}"
SectionEnd
