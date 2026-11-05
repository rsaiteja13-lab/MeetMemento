#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_BINARY="$PROJECT_DIR/.build/MeetMementoChecks"
MODULE_CACHE="$PROJECT_DIR/.build/ModuleCache"

mkdir -p "$MODULE_CACHE"
SWIFTC="$(xcrun --find swiftc)"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

"$SWIFTC" \
    -sdk "$SDKROOT" \
    -module-cache-path "$MODULE_CACHE" \
    -swift-version 5 \
    "$PROJECT_DIR/Sources/MeetMemento/Models.swift" \
    "$PROJECT_DIR/Sources/MeetMemento/TranscriptFormatter.swift" \
    "$PROJECT_DIR/Sources/MeetMemento/MeetingNamer.swift" \
    "$PROJECT_DIR/Sources/MeetMemento/ZoomSignalClassifier.swift" \
    "$PROJECT_DIR/Tests/CheckMain.swift" \
    -o "$CHECK_BINARY"
"$CHECK_BINARY"
