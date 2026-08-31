#!/bin/bash
# Assina, notariza e empacota o Teya Code Station para distribuicao fora da App Store.
#
# Requisitos no Mac (ou no runner):
#   - Certificado "Developer ID Application: Teya Services Limited (QZG8V8U2Y6)" na keychain
#   - Chave de API do App Store Connect (.p8) com role Developer ou superior
#   - Xcode command line tools (codesign, notarytool, stapler, hdiutil)
#
# Uso:
#   export AC_API_KEY_PATH=~/private_keys/AuthKey_XXXXXXXXXX.p8
#   export AC_API_KEY_ID=XXXXXXXXXX
#   export AC_API_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   ./Scripts/release.sh 1.2.0
#
set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "uso: $0 <versao>   (ex.: $0 1.2.0)" >&2
    exit 1
fi
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

APP_NAME="Teya Code Station"
APP="build/$APP_NAME.app"
DMG="build/TeyaCodeStation-$VERSION.dmg"
TEAM_ID="${TEAM_ID:-QZG8V8U2Y6}"
IDENTITY="${SIGN_IDENTITY:-Developer ID Application: Teya Services Limited ($TEAM_ID)}"
ENTITLEMENTS="Resources/CodeStation.entitlements"

: "${AC_API_KEY_PATH:?falta AC_API_KEY_PATH (caminho para o .p8)}"
: "${AC_API_KEY_ID:?falta AC_API_KEY_ID}"
: "${AC_API_ISSUER_ID:?falta AC_API_ISSUER_ID}"

# As credenciais vao DEPOIS do subcomando: "notarytool submit <file> --key ..."
NOTARY_ARGS=(--key "$AC_API_KEY_PATH"
             --key-id "$AC_API_KEY_ID"
             --issuer "$AC_API_ISSUER_ID")

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- 1. build
step "A construir $APP_NAME $VERSION ($BUILD_NUMBER)"
./build-app.sh release

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER"       "$APP/Contents/Info.plist"

# ---------------------------------------------------------------- 2. assinar
# O build-app.sh deixa uma assinatura ad-hoc. Substitui-se por Developer ID,
# de dentro para fora: primeiro tudo o que esta encaixado, depois a app.
step "A assinar com: $IDENTITY"

sign() {
    codesign --force \
             --sign "$IDENTITY" \
             --options runtime \
             --timestamp \
             --entitlements "$ENTITLEMENTS" \
             "$@"
}

# Nested bundles, frameworks e binarios soltos primeiro (nunca uses --deep:
# a Apple desaconselha-o e nao aplica entitlements aos nested correctamente).
# Bundles so de recursos (ex.: MenuBarApp_MenuBarApp.bundle, sem Mach-O) nao
# sao assinaveis; ficam selados pela assinatura da app.
has_macho() {
    [ -n "$(find "$1" -type f -exec sh -c 'file -b "$0" 2>/dev/null | grep -q Mach-O' {} \; -print -quit)" ]
}

while IFS= read -r -d '' nested; do
    if ! has_macho "$nested"; then
        echo "    sem codigo, salto: ${nested#$APP/}"
        continue
    fi
    echo "    nested: ${nested#$APP/}"
    sign "$nested"
done < <(find "$APP/Contents" \
              \( -name '*.framework' -o -name '*.bundle' -o -name '*.dylib' -o -name '*.so' \) \
              -print0 | sort -rz)

sign "$APP"

step "A verificar a assinatura"
codesign --verify --strict --deep --verbose=2 "$APP"
codesign --display --verbose=4 "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier|flags|Timestamp'

# ---------------------------------------------------------------- 3. notarizar a app
step "A notarizar a app (pode demorar 1-15 min)"
ZIP="build/$APP_NAME-notarize.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --wait "${NOTARY_ARGS[@]}"
xcrun stapler staple "$APP"
rm -f "$ZIP"

# ---------------------------------------------------------------- 4. DMG
step "A criar o DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" \
               -srcfolder "$STAGE" \
               -fs HFS+ -format UDZO -ov \
               "$DMG"
rm -rf "$STAGE"

step "A assinar e notarizar o DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --wait "${NOTARY_ARGS[@]}"
xcrun stapler staple "$DMG"

# ---------------------------------------------------------------- 5. validar
step "Validacao final (e' isto que o Gatekeeper vai ver)"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"
spctl --assess --type execute -vv "$APP"

shasum -a 256 "$DMG" | tee "$DMG.sha256"

printf '\n\033[1;32mPronto:\033[0m %s\n' "$DMG"
