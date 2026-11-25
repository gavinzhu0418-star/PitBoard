#!/bin/bash
# Build PitBoard.app (needs the Xcode Command Line Tools: xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

APP="PitBoard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library PitBoard.swift -o "$APP/Contents/MacOS/PitBoard"
# Menu bar icon: copy MenuIcon.png / MenuIcon@2x.png if present; without them the menu bar shows 🏁
for f in MenuIcon.png MenuIcon@2x.png; do
    if [ -f "$f" ]; then cp -X "$f" "$APP/Contents/Resources/"; fi
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>PitBoard</string>
    <key>CFBundleIdentifier</key>
    <string>local.pitboard</string>
    <key>CFBundleExecutable</key>
    <string>PitBoard</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
