#!/bin/bash
# Builds LLMUsageWidget.app (Apple Silicon and Intel) into ./build.
# With "install", also copies it to /Applications (or ~/Applications) and restarts it there.
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"

APP=build/LLMUsageWidget.app
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release "${ARCHS[@]}" --show-bin-path)/LLMUsageWidget" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    DEST=/Applications
    [[ -w "$DEST" ]] || DEST="$HOME/Applications"
    mkdir -p "$DEST"
    pkill -x LLMUsageWidget || true
    while pgrep -x LLMUsageWidget >/dev/null; do sleep 0.1; done
    ditto "$APP" "$DEST/LLMUsageWidget.app"
    open "$DEST/LLMUsageWidget.app"
    echo "Installed $DEST/LLMUsageWidget.app"
fi
