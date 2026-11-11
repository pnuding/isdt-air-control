#!/bin/bash
# Builds the release binary and wraps it into a standalone, double-clickable
# .app bundle. No Xcode project needed - built entirely via Swift Package
# Manager, then hand-wrapped (same approach as the sibling instrument apps).
#
# The .app wrapper isn't optional here: system notifications and the
# Bluetooth permission prompt only work for a real app bundle, not for a
# bare `swift run` binary.
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="ISDT Air Control.app"
APP="$DIR/$APP_NAME"
BIN_NAME="A8AirControl"

echo "Building release binary..."
(cd "$DIR" && swift build -c release)
# Resolved, not hardcoded: the build output lands in an architecture-specific
# directory (arm64-apple-macosx vs x86_64-apple-macosx).
BIN_PATH="$(cd "$DIR" && swift build -c release --show-bin-path)"

echo "Bundling $APP_NAME ..."
rm -rf "$APP"
# The app used to be called "A8 Air Control" (A8-only); drop that stale bundle.
rm -rf "$DIR/A8 Air Control.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"
if [ -f "$DIR/icon.icns" ]; then
    cp "$DIR/icon.icns" "$APP/Contents/Resources/icon.icns"
fi

# Localizable.strings live outside Sources/ (not an SPM target resource) so SPM never wraps
# them in its own nested Bundle.module resource bundle - they're copied straight into
# Contents/Resources/<locale>.lproj here, like a classic Xcode-built app, so plain
# Bundle.main-based lookups (SwiftUI Text, String(localized:)) find them with no bundle
# plumbing in the source. Same mechanism as the sibling instrument apps.
cp -R "$DIR/Localization/"*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$BIN_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.isdt.a8air.control</string>
    <key>CFBundleName</key>
    <string>ISDT Air Control</string>
    <key>CFBundleDisplayName</key>
    <string>ISDT Air Control</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>icon.icns</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>de</string>
        <string>es</string>
        <string>ca</string>
        <string>fr</string>
        <string>pt-PT</string>
        <string>nl</string>
        <string>it</string>
        <string>pl</string>
        <string>cs</string>
        <string>da</string>
        <string>sv</string>
        <string>nb</string>
        <string>fi</string>
        <string>zh-Hans</string>
        <string>ja</string>
        <string>pt-BR</string>
        <string>ko</string>
    </array>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>ISDT Air Control talks to your ISDT chargers (A8 Air, A4 Air, C4 Air) over Bluetooth to show their status and change their settings.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built: $APP"
du -sh "$APP"
