#!/bin/bash
set -euo pipefail

# 本地发版脚本：改版本号 -> 提交 -> 打 tag -> 推送 -> 打开 GitHub Release 创建页。
#
# 用法：
#   ./scripts/release.sh
#
# 之后去 GitHub 页面确认 Release 信息并上传构建好的 zip 包即可。

cd "$(dirname "$0")/.."

CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
echo "当前版本: $CURRENT_VERSION"

read -rp "新版本号 (例如 1.1.7): " NEW_VERSION
if [ -z "$NEW_VERSION" ]; then
    echo "错误：版本号不能为空"
    exit 1
fi

CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" Resources/Info.plist)
NEW_BUILD=$((CURRENT_BUILD + 1))

/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $NEW_VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $NEW_BUILD" Resources/Info.plist

echo "版本已更新为 $NEW_VERSION ($NEW_BUILD)"

git add Resources/Info.plist
git commit -m "chore: bump version to $NEW_VERSION ($NEW_BUILD)"

git tag "v$NEW_VERSION"
git push origin main
git push origin "v$NEW_VERSION"

RELEASE_URL="https://github.com/monkey-wenjun/ClipVault-Swift/releases/new?tag=v$NEW_VERSION"
echo ""
echo "已推送 tag v$NEW_VERSION"
echo "请在浏览器中打开以下链接创建 Release 并上传 zip："
echo "$RELEASE_URL"

if command -v open >/dev/null 2>&1; then
    open "$RELEASE_URL"
fi
