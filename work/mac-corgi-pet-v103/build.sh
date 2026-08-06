#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
OUTPUT_DIR="${1:-$ROOT_DIR/dist}"
APP_NAME="柯基小小.app"
ARCHIVE_NAME="柯基小小-macOS.zip"
APP_DIR="$OUTPUT_DIR/$APP_NAME"
BUILD_DIR="$ROOT_DIR/build"
MODULE_CACHE_DIR="$BUILD_DIR/ModuleCache"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$BUILD_DIR" "$MODULE_CACHE_DIR"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/spritesheet.png" "$APP_DIR/Contents/Resources/spritesheet.png"
cp "$ROOT_DIR/Resources/CorgiPet.icns" "$APP_DIR/Contents/Resources/CorgiPet.icns"
cp "$ROOT_DIR/Resources/install-update.sh" "$APP_DIR/Contents/Resources/install-update.sh"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" xcrun swiftc -O -target arm64-apple-macos13.0 \
  -module-cache-path "$MODULE_CACHE_DIR" -framework AppKit \
  "$ROOT_DIR/Sources/main.swift" -o "$BUILD_DIR/CorgiPet-arm64"
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" xcrun swiftc -O -target x86_64-apple-macos13.0 \
  -module-cache-path "$MODULE_CACHE_DIR" -framework AppKit \
  "$ROOT_DIR/Sources/main.swift" -o "$BUILD_DIR/CorgiPet-x86_64"
lipo -create "$BUILD_DIR/CorgiPet-arm64" "$BUILD_DIR/CorgiPet-x86_64" \
  -output "$APP_DIR/Contents/MacOS/CorgiPet"

chmod +x "$APP_DIR/Contents/MacOS/CorgiPet"
xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"
plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --verify --deep --strict "$APP_DIR"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist")
rm -f "$OUTPUT_DIR/$ARCHIVE_NAME"
ditto -c -k --norsrc --keepParent "$APP_DIR" "$OUTPUT_DIR/$ARCHIVE_NAME"
ARCHIVE_SHA256=$(/usr/bin/shasum -a 256 "$OUTPUT_DIR/$ARCHIVE_NAME" | /usr/bin/awk '{print $1}')
/usr/bin/printf '{\n  "schemaVersion": 1,\n  "version": "%s",\n  "build": %s,\n  "releaseNotes": "将右键菜单中的‘检查本地更新…’简化为‘更新’。",\n  "platforms": {\n    "macos": {\n      "archive": "%s",\n      "sha256": "%s",\n      "url": null\n    }\n  }\n}\n' \
  "$VERSION" "$BUILD" "$ARCHIVE_NAME" "$ARCHIVE_SHA256" > "$OUTPUT_DIR/update.json"
echo "$APP_DIR"
