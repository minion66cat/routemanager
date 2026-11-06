#!/bin/bash
# Build RouteManager.app without an Xcode project.
#   ./build.sh           — build for this Mac's architecture → build/RouteManager.app
#   ./build.sh install   — build and copy to /Applications
#   ./build.sh release   — universal build (Apple Silicon + Intel) → build/RouteManager-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0.0"
BUILD_NUMBER="1"
MIN_MACOS="14.0"
MODE="${1:-}"

APP="build/RouteManager.app"
BIN="$APP/Contents/MacOS/RouteManager"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() { # $1 = arch, $2 = output
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$1-apple-macos$MIN_MACOS" \
    Sources/*.swift -o "$2"
}

if [ "$MODE" = "release" ]; then
  echo "→ compiling arm64…"
  compile arm64 build/RouteManager-arm64
  echo "→ compiling x86_64…"
  compile x86_64 build/RouteManager-x86_64
  lipo -create build/RouteManager-arm64 build/RouteManager-x86_64 -output "$BIN"
  rm -f build/RouteManager-arm64 build/RouteManager-x86_64
else
  echo "→ compiling $(uname -m)…"
  compile "$(uname -m)" "$BIN"
fi

echo "→ icon…"
if [ ! -f build/AppIcon.icns ]; then
  swiftc -O tools/make_icon.swift -o build/make_icon
  build/make_icon build/icon_1024.png
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>RouteManager</string>
  <key>CFBundleDisplayName</key><string>RouteManager</string>
  <key>CFBundleIdentifier</key><string>local.routemanager</string>
  <key>CFBundleExecutable</key><string>RouteManager</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "✓ built: $(pwd)/$APP ($(lipo -archs "$BIN"))"

if [ "$MODE" = "install" ]; then
  rm -rf /Applications/RouteManager.app
  cp -R "$APP" /Applications/
  echo "✓ installed: /Applications/RouteManager.app"
fi

if [ "$MODE" = "release" ]; then
  DMG="build/RouteManager-$VERSION.dmg"
  STAGE="build/dmg"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "RouteManager $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "✓ dmg: $(pwd)/$DMG"
  shasum -a 256 "$DMG"
fi
