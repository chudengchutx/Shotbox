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
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ad-hoc 签名"
codesign --force --sign - --timestamp=none "$APP"

echo "==> 完成: $(pwd)/$APP"
echo "运行: open $(pwd)/$APP"
