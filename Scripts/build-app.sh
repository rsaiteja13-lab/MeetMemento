#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_DIR/Dist"
APP_DIR="$DIST_DIR/MeetMemento.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE="$PROJECT_DIR/.build/ModuleCache"
ARCHITECTURES="${ARCHITECTURES:-arm64 x86_64}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

mkdir -p "$MODULE_CACHE"

# Some standalone Command Line Tools installations retain an older compatible SDK.
if ! xcodebuild -version >/dev/null 2>&1 && [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk ]]; then
    export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk
fi
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

binary_paths=()
for architecture in $ARCHITECTURES; do
    swift build --disable-sandbox -c release --arch "$architecture"
    binary_dir="$(swift build --disable-sandbox -c release --arch "$architecture" --show-bin-path)"
    binary_paths+=("$binary_dir/MeetMemento")
done

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
if [[ ${#binary_paths[@]} -eq 1 ]]; then
    cp "${binary_paths[0]}" "$MACOS_DIR/MeetMemento"
else
    lipo -create "${binary_paths[@]}" -output "$MACOS_DIR/MeetMemento"
fi
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

icon_source="$PROJECT_DIR/Resources/AppIcon.svg"
icon_work="$PROJECT_DIR/.build/AppIcon.iconset"
icon_master="$PROJECT_DIR/.build/AppIcon-1024.png"
if ! sips -s format png "$icon_source" --out "$icon_master" >/dev/null 2>&1; then
    swiftc -parse-as-library "$PROJECT_DIR/Tools/IconRenderer.swift" -o "$PROJECT_DIR/.build/IconRenderer"
    "$PROJECT_DIR/.build/IconRenderer" "$icon_master"
fi
if [[ -f "$icon_master" ]]; then
    rm -rf "$icon_work"
    mkdir -p "$icon_work"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$icon_master" --out "$icon_work/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$icon_master" --out "$icon_work/icon_${size}x${size}@2x.png" >/dev/null
    done
    if ! iconutil -c icns "$icon_work" -o "$RESOURCES_DIR/MeetMemento.icns" 2>/dev/null; then
        swiftc -parse-as-library "$PROJECT_DIR/Tools/IconPacker.swift" -o "$PROJECT_DIR/.build/IconPacker"
        "$PROJECT_DIR/.build/IconPacker" "$icon_work" "$RESOURCES_DIR/MeetMemento.icns"
    fi
fi

codesign --force --deep --options runtime --timestamp \
    --entitlements "$PROJECT_DIR/Resources/MeetMemento.entitlements" \
    --sign "$SIGNING_IDENTITY" "$APP_DIR"

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "$APP_DIR"
