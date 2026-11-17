#!/bin/zsh
# 构建 LightMonitor.app（release + ad-hoc 签名）
set -euo pipefail
cd "$(dirname "$0")"

OUT="${TMPDIR:-/tmp}/lightmonitor-build"
mkdir -p "$OUT"

swiftc -O -swift-version 5 \
    Sources/LightMonitor/*.swift \
    -o "$OUT/LightMonitor" \
    -framework AppKit -framework SwiftUI -framework IOKit \
    -framework ServiceManagement -framework Combine -lsqlite3

APP="../LightMonitor.app"
mkdir -p "$APP/Contents/MacOS"
cp "$OUT/LightMonitor" "$APP/Contents/MacOS/LightMonitor"
cp Info.plist "$APP/Contents/Info.plist"

codesign --force --sign - "$APP"
echo "Built: $APP"