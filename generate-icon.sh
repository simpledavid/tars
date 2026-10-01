#!/bin/bash
# 复用应用内的 TARS 绘制器，生成 PNG / iconset / macOS icns。
set -euo pipefail

ICON_PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
ICON_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tars-icon.XXXXXX")"
trap 'rm -rf "$ICON_TEMP_DIR"' EXIT

swiftc -parse-as-library -swift-version 6 \
    "$ICON_PROJECT_DIR/Sources/TarsPersonality.swift" \
    "$ICON_PROJECT_DIR/Sources/Models.swift" \
    "$ICON_PROJECT_DIR/Sources/PetPalette.swift" \
    "$ICON_PROJECT_DIR/Sources/TarsRobotDrawing.swift" \
    "$ICON_PROJECT_DIR/generate-icon.swift" \
    -o "$ICON_TEMP_DIR/generate-icon"
"$ICON_TEMP_DIR/generate-icon" "$ICON_PROJECT_DIR"
iconutil -c icns "$ICON_PROJECT_DIR/AppIcon.iconset" -o "$ICON_PROJECT_DIR/AppIcon.icns"
echo "已生成 AppIcon.icns"
