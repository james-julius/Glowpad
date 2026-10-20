#!/bin/sh
# Builds Glowpad.app and installs it to /Applications.
set -e
cd "$(dirname "$0")"
APP=build/Glowpad.app
mkdir -p "$APP/Contents/MacOS"
for ARCH in arm64 x86_64; do
  swiftc -O -target $ARCH-apple-macos13.0 main.swift -o "build/Glowpad-$ARCH"
done
lipo -create build/Glowpad-arm64 build/Glowpad-x86_64 -output "$APP/Contents/MacOS/Glowpad"
if [ ! -f AppIcon.icns ]; then
  ICONSET="build/AppIcon-$(date +%s).iconset"
  swiftc -O make_icon.swift -o build/make_icon
  build/make_icon "$ICONSET"
  iconutil -c icns "$ICONSET" -o AppIcon.icns
fi
mkdir -p "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Glowpad</string>
  <key>CFBundleIdentifier</key><string>io.github.james-julius.glowpad</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Glowpad</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
ditto "$APP" /Applications/Glowpad.app
echo "Installed /Applications/Glowpad.app"
