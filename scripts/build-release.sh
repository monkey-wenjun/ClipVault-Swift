#!/bin/bash
set -euo pipefail

# CI / 本地构建脚本：编译 Release 版本并打包成 zip，不安装到 /Applications。
#
# 用法：
#   ./scripts/build-release.sh
#
# 输出：build/ClipVault-v{版本号}.app.zip

cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist)

echo "Building ClipVault $VERSION ($BUILD)..."

swift build -c release

APP_DIR="build/ClipVault.app"
ZIP_NAME="build/ClipVault-v${VERSION}.app.zip"

rm -rf "$APP_DIR"
rm -f "$ZIP_NAME"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/release/ClipVault "$APP_DIR/Contents/MacOS/ClipVault"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/ClipVault.icns "$APP_DIR/Contents/Resources/ClipVault.icns"
cp Resources/StatusIcon.png "$APP_DIR/Contents/Resources/StatusIcon.png"
cp Resources/StatusIcon@2x.png "$APP_DIR/Contents/Resources/StatusIcon@2x.png"

# CI 环境或没有 Apple Development 证书时使用 ad-hoc 签名
codesign --force --sign "-" "$APP_DIR" >/dev/null

ditto -c -k --keepParent "$APP_DIR" "$ZIP_NAME"

echo ""
echo "构建完成: $ZIP_NAME"
