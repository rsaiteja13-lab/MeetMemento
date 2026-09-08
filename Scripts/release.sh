#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_DIR/Dist/MeetMemento.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
ZIP_PATH="$PROJECT_DIR/Dist/MeetMemento-$VERSION.zip"

if [[ -z "${SIGNING_IDENTITY:-}" || "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Set SIGNING_IDENTITY to an Apple Developer ID Application certificate name."
    exit 1
fi
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "Set NOTARY_PROFILE to a notarytool keychain profile name."
    exit 1
fi

"$SCRIPT_DIR/build-app.sh"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_DIR"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
spctl --assess --type execute --verbose=2 "$APP_DIR"
echo "$ZIP_PATH"
