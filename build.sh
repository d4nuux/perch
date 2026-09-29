#!/bin/bash
# Builds NotchApp.app in ./build and launches it.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/NotchApp.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotchApp "$APP/Contents/MacOS/"
# Now Playing helper: a dylib hosted by /usr/bin/perl (see Helper/MediaRemoteHelper.m).
clang -dynamiclib -fobjc-arc -O2 -framework Foundation Helper/MediaRemoteHelper.m \
  -o "$APP/Contents/Resources/MediaRemoteHelper.dylib"
cp Helper/media-remote.pl "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NotchApp</string>
  <key>CFBundleIdentifier</key><string>local.notchapp</string>
  <key>CFBundleExecutable</key><string>NotchApp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Shows your upcoming events in the notch.</string>
  <key>NSCalendarsUsageDescription</key><string>Shows your upcoming events in the notch.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>Shows when your headphones and other devices connect.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Shows local weather and travel time to your next event.</string>
  <key>NSLocationUsageDescription</key><string>Shows local weather and travel time to your next event.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Draws a live waveform of the audio that's playing.</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>local.notchapp</string>
    <key>CFBundleURLSchemes</key><array><string>notchapp</string></array>
  </dict></array>
  <key>NSAppleEventsUsageDescription</key><string>Shows and controls what's playing in Spotify and Music.</string>
</dict></plist>
PLIST
# A stable identity keeps macOS permissions (Accessibility etc.) across rebuilds; ad-hoc if missing.
if security find-certificate -c "NotchApp Local Signing" >/dev/null 2>&1; then
  codesign --force --sign "NotchApp Local Signing" --identifier local.notchapp "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
[[ "${1:-}" == "--run" ]] && { pkill -x NotchApp || true; for _ in {1..50}; do pgrep -x NotchApp >/dev/null || break; sleep 0.1; done; sleep 0.5; open "$APP" || { sleep 1; open "$APP"; }; }
