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
PKG="$OUT/soundMatik"
mkdir -p "$PKG"
STAGE="$OUT/_ccx"; rm -rf "$STAGE"; mkdir -p "$STAGE/dist"
cp "$PANEL/manifest.json" "$PANEL/index.html" "$STAGE/"
cp "$PANEL/dist/index.js" "$STAGE/dist/"
cp -R "$PANEL/icons" "$STAGE/"
( cd "$STAGE" && ditto -c -k --keepParent . "$OUT/soundMatik.ccx.zip" >/dev/null )
# ditto --keepParent nests one dir; re-zip flat instead:
rm -f "$OUT/soundMatik.ccx.zip"
( cd "$STAGE" && zip -qr "$PKG/soundMatik.ccx" . )
rm -rf "$STAGE"

# ── 9. Assemble share package ──────────────────────────────────────────────
log "Assembling share package..."
cp -R "$APP" "$PKG/"

cat > "$PKG/KURULUM.command" <<'EOF'
#!/bin/bash
cd "$(dirname "$0")"
echo "soundMatik kuruluyor..."
DEST="$HOME/Library/Application Support/soundMatik"
mkdir -p "$DEST"
pkill -f soundmatik-sidecar 2>/dev/null || true
rm -rf "$DEST/soundMatik Helper.app"
cp -R "soundMatik Helper.app" "$DEST/"
xattr -dr com.apple.quarantine "$DEST/soundMatik Helper.app" 2>/dev/null || true
echo "Yardimci program kuruldu: $DEST"
echo "Panel yukleniyor (Creative Cloud penceresini onaylayin)..."
open "soundMatik.ccx"
echo ""
echo "Bitti! Premiere Pro'yu yeniden baslatin, sonra:"
echo "Window > Extensions (UXP) > soundMatik"
read -n 1 -s -r -p "Kapatmak icin bir tusa basin..."
EOF
chmod +x "$PKG/KURULUM.command"

cat > "$PKG/OKU-BENI.txt" <<'EOF'
soundMatik — video linkinden ses indirme paneli (Premiere Pro 2026+)
by Sevki Bugra Ozbek · catheadai.com   (macOS surumu)

KURULUM
1) KURULUM.command dosyasina cift tiklayin.
   Eger "acilamiyor / gelistirici dogrulanamadi" derse: sag tik > Ac > Ac.
   (Alternatif: Terminal'de  bash KURULUM.command  yazin.)
2) Acilan Creative Cloud penceresinde eklenti kurulumunu onaylayin.
3) Premiere Pro'yu yeniden baslatin.
4) Premiere'de: Window > Extensions (UXP) > soundMatik

Yardimci program imzali ve Apple tarafindan onaylidir (notarized), bu yuzden
calisrken ek bir guvenlik uyarisi cikmaz.

KULLANIM
- Video linkini yapistirin, WAV/MP3 secin, DOWNLOAD AUDIO'ya basin.
- Ses dosyasi <proje klasoru>/SOUND_EFFECTS/ icine iner ve Project panelindeki
  SOUND_EFFECTS bin'ine otomatik eklenir.
- Projenizin en az bir kez kaydedilmis olmasi gerekir.
EOF

FINAL_ZIP="$ROOT/dist-share/soundMatik-mac.zip"
rm -f "$FINAL_ZIP"
( cd "$OUT" && zip -qr "$FINAL_ZIP" "soundMatik" )

log "Done."
echo "  App (signed+notarized+stapled): $APP"
echo "  Share folder: $PKG"
echo "  Share zip:    $FINAL_ZIP"
