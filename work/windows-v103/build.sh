#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
OUTPUT_DIR="${1:-$ROOT_DIR/dist}"
BUILD_DIR="$ROOT_DIR/build"
PACKAGE_DIR="$BUILD_DIR/柯基小小-Windows"
ARCHIVE_PATH="$OUTPUT_DIR/Corgi-Xiaoxiao-Windows.zip"

rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR/assets" "$OUTPUT_DIR"
cp "$ROOT_DIR/CorgiPet.ps1" "$PACKAGE_DIR/CorgiPet.ps1"
cp "$ROOT_DIR/README.txt" "$PACKAGE_DIR/README.txt"
cp "$ROOT_DIR/启动柯基小小.vbs" "$PACKAGE_DIR/启动柯基小小.vbs"
cp "$ROOT_DIR/调试启动.bat" "$PACKAGE_DIR/调试启动.bat"
cp "$ROOT_DIR/assets/spritesheet.png" "$PACKAGE_DIR/assets/spritesheet.png"

rm -f "$ARCHIVE_PATH"
/usr/bin/ditto -c -k --norsrc --keepParent "$PACKAGE_DIR" "$ARCHIVE_PATH"
/usr/bin/shasum -a 256 "$ARCHIVE_PATH"
