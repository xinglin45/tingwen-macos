#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
bash scripts/build.sh

APP_DIR="$PROJECT_DIR/dist/听文.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")
MIN_SYSTEM=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_DIR/Contents/Info.plist")
ARCHS=$(lipo -archs "$APP_DIR/Contents/MacOS/ListenText")
case "$ARCHS" in
    arm64) ARCH_LABEL="arm64"; CPU_DESCRIPTION="Apple Silicon（M 系列芯片）" ;;
    x86_64) ARCH_LABEL="x86_64"; CPU_DESCRIPTION="Intel" ;;
    *arm64*x86_64*|*x86_64*arm64*) ARCH_LABEL="universal"; CPU_DESCRIPTION="Apple Silicon 和 Intel" ;;
    *) printf '无法识别应用架构：%s\n' "$ARCHS" >&2; exit 1 ;;
esac

IMAGE_NAME="Tingwen-v${VERSION}-macOS-${ARCH_LABEL}.dmg"
WORK_DIR=$(mktemp -d "$PROJECT_DIR/.build/dmg.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
STAGING_DIR="$WORK_DIR/contents"
mkdir -p "$STAGING_DIR"
ditto "$APP_DIR" "$STAGING_DIR/听文.app"
ln -s /Applications "$STAGING_DIR/Applications"
cat > "$STAGING_DIR/安装说明.txt" <<EOF
听文 v${VERSION}

系统要求：macOS ${MIN_SYSTEM} 或更新版本；${CPU_DESCRIPTION} Mac。

安装方法
1. 将「听文.app」拖到「Applications」入口（应用程序文件夹）。
2. 在应用程序文件夹打开「听文」。
3. 安装完成后推出此磁盘镜像。

默认播放 / 暂停快捷键：Control + Option + Space。
声音使用本机已安装的 macOS 系统声音。

此版本使用本地 ad-hoc 签名，未使用 Apple Developer ID 签名或 Apple 公证。
从互联网下载后，macOS 可能阻止首次打开。请先确认下载来源可信，
再按照 macOS「系统设置 → 隐私与安全性」中显示的提示操作。

项目主页：https://github.com/xinglin45/tingwen-macos
EOF

codesign --verify --strict "$STAGING_DIR/听文.app"
hdiutil create -volname "听文 ${VERSION}" -srcfolder "$STAGING_DIR" \
    -format UDZO -fs HFS+ "$WORK_DIR/$IMAGE_NAME"
hdiutil verify "$WORK_DIR/$IMAGE_NAME"
mv "$WORK_DIR/$IMAGE_NAME" "$PROJECT_DIR/dist/$IMAGE_NAME"
(cd "$PROJECT_DIR/dist" && shasum -a 256 "$IMAGE_NAME" > "$IMAGE_NAME.sha256")
printf '\n已生成：%s\n校验文件：%s\n' "$PROJECT_DIR/dist/$IMAGE_NAME" "$PROJECT_DIR/dist/$IMAGE_NAME.sha256"
