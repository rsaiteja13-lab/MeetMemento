#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK_BINARY="$PROJECT_DIR/.build/MeetMementoChecks"
MODULE_CACHE="$PROJECT_DIR/.build/ModuleCache"

mkdir -p "$MODULE_CACHE"
if ! xcodebuild -version >/dev/null 2>&1 && [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

swiftc \
    "$PROJECT_DIR/Sources/MeetMemento/Models.swift" \
    "$PROJECT_DIR/Sources/MeetMemento/TranscriptFormatter.swift" \
    "$PROJECT_DIR/Sources/MeetMemento/MeetingNamer.swift" \
    "$PROJECT_DIR/Tests/CheckMain.swift" \
    -o "$CHECK_BINARY"
"$CHECK_BINARY"
