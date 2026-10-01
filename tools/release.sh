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
rm -f "$DMG"

# Installer window: designed background, fixed layout, volume icon (dmgbuild writes the .DS_Store, no Finder scripting)
VENV=.build/dmgvenv
[ -x "$VENV/bin/dmgbuild" ] || { python3 -m venv "$VENV" && "$VENV/bin/pip" install -q dmgbuild; }
mkdir -p tools/dmg/build
swift tools/dmg/background.swift tools/dmg/build >/dev/null
"$VENV/bin/dmgbuild" -s tools/dmg/settings.py -D app="$APP" -D background=tools/dmg/build/background.png Perch "$DMG" >/dev/null
(cd dist && shasum -a 256 "Perch-$VERSION.dmg" > "Perch-$VERSION.dmg.sha256")
# Stable name so the site can link releases/latest/download/Perch.dmg
cp "$DMG" dist/Perch.dmg

echo "Built $DMG ($(du -h "$DMG" | cut -f1)), version $VERSION"
cat "$DMG.sha256"
