#!/bin/zsh
# Builds a universal CacheMenuBar.app and a zip that can be shared with another Mac.
set -e
cd "$(dirname "$0")"

APP=CacheMenuBar.app
BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -target arm64-apple-macosx13.0 main.swift -o "$BUILD_DIR/CacheMenuBar-arm64"
swiftc -O -target x86_64-apple-macosx13.0 main.swift -o "$BUILD_DIR/CacheMenuBar-x86_64"
lipo -create "$BUILD_DIR/CacheMenuBar-arm64" "$BUILD_DIR/CacheMenuBar-x86_64" -output "$APP/Contents/MacOS/CacheMenuBar"

ICONSET="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Assets/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Assets/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>CacheMenuBar</string>
    <key>CFBundleIdentifier</key><string>dev.local.cachemenubar</string>
    <key>CFBundleName</key><string>CacheMenuBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP"
rm -f CacheMenuBar.zip
ditto -c -k --sequesterRsrc --keepParent "$APP" CacheMenuBar.zip

echo "Built $APP"
echo "Share:  CacheMenuBar.zip"
echo "Run:    open $APP"
