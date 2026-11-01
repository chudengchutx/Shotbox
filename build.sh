#!/bin/bash
# 构建并打包 Shotbox.app（ad-hoc 签名，无需开发者证书）
set -euo pipefail

cd "$(dirname "$0")"

echo "==> 编译 release"
swift build -c release

APP="Shotbox.app"
BIN="$(swift build -c release --show-bin-path)/Shotbox"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Shotbox"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 用固定的开发者证书签名：ad-hoc 签名没有证书，TCC 只能按 cdhash 记录授权，
# 每次重建都会让「屏幕录制」权限失效。指定证书后授权按「证书 + bundle id」记录，可长期复用。
IDENTITY="${SHOTBOX_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | grep -v REVOKED | head -1 | awk '{print $2}')}"

if [ -n "$IDENTITY" ]; then
  echo "==> 使用证书签名: $IDENTITY"
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
  echo "==> 未找到开发者证书，回退 ad-hoc 签名（每次重建都需要重新授权屏幕录制）"
  codesign --force --sign - --timestamp=none "$APP"
fi

echo "==> 完成: $(pwd)/$APP"
echo "运行: open $(pwd)/$APP"
