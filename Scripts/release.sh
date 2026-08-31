#!/bin/bash
# Signs, notarizes and packages Teya Code Station for distribution outside the App Store.
#
# Needed on the Mac (or on the runner):
#   - "Developer ID Application: Teya Services Limited (QZG8V8U2Y6)" certificate in the keychain
#   - App Store Connect API key (.p8) with the Developer role or higher
#   - Xcode command line tools (codesign, notarytool, stapler, hdiutil)
#
# Usage:
#   export AC_API_KEY_PATH=~/private_keys/AuthKey_XXXXXXXXXX.p8
#   export AC_API_KEY_ID=XXXXXXXXXX
#   export AC_API_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   ./Scripts/release.sh 1.2.0
#
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <version>   (e.g.: $0 1.2.0)" >&2
    exit 1
fi
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

APP_NAME="Teya Code Station"
APP="build/$APP_NAME.app"
DMG="build/TeyaCodeStation-$VERSION.dmg"
TEAM_ID="${TEAM_ID:-QZG8V8U2Y6}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Teya Services Limited ($TEAM_ID)}"
ENTITLEMENTS="Resources/CodeStation.entitlements"

: "${AC_API_KEY_PATH:?missing AC_API_KEY_PATH (path to the .p8)}"
: "${AC_API_KEY_ID:?missing AC_API_KEY_ID}"
: "${AC_API_ISSUER_ID:?missing AC_API_ISSUER_ID}"

# The credentials go AFTER the subcommand: "notarytool submit <file> --key ..."
NOTARY_ARGS=(--key "$AC_API_KEY_PATH"
             --key-id "$AC_API_KEY_ID"
             --issuer "$AC_API_ISSUER_ID")

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- 1. build
step "Building $APP_NAME $VERSION ($BUILD_NUMBER)"
./build-app.sh release

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER"       "$APP/Contents/Info.plist"

# ---------------------------------------------------------------- 2. sign
# build-app.sh leaves an ad-hoc signature. It gets replaced with Developer ID,
# from the inside out: everything nested first, then the app itself.
step "Signing with: $IDENTITY"

sign() {
    codesign --force \
             --sign "$IDENTITY" \
             --options runtime \
             --timestamp \
             --entitlements "$ENTITLEMENTS" \
             "$@"
}

# Nested bundles, frameworks and loose binaries first (never use --deep:
# Apple advises against it and it does not apply entitlements to the nested
# code correctly). Resource-only bundles (e.g. MenuBarApp_MenuBarApp.bundle,
# with no Mach-O) cannot be signed; the app signature seals them instead.
has_macho() {
    [ -n "$(find "$1" -type f -exec sh -c 'file -b "$0" 2>/dev/null | grep -q Mach-O' {} \; -print -quit)" ]
}

while IFS= read -r -d '' nested; do
    if ! has_macho "$nested"; then
        echo "    no code, skipping: ${nested#$APP/}"
        continue
    fi
    echo "    nested: ${nested#$APP/}"
    sign "$nested"
done < <(find "$APP/Contents" \
              \( -name '*.framework' -o -name '*.bundle' -o -name '*.dylib' -o -name '*.so' \) \
              -print0 | sort -rz)

sign "$APP"

step "Checking the signature"
codesign --verify --strict --deep --verbose=2 "$APP"
codesign --display --verbose=4 "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier|flags|Timestamp'

# ---------------------------------------------------------------- 3. notarize the app
step "Notarizing the app (can take 1-15 min)"
ZIP="build/$APP_NAME-notarize.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --wait "${NOTARY_ARGS[@]}"
xcrun stapler staple "$APP"
rm -f "$ZIP"

# ---------------------------------------------------------------- 4. DMG
step "Building the DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" \
               -srcfolder "$STAGE" \
               -fs HFS+ -format UDZO -ov \
               "$DMG"
rm -rf "$STAGE"

step "Signing and notarizing the DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --wait "${NOTARY_ARGS[@]}"
xcrun stapler staple "$DMG"

# ---------------------------------------------------------------- 5. validate
step "Final check (this is what Gatekeeper will see)"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
spctl --assess --type execute -vv "$APP"

shasum -a 256 "$DMG" | tee "$DMG.sha256"

printf '\n\033[1;32mDone:\033[0m %s\n' "$DMG"
