#!/bin/bash
# Builds a release Perch.app via build.sh and packages it as dist/Perch-<version>.dmg (+ .sha256).
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh   # already builds with `swift build -c release`; does not install or launch

APP=build/Perch.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
[ -n "$VERSION" ] || { echo "CFBundleShortVersionString missing in $APP" >&2; exit 1; }

codesign --verify --deep --strict "$APP"
codesign -dvv "$APP" 2>&1 | grep -E '^(Identifier|Authority|Signature|TeamIdentifier)=' || true

mkdir -p dist
DMG="dist/Perch-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname Perch -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
(cd dist && shasum -a 256 "Perch-$VERSION.dmg" > "Perch-$VERSION.dmg.sha256")
# Stable name so the site can link releases/latest/download/Perch.dmg
cp "$DMG" dist/Perch.dmg

echo "Built $DMG ($(du -h "$DMG" | cut -f1)), version $VERSION"
cat "$DMG.sha256"
