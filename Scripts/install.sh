#!/usr/bin/env bash
# Build Voice Dictation, install it to /Applications and start it.
# Safe to run again after a `git pull` - it replaces the installed app.
#
#   Scripts/install.sh

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="VoiceDictation"
INSTALLED="/Applications/$APP_NAME.app"
SERVER="http://127.0.0.1:9876"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Voice Dictation is a macOS app." >&2
  exit 1
fi
if ! xcode-select -p >/dev/null 2>&1; then
  echo "The Xcode Command Line Tools are missing. Install them, then run this script again:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

Scripts/build-app.sh

echo "==> installing to $INSTALLED"
# Quit a running copy first, so the new build is the one that starts.
osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
for _ in $(seq 1 25); do
  pgrep -f "$INSTALLED/Contents/MacOS/$APP_NAME" >/dev/null || break
  sleep 0.2
done
rm -rf "$INSTALLED"
ditto "build/$APP_NAME.app" "$INSTALLED"
codesign --verify --deep --strict "$INSTALLED"
open "$INSTALLED"
echo "==> started (look for the microphone icon in the menu bar)"

echo
if curl -fsS -m 3 "$SERVER/health" >/dev/null 2>&1; then
  echo "Server: whisper-service is running on $SERVER."
else
  echo "Server: whisper-service is NOT running on $SERVER yet. Install it:"
  echo "  git clone https://github.com/gapsong/whisper-service.git"
  echo "  whisper-service/scripts/install.sh"
fi

cat <<'EOF'

Last steps (one time only):
  1. Allow the microphone when macOS asks.
  2. System Settings > Privacy & Security > Accessibility: turn on VoiceDictation.
     (Needed for the hotkey and to paste the text.)
  3. System Settings > Keyboard > "Press Globe key to": Do Nothing.

Then hold fn/Globe (or F13 on an external keyboard), speak, and release.
EOF
