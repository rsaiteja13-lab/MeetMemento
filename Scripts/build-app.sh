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
if [[ -z "${SIGNING_IDENTITY:-}" ]]; then
    if security find-identity -v -p codesigning 2>/dev/null \
        | grep -Fq '"MeetMemento Local Code Signing"'; then
        SIGNING_IDENTITY="MeetMemento Local Code Signing"
    else
        SIGNING_IDENTITY="-"
    fi
fi

# An ad-hoc signature changes identity every time the executable changes. That
# makes macOS Screen Recording permissions appear to be present in System
# Settings while no longer applying to the newly installed build. Keep ad-hoc
# signing available for CI and short-lived development builds, but require an
# explicit opt-in so it can never be mistaken for a distributable update.
if [[ "$SIGNING_IDENTITY" == "-" && "${ALLOW_ADHOC_SIGNING:-0}" != "1" ]]; then
    echo "Refusing to create an installable ad-hoc build." >&2
    echo "Set SIGNING_IDENTITY to a stable code-signing certificate." >&2
    echo "For CI or a disposable development build only, set ALLOW_ADHOC_SIGNING=1." >&2
    exit 1
fi

mkdir -p "$MODULE_CACHE"

SWIFTC="$(xcrun --find swiftc)"
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

binary_paths=()
keeper_binary_paths=()
source_files=("$PROJECT_DIR"/Sources/MeetMemento/*.swift)
keeper_source="$PROJECT_DIR/Sources/MeetMementoKeeper/main.swift"
toolchain_usr="$(cd "$(dirname "$SWIFTC")/.." && pwd)"
plugin_path="$toolchain_usr/lib/swift/host/plugins"
for architecture in $ARCHITECTURES; do
    binary_dir="$PROJECT_DIR/.build/manual-$architecture/release"
    mkdir -p "$binary_dir"
    "$SWIFTC" \
        -parse-as-library \
        -O \
        -whole-module-optimization \
        -sdk "$SDKROOT" \
        -module-cache-path "$MODULE_CACHE" \
        -target "$architecture-apple-macosx13.0" \
        -plugin-path "$plugin_path" \
        "${source_files[@]}" \
        -o "$binary_dir/MeetMemento" \
        -framework AVFoundation \
        -framework AVKit \
        -framework AppKit \
        -framework CoreGraphics \
        -framework EventKit \
        -framework ScreenCaptureKit \
        -framework ServiceManagement \
        -framework Speech \
        -framework SwiftUI \
        -framework UserNotifications
    binary_paths+=("$binary_dir/MeetMemento")

    "$SWIFTC" \
        -parse-as-library \
        -O \
        -whole-module-optimization \
        -sdk "$SDKROOT" \
        -module-cache-path "$MODULE_CACHE" \
        -target "$architecture-apple-macosx13.0" \
        "$keeper_source" \
        -o "$binary_dir/MeetMementoKeeper" \
        -framework AppKit
    keeper_binary_paths+=("$binary_dir/MeetMementoKeeper")
done

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
if [[ ${#binary_paths[@]} -eq 1 ]]; then
    cp "${binary_paths[0]}" "$MACOS_DIR/MeetMemento"
else
    lipo -create "${binary_paths[@]}" -output "$MACOS_DIR/MeetMemento"
fi
if [[ ${#keeper_binary_paths[@]} -eq 1 ]]; then
    cp "${keeper_binary_paths[0]}" "$RESOURCES_DIR/MeetMementoKeeper"
else
    lipo -create "${keeper_binary_paths[@]}" -output "$RESOURCES_DIR/MeetMementoKeeper"
fi
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

icon_source="$PROJECT_DIR/Resources/AppIcon.svg"
icon_work="$PROJECT_DIR/.build/AppIcon.iconset"
icon_master="$PROJECT_DIR/.build/AppIcon-1024.png"
if ! sips -s format png "$icon_source" --out "$icon_master" >/dev/null 2>&1; then
        "$SWIFTC" -parse-as-library -sdk "$SDKROOT" -module-cache-path "$MODULE_CACHE" \
            "$PROJECT_DIR/Tools/IconRenderer.swift" -o "$PROJECT_DIR/.build/IconRenderer"
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
        "$SWIFTC" -parse-as-library -sdk "$SDKROOT" -module-cache-path "$MODULE_CACHE" \
            "$PROJECT_DIR/Tools/IconPacker.swift" -o "$PROJECT_DIR/.build/IconPacker"
        "$PROJECT_DIR/.build/IconPacker" "$icon_work" "$RESOURCES_DIR/MeetMemento.icns"
    fi
fi

timestamp_option="--timestamp=none"
if [[ "$SIGNING_IDENTITY" == "Developer ID Application:"* ]]; then
    timestamp_option="--timestamp"
fi
codesign --force --options runtime "$timestamp_option" \
    --sign "$SIGNING_IDENTITY" "$RESOURCES_DIR/MeetMementoKeeper"
codesign --force --deep --options runtime "$timestamp_option" \
    --entitlements "$PROJECT_DIR/Resources/MeetMemento.entitlements" \
    --sign "$SIGNING_IDENTITY" "$APP_DIR"

codesign --verify --deep --strict --verbose=2 "$APP_DIR"
"$RESOURCES_DIR/MeetMementoKeeper" --self-test
echo "$APP_DIR"
