#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="剪贴板管理器"
APP_DIR="$ROOT/build/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

echo "==> 编译 Swift（release）"
cd "$ROOT"
swift build -c release --product ClipboardManagerMac

echo "==> 组装 App Bundle"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$ROOT/.build/release/ClipboardManagerMac" "$CONTENTS/MacOS/ClipboardManagerMac"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

echo "==> 生成图标"
ICONSET="$ROOT/build/icon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/scripts/make_icon.swift" "$ICONSET"
if command -v iconutil >/dev/null 2>&1; then
    iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
fi

echo "==> 临时签名"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "==> 完成：$APP_DIR"
