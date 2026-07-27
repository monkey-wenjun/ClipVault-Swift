#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

swift build -c release

APP_DIR="build/ClipVault.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp .build/release/ClipVault "$APP_DIR/Contents/MacOS/ClipVault"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp Resources/ClipVault.icns "$APP_DIR/Contents/Resources/ClipVault.icns"
cp Resources/StatusIcon.png "$APP_DIR/Contents/Resources/StatusIcon.png"
cp Resources/StatusIcon@2x.png "$APP_DIR/Contents/Resources/StatusIcon@2x.png"

# 用固定的签名身份签名：ad-hoc 签名每次构建哈希都变，
# 会导致辅助功能等 TCC 授权和 Keychain ACL 在每次构建后失效。
# 优先使用钥匙串中已有的 Apple Development 证书（稳定有效），没有则退回 ad-hoc。
IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development:" | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)
if [ -z "${IDENTITY:-}" ]; then
    echo "No Apple Development identity found, falling back to ad-hoc signing"
    IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP_DIR" >/dev/null

echo "Built $APP_DIR"
echo "Run with: open $APP_DIR"
