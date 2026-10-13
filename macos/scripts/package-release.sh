#!/bin/bash
# Builds a universal Lidless.app and packages it for a GitHub release:
#   dist/Lidless-<version>.dmg   drag-to-Applications disk image
#   dist/Lidless-<version>.zip   the same app, zipped
#   dist/SHA256SUMS.txt
# The app is ad-hoc signed, not notarized: users clear the quarantine flag
# once (see README).
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=1 ./scripts/build-app.sh
VERSION="$(sed -n 's/.*string = "\(.*\)".*/\1/p' Sources/LidlessCore/Version.swift)"
NAME="Lidless-$VERSION"

cd dist
rm -f "$NAME.dmg" "$NAME.zip" SHA256SUMS.txt
rm -rf dmg-root
mkdir dmg-root
cp -R Lidless.app dmg-root/
ln -s /Applications dmg-root/Applications
hdiutil create -quiet -volname "Lidless $VERSION" -srcfolder dmg-root -fs HFS+ -format UDZO -ov "$NAME.dmg"
rm -rf dmg-root

ditto -c -k --sequesterRsrc --keepParent Lidless.app "$NAME.zip"
shasum -a 256 "$NAME.dmg" "$NAME.zip" > SHA256SUMS.txt

echo
cat SHA256SUMS.txt
echo "Packaged dist/$NAME.dmg and dist/$NAME.zip"
