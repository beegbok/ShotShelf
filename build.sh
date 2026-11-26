#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
SDK="$(xcrun --show-sdk-path)"
TARGET="arm64-apple-macos14.0"

echo "Testing…"
swiftc -parse-as-library -sdk "$SDK" -target "$TARGET" \
  Sources/ScreenshotFilter.swift Sources/PanelGeometry.swift Tests/ScreenshotFilterTests.swift \
  -o /tmp/shotshelf-filter-test
/tmp/shotshelf-filter-test

echo "Building…"
APP="$ROOT/build/ShotShelf.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# AppKit callbacks are main-thread by contract; Swift 5 mode avoids isolation noise.
swiftc -parse-as-library -O -swift-version 5 -sdk "$SDK" -target "$TARGET" \
  -framework AppKit \
  -framework SwiftUI \
  -framework ImageIO \
  -framework UniformTypeIdentifiers \
  -framework CoreServices \
  -framework ServiceManagement \
  Sources/ScreenshotFilter.swift \
  Sources/PanelGeometry.swift \
  Sources/ImageFileWriter.swift \
  Sources/ScreenshotStore.swift \
  Sources/ShelfView.swift \
  Sources/ShotShelfApp.swift \
  -o "$APP/Contents/MacOS/ShotShelf"

cp Info.plist "$APP/Contents/Info.plist"

ICON_PNG="$ROOT/build/icon-1024.png"
ICONSET="$ROOT/build/AppIcon.iconset"
if swift scripts/make-icon.swift "$ICON_PNG"; then
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  sips -z 16 16 "$ICON_PNG" --out "$ICONSET/icon_16x16.png" >/dev/null
  sips -z 32 32 "$ICON_PNG" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$ICON_PNG" --out "$ICONSET/icon_32x32.png" >/dev/null
  sips -z 64 64 "$ICON_PNG" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$ICON_PNG" --out "$ICONSET/icon_128x128.png" >/dev/null
  sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_256x256.png" >/dev/null
  sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

SIGN_ID="Developer ID Application: Dage Electronics Pty Ltd (3UU8PXWLK5)"
if security find-identity -v -p codesigning | grep -Fq "$SIGN_ID"; then
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
else
  echo "Developer ID certificate not in the keychain; this copy will only run on this Mac."
  codesign --force --sign - --identifier app.shotshelf.mac "$APP"
fi

ZIP="$ROOT/build/ShotShelf.zip"
rm -f "$ZIP"
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
echo "Packaged $ZIP"

DEST="$HOME/Applications/ShotShelf.app"
killall ShotShelf 2>/dev/null || true
rm -rf "$DEST"
ditto "$APP" "$DEST"
echo "Installed $DEST"
