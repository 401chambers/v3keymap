#!/usr/bin/env bash
# Builds Keymap.app (release) from the Swift package. Needs only the Command Line Tools.
# usage: scripts/make-app.sh [--dmg] [output-dir]   (default: ./dist; --dmg also makes Keymap.dmg)
set -euo pipefail
cd "$(dirname "$0")/.."
dmg=0
if [ "${1:-}" = "--dmg" ]; then dmg=1; shift; fi
out="${1:-dist}"
app="$out/Keymap.app"

swift build -c release --product KeymapApp
bin="$(swift build -c release --show-bin-path)"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/KeymapApp" "$app/Contents/MacOS/Keymap"
# SwiftPM resource bundles (the bundled V3 layout) sit next to the app's resources.
for b in "$bin"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$app/Contents/Resources/"; done
# Help documents (the PDFs in ./Help, if present).
[ -d Help ] && cp -R Help "$app/Contents/Resources/Help"
# App icon (regenerate with: swiftc scripts/make-icon.swift -o make-icon && ./make-icon Resources/AppIcon.icns)
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>local.keymap</string>
  <key>CFBundleName</key><string>Keymap</string>
  <key>CFBundleDisplayName</key><string>Keymap</string>
  <key>CFBundleExecutable</key><string>Keymap</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 401chambers. Released under the MIT licence. Not affiliated with Keychron.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSInputMonitoringUsageDescription</key>
  <string>Keymap talks to your keyboard over its configuration channel to read and change its keymap, knob, macros and lighting.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$app" >/dev/null 2>&1 || echo "warning: ad-hoc signing failed; the app may need to be opened via right-click > Open"
echo "$PWD/$app"

if [ "$dmg" = 1 ]; then
  stage="$(mktemp -d)"
  cp -R "$app" "$stage/"
  ln -s /Applications "$stage/Applications"
  rm -f "$out/Keymap.dmg"
  hdiutil create -quiet -volname "Keymap" -srcfolder "$stage" -ov -format UDZO "$out/Keymap.dmg"
  rm -rf "$stage"
  echo "$PWD/$out/Keymap.dmg"
fi
