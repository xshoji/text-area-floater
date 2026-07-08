#!/bin/bash
# TextAreaFloater ビルドスクリプト
# SwiftPM なしで swiftc を直接叩いて .app バンドルを生成する

set -e

APP_NAME="TextAreaFloater"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
SRC_DIR="Sources/TextAreaApp"

echo "==> クリーンアップ"
rm -rf "$APP_DIR"

echo "==> バンドル構造作成"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

echo "==> コンパイル"
swiftc \
  -parse-as-library \
  -O \
  -framework SwiftUI -framework AppKit -framework ApplicationServices -framework Carbon \
  -sdk "$(xcrun --show-sdk-path)" \
  "$SRC_DIR"/*.swift \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME" 2>&1

echo "==> Info.plist コピー"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

echo "==> アイコンコピー"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

echo ""
echo "==> ビルド完了: $APP_DIR"
echo "起動: open $APP_DIR"
