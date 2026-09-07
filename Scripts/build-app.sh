#!/bin/bash
# Builds the GaithanoSpeak executable via SPM and wraps it into a signed .app
# bundle. Signing with a stable Apple Development identity keeps TCC/Accessibility
# grants alive across rebuilds (see the plan's "TCC breaks between dev builds").
#
# Usage: Scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

APP_NAME="Gaithano Speak"
BUNDLE_ID="com.gaithano.speak"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Building ($CONFIG)…"
cd "$ROOT"
swift build -c "$CONFIG"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/GaithanoSpeak" "$APP/Contents/MacOS/GaithanoSpeak"
# Copy any SPM resource bundles (FluidAudio ships CoreML/resource bundles).
find "$BIN_PATH" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;
# Copied files come from .build read-only; make the bundle writable for signing.
chmod -R u+w "$APP"

# Info.plist with the exact keys the app needs (LSUIElement, mic usage, etc.).
cp "$ROOT/GaithanoSpeak/Info.plist" "$APP/Contents/Info.plist"
# App icon (built from the logo via Scripts/makeicon or committed AppIcon.icns).
if [ -f "$ROOT/GaithanoSpeak/AppIcon.icns" ]; then
  cp "$ROOT/GaithanoSpeak/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
# Bundled image resources (logo mark used in the overlay, etc.), and the Qwen3-TTS
# sidecar. The .py has to be copied here rather than declared as an SPM resource: the
# app target is an executable wrapped by this script, so `Bundle.module` doesn't exist
# and `Bundle.main` is whatever this assembles.
if [ -d "$ROOT/GaithanoSpeak/Resources" ]; then
  cp "$ROOT/GaithanoSpeak/Resources/"*.png "$APP/Contents/Resources/" 2>/dev/null || true
  cp "$ROOT/GaithanoSpeak/Resources/"*.py "$APP/Contents/Resources/" 2>/dev/null || true
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable GaithanoSpeak" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleName GaithanoSpeak" "$APP/Contents/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 26.0" "$APP/Contents/Info.plist" 2>/dev/null || true

# Pick a stable signing identity: prefer a real Apple Development cert so TCC
# grants persist; fall back to ad-hoc (grants will reset each rebuild).
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Apple Development' | awk '{print $2}' || true)"
if [ -z "$IDENTITY" ]; then
  echo "==> No Apple Development identity found; signing ad-hoc (TCC grants will reset per build)."
  IDENTITY="-"
fi

echo "==> Signing with: $IDENTITY"
# Sign nested resource bundles first (no --deep, which is deprecated), clearing
# the FinderInfo/resource-fork xattrs codesign rejects before each step.
# `xattr -cr` (recursive form) is required — `find -exec xattr -c` misses FinderInfo.
while IFS= read -r bundle; do
  chmod -R u+w "$bundle"; xattr -cr "$bundle"
  codesign --force --sign "$IDENTITY" "$bundle"
done < <(find "$APP/Contents/Resources" -maxdepth 1 -name "*.bundle")

# A file-provider-synced folder (iCloud/Documents) keeps re-adding
# com.apple.FinderInfo to bundle directories, racing the sign. FinderInfo isn't
# part of the content seal, so retry clear-then-sign until we win the race.
chmod -R u+w "$APP"
signed=0
for attempt in 1 2 3 4 5; do
  xattr -cr "$APP"
  # NOTE: no --options runtime for dev builds. Hardened runtime blocks the private
  # MediaRemote framework (breaks pause-media-while-listening). Re-enable it ONLY
  # for a notarized distribution build.
  if codesign --force \
      --entitlements "$ROOT/GaithanoSpeak/GaithanoSpeak.entitlements" \
      --sign "$IDENTITY" "$APP" 2>/dev/null; then
    signed=1; break
  fi
  echo "   (sign attempt $attempt hit the FinderInfo race; retrying)"
done
[ "$signed" = 1 ] || { echo "ERROR: signing failed after retries"; exit 1; }

# Clear any FinderInfo the sync re-added post-sign so strict verify passes.
xattr -cr "$APP" 2>/dev/null || true

echo "==> Verifying signature…"
codesign --verify --strict --verbose=2 "$APP" || {
  # One more clear+verify in case sync raced the verify too.
  xattr -cr "$APP"; codesign --verify --strict "$APP"
}

echo "==> Done: $APP"
