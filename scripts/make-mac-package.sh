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
# identity. Output: dist-share/mac/soundMatik/  and  dist-share/soundMatik-mac.zip
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
if [ ! -f "$SIDE/bin/mac/yt-dlp" ]; then
  log "Fetching macOS binaries (yt-dlp, ffmpeg, deno)..."
  "$SIDE/scripts/fetch-binaries.sh"
fi

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
( cd "$STAGE" && zip -qr "$OUT/soundMatik.ccx" . )
rm -rf "$STAGE"

# ── 9. Build the installer applet ──────────────────────────────────────────
# A .command shell script CANNOT be notarized (Apple only notarizes Mach-O /
# .app / .pkg / .dmg), and macOS 15+ removed the right-click▸Open bypass, so
# an unsigned script greets users with a "Move to Trash" dialog. Instead we
# ship a signed+notarized AppleScript applet with the helper .app and the
# .ccx embedded in its Resources — double-click, zero warnings.
log "Building Install soundMatik.app ..."
INSTALLER="$OUT/Install soundMatik.app"
rm -rf "$INSTALLER"
OSA="$OUT/_installer.applescript"
cat > "$OSA" <<'EOF'
on run
	-- Raise the default 120s AppleEvent limit: an unattended dialog or a slow
	-- Creative Cloud start would otherwise throw -1712 ("AppleEvent timed out").
	with timeout of 3600 seconds
		set appPath to POSIX path of (path to me)
		set res to appPath & "Contents/Resources/"
		set destRoot to (POSIX path of (path to application support folder from user domain)) & "soundMatik/"
		do shell script "mkdir -p " & quoted form of destRoot
		do shell script "pkill -f soundmatik-sidecar 2>/dev/null; true"
		do shell script "rm -rf " & quoted form of (destRoot & "soundMatik Helper.app")
		do shell script "cp -R " & quoted form of (res & "soundMatik Helper.app") & " " & quoted form of destRoot
		do shell script "xattr -dr com.apple.quarantine " & quoted form of (destRoot & "soundMatik Helper.app") & " 2>/dev/null; true"
		-- Pre-launch the helper now so macOS does its first-run verification
		-- during install (while the user expects to wait), not on first download.
		do shell script "open " & quoted form of (destRoot & "soundMatik Helper.app")
		try
			do shell script "open " & quoted form of (res & "soundMatik.ccx")
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
cp -R "$APP" "$INSTALLER/Contents/Resources/"
mv "$OUT/soundMatik.ccx" "$INSTALLER/Contents/Resources/"

log "Codesigning the installer..."
codesign --force --options runtime --timestamp --sign "$SM_SIGN_ID" "$INSTALLER"
codesign --verify --deep --strict --verbose=2 "$INSTALLER" || die "installer codesign verify failed"

log "Notarizing the installer..."
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

# ── 10. Assemble share package ─────────────────────────────────────────────
log "Assembling share package..."
PKG="$OUT/soundMatik"
rm -rf "$PKG"; mkdir -p "$PKG"
cp -R "$INSTALLER" "$PKG/"

cat > "$PKG/README.txt" <<'EOF'
soundMatik — download audio from any video link (Premiere Pro 2026+)
by Sevki Bugra Ozbek · catheadai.com   (macOS version)

REQUIREMENT: Apple Silicon (M1 or newer) Mac.
(Intel Macs are not supported.)

INSTALL
1) Double-click "Install soundMatik.app".
   (The first launch can take 10-20 seconds while macOS verifies the app —
   that's normal, just wait.)
2) Approve the plugin install in the Creative Cloud window that opens.
3) Restart Premiere Pro.
4) In Premiere: Window > Extensions (UXP) > soundMatik

Everything is signed and notarized by Apple — no security warnings.

USAGE
- Paste a video link, choose WAV/MP3, click DOWNLOAD AUDIO.
- The audio file lands in <project folder>/SOUND_EFFECTS/ and is added
  automatically to the SOUND_EFFECTS bin in the Project panel.
- Your project must have been saved at least once.
EOF

FINAL_ZIP="$ROOT/dist-share/soundMatik-mac.zip"
rm -f "$FINAL_ZIP"
( cd "$OUT" && zip -qr "$FINAL_ZIP" "soundMatik" )

log "Done."
echo "  Helper app (signed+notarized+stapled):    $APP"
echo "  Installer app (signed+notarized+stapled): $INSTALLER"
echo "  Share folder: $PKG"
echo "  Share zip:    $FINAL_ZIP"
