#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app='.build/Quota Bar.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun swiftc -O -parse-as-library -emit-executable macOS/QuotaBar.swift -o "$app/Contents/MacOS/QuotaBar" -framework AppKit -framework SwiftUI
cp pool.py quota.5m.py LICENSE "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>me.onmax.quota-bar</string>
<key>CFBundleName</key><string>Quota Bar</string>
<key>CFBundleExecutable</key><string>QuotaBar</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
echo "Built $app"
