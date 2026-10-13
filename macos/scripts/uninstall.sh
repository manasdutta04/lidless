#!/bin/bash
# Removes Lidless: restores settings first, then removes the recovery agent,
# sudoers rule, CLI link and the app.
#   --purge   also delete ~/Library/Application Support/Lidless (state and logs)
set -euo pipefail

STATE="$HOME/Library/Application Support/Lidless"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

APP=""
for candidate in /Applications/Lidless.app "$HOME/Applications/Lidless.app"; do
  [ -d "$candidate" ] && APP="$candidate" && break
done

if pgrep -xq Lidless; then
  echo "Quitting the Lidless app (this ends its session and restores settings)…"
  osascript -e 'tell application id "io.github.manasdutta04.lidless" to quit' >/dev/null 2>&1 || true
  sleep 3
fi

if [ -n "$APP" ] && [ -x "$APP/Contents/Helpers/lidless" ]; then
  "$APP/Contents/Helpers/lidless" stop >/dev/null 2>&1 || true
  # Restores anything left, then removes agent, sudoers rule and CLI link.
  "$APP/Contents/Helpers/lidless" uninstall
  rm -rf "$APP"
  echo "✓ Removed $APP"
else
  echo "Lidless.app not found; nothing else to remove." >&2
fi

if [ "$PURGE" = 1 ]; then
  rm -rf "$STATE"
  echo "✓ Removed $STATE"
else
  echo "State and logs kept in $STATE (use --purge to remove)."
fi
