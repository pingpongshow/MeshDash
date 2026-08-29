#!/bin/bash
# Builds MeshDash.app. macOS only grants Bluetooth and notification access to a
# real bundle with an Info.plist and a code signature, so a bare SwiftPM binary
# is not enough.
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/MeshDash.app"
CONTENTS="$APP/Contents"

echo "Building ($CONFIGURATION)…"
swift build -c "$CONFIGURATION" --product MeshDash
BINARY="$(swift build -c "$CONFIGURATION" --product MeshDash --show-bin-path)/MeshDash"

echo "Assembling $APP…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/MeshDash"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MeshDash</string>
    <key>CFBundleDisplayName</key><string>MeshDash</string>
    <key>CFBundleIdentifier</key><string>org.meshdash.MeshDash</string>
    <key>CFBundleExecutable</key><string>MeshDash</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MeshDash — a desktop client for Meshtastic.</string>

    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>MeshDash connects to your Meshtastic radio over Bluetooth to send and receive messages and read its configuration.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>MeshDash finds Meshtastic radios on your WiFi network and connects to their network API.</string>
    <key>NSLocationWhenInUseUsageDescription</key>
    <string>MeshDash can share this Mac's location with your mesh and centre the map on you.</string>

    <key>NSBonjourServices</key>
    <array>
        <string>_meshtastic._tcp</string>
    </array>

    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>Meshtastic Channel Link</string>
            <key>CFBundleURLSchemes</key>
            <array><string>meshtastic</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

cat > "$ROOT/build/MeshDash.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key><false/>
    <key>com.apple.security.device.bluetooth</key><true/>
    <key>com.apple.security.device.usb</key><true/>
    <key>com.apple.security.device.serial</key><true/>
    <key>com.apple.security.network.client</key><true/>
    <key>com.apple.security.network.server</key><true/>
    <key>com.apple.security.files.user-selected.read-write</key><true/>
</dict>
</plist>
ENT

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

# An ad-hoc signature is enough for macOS to grant a stable identity for the
# Bluetooth and notification permission prompts on this machine.
SIGN_IDENTITY="${MESHDASH_SIGN_IDENTITY:--}"
echo "Signing with identity: $SIGN_IDENTITY"
codesign --force --deep --options runtime \
    --entitlements "$ROOT/build/MeshDash.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP"

codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/  /'
echo
echo "Built $APP"
echo "Run it with:  open '$APP'"
