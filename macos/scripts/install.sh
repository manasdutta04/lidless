#!/bin/bash
# Installs Lidless for the current user:
#   1. builds dist/Lidless.app and copies it to ~/Applications
#   2. links the CLI to ~/.local/bin/lidless
#   3. installs /etc/sudoers.d/lidless (asks for your password once), allowing
#      exactly four pmset commands without a password, nothing else
#   4. installs and loads the recovery LaunchAgent (runs `lidless recover`
#      every 60 s and at login)
#   5. runs `lidless doctor`
#
# Safe to run again to upgrade. Refuses to run while a session is active.
set -euo pipefail
cd "$(dirname "$0")/.."

LABEL="io.github.manasdutta04.lidless.recovery"
APP_DEST="$HOME/Applications/Lidless.app"
CLI="$APP_DEST/Contents/Helpers/lidless"
BIN_DIR="$HOME/.local/bin"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SUDOERS="/etc/sudoers.d/lidless"
STATE="$HOME/Library/Application Support/Lidless"
USER_NAME="$(id -un)"
UID_NUM="$(id -u)"

if [[ ! "$USER_NAME" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]]; then
  echo "Unsupported user name for a sudoers rule: $USER_NAME" >&2
  exit 1
fi

if [ -f "$STATE/session.json" ]; then
  echo "A Lidless session is active. Stop it first (lidless stop), then re-run." >&2
  exit 1
fi

# 1. Build and copy the app.
./scripts/build-app.sh
if pgrep -xq Lidless; then
  echo "Quitting the running Lidless app…"
  osascript -e 'tell application id "io.github.manasdutta04.lidless" to quit' >/dev/null 2>&1 || true
  sleep 2
fi
mkdir -p "$HOME/Applications"
rm -rf "$APP_DEST"
cp -R dist/Lidless.app "$APP_DEST"
echo "✓ Installed $APP_DEST"

# 2. CLI link.
mkdir -p "$BIN_DIR"
ln -sf "$CLI" "$BIN_DIR/lidless"
echo "✓ Linked $BIN_DIR/lidless"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "  Note: $BIN_DIR is not on your PATH. Add this to your shell profile:"
     echo "    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# 3. sudoers rule: exactly these four commands, for this user only.
TMP_SUDOERS="$(mktemp)"
trap 'rm -f "$TMP_SUDOERS"' EXIT
cat > "$TMP_SUDOERS" <<EOF
# Installed by Lidless. Lets $USER_NAME toggle closed-lid sleep and battery
# Low Power Mode without a password. Nothing else. Remove with uninstall.sh.
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -b lowpowermode 1, /usr/bin/pmset -b lowpowermode 0
EOF
echo "Installing $SUDOERS (sudo will ask for your password)…"
if ! sudo /usr/sbin/visudo -cf "$TMP_SUDOERS" >/dev/null; then
  echo "The sudoers rule failed validation; nothing was installed." >&2
  exit 1
fi
sudo /usr/bin/install -m 0440 -o root -g wheel "$TMP_SUDOERS" "$SUDOERS"
if sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1; then
  echo "✓ sudoers rule installed and verified"
else
  echo "The sudoers rule was installed but sudo still asks for a password." >&2
  echo "Check that /etc/sudoers includes /etc/sudoers.d (#includedir /private/etc/sudoers.d)." >&2
  exit 1
fi

# 4. Recovery LaunchAgent.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$CLI</string>
        <string>recover</string>
    </array>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
EOF
chmod 644 "$PLIST"
launchctl bootout "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
  echo "✓ Recovery agent loaded ($LABEL)"
else
  echo "The recovery agent did not load. Check: launchctl print gui/$UID_NUM/$LABEL" >&2
  exit 1
fi

# 5. Check.
echo
"$CLI" doctor || true
echo
echo "Done. Open Lidless from ~/Applications (it lives in the menu bar), or run: lidless start 2h"
echo "Keep the Mac on a ventilated surface while the lid is closed. Never in a bag."
