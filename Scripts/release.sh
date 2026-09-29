#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_DIR/Dist/MeetMemento.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
ZIP_PATH="$PROJECT_DIR/Dist/MeetMemento-$VERSION.zip"

if [[ -z "${SIGNING_IDENTITY:-}" || "$SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
    echo "Set SIGNING_IDENTITY to a Developer ID Application certificate name."
    echo "Ad-hoc, Apple Development, and locally trusted certificates are not distributable releases."
    exit 1
fi
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "Set NOTARY_PROFILE to a notarytool keychain profile name."
    exit 1
fi

"$SCRIPT_DIR/build-app.sh"

signature_details="$(codesign -d --verbose=4 "$APP_DIR" 2>&1)"
if grep -Fq "Signature=adhoc" <<<"$signature_details" \
    || grep -Fq "TeamIdentifier=not set" <<<"$signature_details"; then
    echo "Release validation failed: MeetMemento does not have a stable Developer ID signature."
    exit 1
fi

rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_DIR"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
spctl --assess --type execute --verbose=2 "$APP_DIR"
echo "$ZIP_PATH"
