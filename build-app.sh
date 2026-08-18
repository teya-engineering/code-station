#!/bin/bash
# Build a double-clickable app bundle from the SwiftPM executable.
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="Teya Code Station"
BUNDLE_ID="com.teya.code-station"

# The organisation settings folded into the bundle. Override this path to select another
# file; a build with no file is left unconfigured.
SITE_DEFAULTS="${SITE_DEFAULTS:-site-defaults.json}"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/MenuBarApp"

APP="build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MenuBarApp"

# SwiftPM keeps target resources in their own bundle next to the binary; Bundle.module
# finds it again once it sits in the app's Resources folder.
cp -R "$(dirname "$BIN")/MenuBarApp_MenuBarApp.bundle" "$APP/Contents/Resources/"

# A bundle carrying settings is an app that is already set up for whoever it is handed
# to. The app looks for one fixed name, so whichever file was chosen arrives under it.
if [ -f "$SITE_DEFAULTS" ]; then
    cp "$SITE_DEFAULTS" \
        "$APP/Contents/Resources/MenuBarApp_MenuBarApp.bundle/site-defaults.json"
fi

# Regenerate the icon if it is missing, so a fresh clone still gets a Dock icon.
[ -f Resources/AppIcon.icns ] || swift make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>MenuBarApp</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Open a selected Code Station session on a phone connected to the same Wi-Fi.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
echo "Built $APP"
