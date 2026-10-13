#!/bin/bash
# Removes Lidless: ends any session and restores settings first, then removes
# the recovery agent, sudoers rule, app and CLI link.
#   --purge   also delete ~/Library/Application Support/Lidless (state and logs)
set -euo pipefail

LABEL="io.github.manasdutta04.lidless.recovery"
APP_DEST="$HOME/Applications/Lidless.app"
CLI="$APP_DEST/Contents/Helpers/lidless"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SUDOERS="/etc/sudoers.d/lidless"
STATE="$HOME/Library/Application Support/Lidless"
UID_NUM="$(id -u)"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

if pgrep -xq Lidless; then
  echo "Quitting the Lidless app (this ends its session and restores settings)…"
  osascript -e 'tell application id "io.github.manasdutta04.lidless" to quit' >/dev/null 2>&1 || true
  sleep 3
fi

# Restore before removing the machinery that restores (needs the sudoers rule).
if [ -x "$CLI" ]; then
  "$CLI" stop >/dev/null 2>&1 || true
  "$CLI" recover || true
  if [ -f "$STATE/session.json" ] || { [ -f "$STATE/journal.json" ] && grep -q '"sleepDisabled"\|"lowPowerMode"' "$STATE/journal.json"; }; then
    echo "Lidless still has settings to restore (see: $CLI status). Not uninstalling." >&2
    echo "Fix the reported problem and run this again." >&2
    exit 1
  fi
fi

launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
rm -f "$PLIST"
echo "✓ Removed recovery agent"

if [ -f "$SUDOERS" ]; then
  echo "Removing $SUDOERS (sudo may ask for your password)…"
  sudo rm -f "$SUDOERS"
  echo "✓ Removed sudoers rule"
fi

if [ -L "$HOME/.local/bin/lidless" ]; then
  rm -f "$HOME/.local/bin/lidless"
  echo "✓ Removed CLI link"
fi
rm -rf "$APP_DEST"
echo "✓ Removed $APP_DEST"

if [ "$PURGE" = 1 ]; then
  rm -rf "$STATE"
  echo "✓ Removed $STATE"
else
  echo "State and logs kept in $STATE (use --purge to remove)."
fi
