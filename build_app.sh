#!/bin/bash
# Builds "NxNative Builder.app" (universal: Apple silicon and Intel) next to this script. Needs Xcode's swiftc. The app is native SwiftUI; it contains the three patches,
# and downloads everything else it needs on first run after asking. Signed ad-hoc: on another Mac, right-click the app and choose Open the first time (it is not notarized).
set -euo pipefail
cd "$(dirname "$0")"
APP="NxNative Builder.app"
rm -rf "$APP" .build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/patches" .build
for a in arm64 x86_64; do swiftc -O -swift-version 5 -parse-as-library -target $a-apple-macos13.0 Sources/*.swift -o .build/app-$a; done
lipo -create .build/app-arm64 .build/app-x86_64 -output "$APP/Contents/MacOS/NxNativeBuilder"
cp patches/*.patch "$APP/Contents/Resources/patches/"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # made by make_icon.swift from icon-source.png
cat > "$APP/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>NxNative Builder</string>
<key>CFBundleDisplayName</key><string>NxNative Builder</string>
<key>CFBundleIdentifier</key><string>local.nxnative.builder</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleExecutable</key><string>NxNativeBuilder</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>15</string><key>CFBundleShortVersionString</key><string>2.6.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
P
codesign --force --deep --sign - "$APP"
rm -rf .build
echo "Built $(pwd)/$APP"
