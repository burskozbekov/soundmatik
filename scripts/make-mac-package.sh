#!/usr/bin/env bash
#
# Turnkey macOS build → sign → notarize → package for soundMatik.
# RUN THIS ON A MAC. It cannot be produced from Windows.
#
# ── One-time prerequisites ────────────────────────────────────────────────
#   1. Rust:        curl https://sh.rustup.rs -sSf | sh
#   2. Xcode CLT:   xcode-select --install
#   3. Node (for the panel build):  https://nodejs.org  (or `brew install node`)
#   4. Your "Developer ID Application" certificate in the login keychain
#      (Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ +  → Developer ID
#      Application). Confirm with:  security find-identity -v -p codesigning
#   5. Store a notarization profile ONCE (uses an app-specific password you
#      create at appleid.apple.com ▸ Sign-In & Security ▸ App-Specific Passwords):
#        xcrun notarytool store-credentials soundmatik-notary \
#          --apple-id "you@example.com" --team-id "YOURTEAMID" \
#          --password "xxxx-xxxx-xxxx-xxxx"
#
# ── Run ───────────────────────────────────────────────────────────────────
#   export SM_SIGN_ID="Developer ID Application: Your Name (YOURTEAMID)"
#   export SM_NOTARY_PROFILE="soundmatik-notary"
#   ./scripts/make-mac-package.sh
#
# If SM_SIGN_ID is unset the script auto-detects your Developer ID Application
# identity. Output: a signed+notarized+stapled dist-share/soundMatik-mac.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIDE="$ROOT/soundmatik-sidecar"
PANEL="$ROOT/soundmatik-panel"
OUT="$ROOT/dist-share/mac"
APP_NAME="soundMatik Helper.app"

NOTARY_PROFILE="${SM_NOTARY_PROFILE:-soundmatik-notary}"

log() { printf '\n\033[1;36m▸ %s\033[0m\n' "$1"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ── Resolve signing identity ───────────────────────────────────────────────
if [ -z "${SM_SIGN_ID:-}" ]; then
  SM_SIGN_ID="$(security find-identity -v -p codesigning \
    | grep 'Developer ID Application' | head -1 \
    | sed -E 's/.*"([^"]+)".*/\1/')"
  [ -n "$SM_SIGN_ID" ] || die "No 'Developer ID Application' identity found. See prerequisites (4)."
  log "Auto-detected signing identity: $SM_SIGN_ID"
fi

# ── 1. Bundled binaries ────────────────────────────────────────────────────
for b in yt-dlp ffmpeg ffprobe deno; do
  if [ ! -f "$SIDE/bin/mac/$b" ]; then
    log "Fetching macOS binaries (yt-dlp, ffmpeg, ffprobe, deno)..."
    "$SIDE/scripts/fetch-binaries.sh"
    break
  fi
done
for b in yt-dlp ffmpeg ffprobe deno; do
  [ -f "$SIDE/bin/mac/$b" ] || die "missing bundled binary: bin/mac/$b"
done

# ── 2. Build the sidecar (release) ─────────────────────────────────────────
log "Building sidecar (cargo release)..."
( cd "$SIDE" && cargo build --release )

# ── 3. Build the panel bundle ──────────────────────────────────────────────
log "Building panel..."
( cd "$PANEL" && npm install --silent && npm run build )

# ── 4. Assemble the .app bundle ────────────────────────────────────────────
log "Assembling $APP_NAME ..."
APP="$OUT/$APP_NAME"
rm -rf "$OUT"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin/mac"
cp "$SIDE/mac/Info.plist" "$APP/Contents/Info.plist"
cp "$SIDE/target/release/soundmatik-sidecar" "$APP/Contents/MacOS/soundmatik-sidecar"
cp "$SIDE/bin/mac/yt-dlp" "$SIDE/bin/mac/ffmpeg" "$SIDE/bin/mac/ffprobe" "$SIDE/bin/mac/deno" \
   "$APP/Contents/Resources/bin/mac/"
chmod +x "$APP/Contents/MacOS/soundmatik-sidecar" "$APP/Contents/Resources/bin/mac/"*

# ── 5. Codesign: inner executables first (hardened runtime + entitlements),
#       then seal the bundle. --deep is intentionally NOT used. ──────────────
ENT="$SIDE/mac/entitlements.plist"
log "Codesigning bundled binaries..."
for b in yt-dlp ffmpeg ffprobe deno; do
  codesign --force --options runtime --timestamp \
    --entitlements "$ENT" --sign "$SM_SIGN_ID" \
    "$APP/Contents/Resources/bin/mac/$b"
done
log "Codesigning the app bundle..."
codesign --force --options runtime --timestamp \
  --entitlements "$ENT" --sign "$SM_SIGN_ID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" || die "codesign verify failed"

# ── 6. Notarize ────────────────────────────────────────────────────────────
log "Notarizing (uploading to Apple, this can take a few minutes)..."
ZIP="$OUT/_notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
if ! xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait; then
  echo "Notarization failed. Get the detailed log with:"
  echo "  xcrun notarytool history --keychain-profile \"$NOTARY_PROFILE\""
  echo "  xcrun notarytool log <submission-id> --keychain-profile \"$NOTARY_PROFILE\""
  echo "Then adjust soundmatik-sidecar/mac/entitlements.plist and re-run."
  die "notarytool rejected the bundle"
fi
rm -f "$ZIP"

# ── 7. Staple ──────────────────────────────────────────────────────────────
log "Stapling ticket..."
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv --type exec "$APP" || true

# ── 8. Build the .ccx (panel — JS/HTML only, no notarization needed) ───────
log "Packaging soundMatik.ccx ..."
STAGE="$OUT/_ccx"; rm -rf "$STAGE"; mkdir -p "$STAGE/dist"
cp "$PANEL/manifest.json" "$PANEL/index.html" "$STAGE/"
cp "$PANEL/dist/index.js" "$STAGE/dist/"
cp -R "$PANEL/icons" "$STAGE/"
rm -rf "$STAGE/icons/source"
( cd "$STAGE" && zip -qr "$OUT/soundMatik.ccx" . )
rm -rf "$STAGE"

# ── 9. Build the installer applet (TINY — payload lives on the DMG, step 10) ─
# A .command shell script CANNOT be notarized and macOS 15+ removed the
# right-click▸Open bypass, so we ship a signed+notarized AppleScript applet.
#
# CRITICAL: the applet must stay tiny (a few KB). It does NOT embed the ~130MB
# helper. When a quarantined app is run from a downloaded DMG, macOS
# "translocates" it — copies the whole bundle to a random temp mount and
# re-runs Gatekeeper on it. A 130MB embedded-payload applet stalls for minutes
# at first launch (observed hanging in _dyld_start). A KB-sized applet launches
# instantly. It copies the helper from a hidden .payload folder on the DMG
# volume (a real /Volumes path, reachable even when the applet is translocated).
log "Building Install soundMatik.app (tiny applet) ..."
INSTALLER="$OUT/Install soundMatik.app"
rm -rf "$INSTALLER"
OSA="$OUT/_installer.applescript"
cat > "$OSA" <<'EOF'
on run
	-- Raise the default 120s AppleEvent limit: a slow Creative Cloud start
	-- would otherwise throw -1712 ("AppleEvent timed out").
	with timeout of 3600 seconds
		-- Destination via the shell ($HOME) so it is correct even if this
		-- applet was launched translocated (path-to-me points at a temp copy).
		set homeDir to do shell script "echo $HOME"
		set destRoot to homeDir & "/Library/Application Support/soundMatik/"

		-- Locate the payload (hidden .payload folder shipped on the DMG). Try
		-- next to ourselves first (app run in place from the DMG), then find the
		-- mounted volume by name (app run translocated from a temp copy).
		set src to ""
		try
			set myParent to do shell script "dirname " & quoted form of (POSIX path of (path to me))
			if (do shell script "test -d " & quoted form of (myParent & "/.payload") & " && echo yes || echo no") is "yes" then
				set src to myParent & "/.payload/"
			end if
		end try
		if src is "" then
			try
				set found to do shell script "ls -d /Volumes/Install*soundMatik*/.payload 2>/dev/null | head -1"
				if found is not "" then set src to found & "/"
			end try
		end if
		if src is "" then
			display dialog "Could not find the soundMatik install files. Open the soundMatik disk image first, then double-click \"Install soundMatik\" inside it." buttons {"OK"} default button "OK" with title "soundMatik" with icon caution giving up after 600
			return
		end if

		do shell script "mkdir -p " & quoted form of destRoot
		do shell script "pkill -f soundmatik-sidecar 2>/dev/null; true"
		do shell script "rm -rf " & quoted form of (destRoot & "soundMatik Helper.app")
		do shell script "cp -R " & quoted form of (src & "soundMatik Helper.app") & " " & quoted form of destRoot
		do shell script "xattr -dr com.apple.quarantine " & quoted form of (destRoot & "soundMatik Helper.app") & " 2>/dev/null; true"
		-- Pre-launch the helper now so macOS does its first-run verification
		-- during install (while the user expects to wait), not on first download.
		do shell script "open " & quoted form of (destRoot & "soundMatik Helper.app")
		try
			do shell script "open " & quoted form of (src & "soundMatik.ccx")
			display dialog "soundMatik is installed!" & return & return & "1) Approve the Creative Cloud window that just opened." & return & "2) Restart Premiere Pro." & return & "3) Open: Window > Extensions (UXP) > soundMatik" buttons {"OK"} default button "OK" with title "soundMatik" with icon note giving up after 600
		on error
			display dialog "The helper is installed, but the panel installer could not be opened." & return & return & "Make sure Adobe Creative Cloud is installed and running, then double-click this installer again." buttons {"OK"} default button "OK" with title "soundMatik" with icon caution giving up after 600
		end try
	end timeout
end run
EOF
osacompile -o "$INSTALLER" "$OSA"
rm -f "$OSA"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.soundmatik.installer" "$INSTALLER/Contents/Info.plist" \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.soundmatik.installer" "$INSTALLER/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Install soundMatik" "$INSTALLER/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleName string Install soundMatik" "$INSTALLER/Contents/Info.plist"

log "Codesigning the installer applet..."
codesign --force --options runtime --timestamp --sign "$SM_SIGN_ID" "$INSTALLER"
codesign --verify --deep --strict --verbose=2 "$INSTALLER" || die "installer codesign verify failed"

log "Notarizing the installer applet (tiny — fast)..."
ZIP="$OUT/_notarize-installer.zip"
ditto -c -k --keepParent "$INSTALLER" "$ZIP"
if ! xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait; then
  echo "Installer notarization failed — see: xcrun notarytool history/log ..."
  die "notarytool rejected the installer"
fi
rm -f "$ZIP"
xcrun stapler staple "$INSTALLER"
xcrun stapler validate "$INSTALLER"
spctl -a -vvv --type exec "$INSTALLER" || true

# ── 10. Package the installer into a signed + notarized + stapled DMG ───────
# One double-click file, no zip: the user opens the DMG (Gatekeeper-silent
# because it's notarized) and double-clicks "Install soundMatik.app" inside.
# A DMG only needs the Developer ID *Application* cert (which we have); a
# notarizable .pkg would need a Developer ID *Installer* cert (which we don't).
log "Building soundMatik-mac.dmg ..."
DMG="$ROOT/dist-share/soundMatik-mac.dmg"
VOLNAME="Install soundMatik"

# Stage the app in a folder and point hdiutil at the FOLDER (never the .app
# itself — hdiutil copies a folder's *contents* to the volume root, so a bare
# .app would scatter its Contents/ across the root instead of appearing as a
# single "Install soundMatik.app" icon). The heavy payload (helper .app +
# .ccx) rides along in a HIDDEN .payload folder so the volume shows only the
# installer + a README — the applet copies from .payload at install time.
STAGE_DMG="$OUT/_dmg"
rm -rf "$STAGE_DMG"; mkdir -p "$STAGE_DMG/.payload"
cp -R "$INSTALLER" "$STAGE_DMG/"
cp -R "$APP" "$STAGE_DMG/.payload/"                 # notarized+stapled helper .app
cp "$OUT/soundMatik.ccx" "$STAGE_DMG/.payload/"     # panel package (opened via Creative Cloud)
cat > "$STAGE_DMG/READ ME.txt" <<'EOF'
soundMatik — install for Adobe Premiere Pro 2026 (macOS · Apple Silicon)

Double-click "Install soundMatik.app".
  • Approve the plugin in the Creative Cloud window that opens.
  • Restart Premiere Pro, then: Window > Extensions (UXP) > soundMatik

Everything is signed and notarized by Apple — no security warnings.
by Sevki Bugra Ozbek · catheadai.com
EOF

rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE_DMG" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG"
rm -rf "$STAGE_DMG"

# Sign the disk image itself (a .dmg is data, not code: Developer ID
# Application + timestamp ONLY — never --options runtime / --entitlements).
# The app inside keeps its own hardened-runtime signature + staple from step 9.
log "Codesigning the DMG..."
codesign --force --timestamp --sign "$SM_SIGN_ID" "$DMG"
codesign --verify --verbose=2 "$DMG" || die "DMG codesign verify failed"

# Notarize the DMG (notarytool takes a .dmg directly — no zip wrapper).
log "Notarizing the DMG (uploading to Apple, a few minutes)..."
if ! xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait; then
  echo "DMG notarization failed — see: xcrun notarytool history/log ..."
  die "notarytool rejected the DMG"
fi
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
# DMG Gatekeeper assessment uses -t open (apps use -t exec):
spctl -a -t open --context context:primary-signature -vvv "$DMG" || die "DMG failed Gatekeeper assessment"

log "Done."
echo "  Helper app (signed+notarized+stapled):    $APP"
echo "  Installer app (signed+notarized+stapled): $INSTALLER"
echo "  Installer DMG (signed+notarized+stapled): $DMG"
