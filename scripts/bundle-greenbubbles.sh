#!/bin/bash
# Embed the complete official Apple Silicon distribution, pinned and verified.
set -euo pipefail

TARS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARS_BUNDLE="${1:?Usage: bundle-greenbubbles.sh /path/to/Tars.app}"
GB_VERSION="0.10.0"
GB_ARCHIVE="greenbubbles-$GB_VERSION-macos-arm64.zip"
GB_SHA256="3886b441d85c36a087de34956a14071dbf235166ef4d943df949ea7936c99047"
GB_CACHE="$TARS_ROOT/.greenbubbles-cache/$GB_VERSION"
GB_SOURCE="$GB_CACHE/greenbubbles-$GB_VERSION-macos-arm64"

mkdir -p "$GB_CACHE"
if [ ! -f "$GB_CACHE/$GB_ARCHIVE" ]; then
    echo "📥 下载 GreenBubbles $GB_VERSION..."
    curl --http1.1 -fL --connect-timeout 20 --max-time 240 --retry 2 \
        -o "$GB_CACHE/$GB_ARCHIVE.partial" \
        "https://github.com/bojieli/greenbubbles/releases/download/v$GB_VERSION/$GB_ARCHIVE"
    mv "$GB_CACHE/$GB_ARCHIVE.partial" "$GB_CACHE/$GB_ARCHIVE"
fi
GB_ACTUAL="$(shasum -a 256 "$GB_CACHE/$GB_ARCHIVE" | awk '{print $1}')"
if [ "$GB_ACTUAL" != "$GB_SHA256" ]; then
    echo "❌ GreenBubbles 下载校验失败，请删除 .greenbubbles-cache 后重试。" >&2
    exit 1
fi
# Extract from the verified archive on every build, rather than trusting cache edits.
rm -rf "$GB_SOURCE"
ditto -x -k "$GB_CACHE/$GB_ARCHIVE" "$GB_CACHE"
mkdir -p "$TARS_BUNDLE/Contents/MacOS" "$TARS_BUNDLE/Contents/Resources/GreenBubbles"
for GB_TOOL in "$GB_SOURCE"/bin/*; do
    codesign --verify --strict "$GB_TOOL"
    cp "$GB_TOOL" "$TARS_BUNDLE/Contents/MacOS/"
done
for GB_ENTRY in "$GB_SOURCE"/*; do
    if [ "$(basename "$GB_ENTRY")" != "bin" ]; then
        ditto "$GB_ENTRY" "$TARS_BUNDLE/Contents/Resources/GreenBubbles/$(basename "$GB_ENTRY")"
    fi
done
echo "📦 已嵌入 GreenBubbles $GB_VERSION 完整工具包（Apple Silicon）"
