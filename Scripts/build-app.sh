#!/usr/bin/env bash
#
# Builds the VoiceDictation menu-bar app into a runnable .app bundle.
#
# We use an SPM executable plus this bundling step (rather than an Xcode
# project) so the whole build is reproducible headlessly - it needs only the
# Swift toolchain / Command Line Tools, not a full Xcode install.
#
# Output: build/VoiceDictation.app
#
# Usage:
#   Scripts/build-app.sh            # release build + bundle + ad-hoc sign
#   CONFIG=debug Scripts/build-app.sh
set -euo pipefail

CONFIG="${CONFIG:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="VoiceDictation"
BUILD_DIR="$ROOT/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"

echo "==> Building $APP_NAME ($CONFIG)"
swift build -c "$CONFIG" --product "$APP_NAME"

BIN_PATH="$(swift build -c "$CONFIG" --product "$APP_NAME" --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"

# Ad-hoc code signature. A stable (even if ad-hoc) signature gives the bundle a
# consistent identity so macOS TCC remembers granted Microphone / Accessibility
# permissions across rebuilds instead of re-prompting every launch.
echo "==> Ad-hoc code signing"
codesign --force --sign - --identifier "com.firstmate.VoiceDictation" \
    --timestamp=none "$APP_BUNDLE" >/dev/null 2>&1 || {
        echo "warning: codesign failed; the app will still run but TCC may re-prompt" >&2
    }

echo "==> Done: $APP_BUNDLE"
echo "    Run with: open \"$APP_BUNDLE\""
echo "    Or:       \"$MACOS_DIR/$APP_NAME\"   (foreground, for logs)"
