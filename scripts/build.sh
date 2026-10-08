#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/听文.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/ListenText" "$APP_DIR/Contents/MacOS/ListenText"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/示例文本.txt "$APP_DIR/Contents/Resources/示例文本.txt"
if [ ! -f Resources/AppIcon.icns ]; then
    ICON_DIR="$PROJECT_DIR/.build/AppIcon.iconset"
    mkdir -p "$ICON_DIR"
    swift scripts/make-icon.swift "$PROJECT_DIR/.build/AppIcon.png"
    for SIZE in 16 32 128 256 512; do
        sips -z "$SIZE" "$SIZE" .build/AppIcon.png --out "$ICON_DIR/icon_${SIZE}x${SIZE}.png" >/dev/null
        DOUBLE_SIZE=$((SIZE * 2))
        sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" .build/AppIcon.png --out "$ICON_DIR/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICON_DIR" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$APP_DIR"
codesign --verify --strict "$APP_DIR"
printf '\n已生成：%s\n' "$APP_DIR"
