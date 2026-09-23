#!/bin/bash
# Build TabletPenMac and wrap the executable in a minimal .app bundle.
# A stable bundle identifier + ad-hoc code signature lets macOS persist the
# Screen Recording (and Accessibility) permission grant across launches.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/TabletPenMac"
APP="TabletPenMac.app"
MACOS="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS"
cp "$BIN" "$MACOS/TabletPenMac"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>            <string>TabletPenMac</string>
	<key>CFBundleDisplayName</key>     <string>TabletPenMac</string>
	<key>CFBundleIdentifier</key>      <string>com.example.tabletpenmac</string>
	<key>CFBundleExecutable</key>      <string>TabletPenMac</string>
	<key>CFBundlePackageType</key>     <string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key>         <string>1</string>
	<key>LSMinimumSystemVersion</key>  <string>12.0</string>
	<key>LSUIElement</key>             <true/>
	<key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so the bundle identity is stable for TCC.
codesign --force --sign - --identifier com.example.tabletpenmac "$APP"

echo "Built $APP"
