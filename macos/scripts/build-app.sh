#!/bin/bash
# Builds dist/Lidless.app: the menu bar app plus the `lidless` CLI inside
# Contents/Helpers. Ad-hoc signed. Does not install anything.
#
#   CONFIG=debug|release   (default release)
#   UNIVERSAL=1            build for Apple silicon and Intel
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
ARCH_FLAGS=()
if [ "${UNIVERSAL:-0}" = 1 ]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product lidless
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product LidlessApp
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

VERSION="$(sed -n 's/.*string = "\(.*\)".*/\1/p' Sources/LidlessCore/Version.swift)"
APP="dist/Lidless.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/LidlessMark.png "$APP/Contents/Resources/"
cp "$BIN/LidlessApp" "$APP/Contents/MacOS/Lidless"
cp "$BIN/lidless" "$APP/Contents/Helpers/lidless"
chmod 755 "$APP/Contents/MacOS/Lidless" "$APP/Contents/Helpers/lidless"

codesign --force --sign - --identifier io.github.manasdutta04.lidless.cli "$APP/Contents/Helpers/lidless"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "Built $(pwd)/$APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/Lidless"))"
