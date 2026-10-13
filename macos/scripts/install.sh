#!/bin/bash
# Builds Lidless from source and installs it for the current user:
#   1. builds Lidless.app and copies it to /Applications (or ~/Applications)
#   2. runs `lidless setup`: recovery agent, CLI link at ~/.local/bin/lidless,
#      and the sudoers rule for exactly four pmset commands (asks for your
#      password once)
#
# Safe to run again to upgrade. Refuses to run while a session is active.
set -euo pipefail
cd "$(dirname "$0")/.."

STATE="$HOME/Library/Application Support/Lidless"
if [ -f "$STATE/session.json" ]; then
  echo "A Lidless session is active. Stop it first (lidless stop), then re-run." >&2
  exit 1
fi

./scripts/build-app.sh

if pgrep -xq Lidless; then
  echo "Quitting the running Lidless app…"
  osascript -e 'tell application id "io.github.manasdutta04.lidless" to quit' >/dev/null 2>&1 || true
  sleep 2
fi

if [ -w /Applications ]; then DEST_DIR=/Applications; else DEST_DIR="$HOME/Applications"; fi
mkdir -p "$DEST_DIR"
APP_DEST="$DEST_DIR/Lidless.app"
rm -rf "$APP_DEST"
cp -R dist/Lidless.app "$APP_DEST"
# An older install in the other location would confuse launchd and Spotlight.
for other in /Applications/Lidless.app "$HOME/Applications/Lidless.app"; do
  [ "$other" != "$APP_DEST" ] && [ -d "$other" ] && rm -rf "$other" && echo "Removed older copy at $other"
done
echo "✓ Installed $APP_DEST"

"$APP_DEST/Contents/Helpers/lidless" setup
echo
"$APP_DEST/Contents/Helpers/lidless" doctor || true
open "$APP_DEST"
echo
echo "Lidless is in your menu bar. Keep the Mac on a ventilated surface while the lid is closed."
