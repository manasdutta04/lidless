#!/bin/bash
# Builds dist/Lidless.app: the menu bar app plus the `lidless` CLI inside
# Contents/Helpers. Ad-hoc signed. Does not install anything.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product lidless
swift build -c "$CONFIG" --product LidlessApp
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="dist/Lidless.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$BIN/LidlessApp" "$APP/Contents/MacOS/Lidless"
cp "$BIN/lidless" "$APP/Contents/Helpers/lidless"
chmod 755 "$APP/Contents/MacOS/Lidless" "$APP/Contents/Helpers/lidless"

codesign --force --sign - --identifier io.github.manasdutta04.lidless.cli "$APP/Contents/Helpers/lidless"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "Built $(pwd)/$APP"
