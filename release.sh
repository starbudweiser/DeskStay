#!/bin/bash
# Version distribuable : signature Developer ID + runtime renforcé, archive, notarisation, agrafage.
# Prérequis (une seule fois) : xcrun notarytool store-credentials "deskstay-notary" --apple-id <id> --team-id 35KLMK53PN
# (mot de passe d'application créé sur appleid.apple.com). Autre profil : NOTARY_PROFILE=<nom> ./release.sh
# Sans profil enregistré, le script s'arrête après la signature et l'archive (dist/DeSKSTAY.zip).
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${DEVELOPER_ID:-CB7AAA54D6B7D15300C362B8E1D8334F1A3581C6}" # Developer ID Application (trousseau skyrim-signing)
PROFILE="${NOTARY_PROFILE:-deskstay-notary}"
APP="dist/DeSKSTAY.app"
ZIP="dist/DeSKSTAY.zip"

mkdir -p dist
INSTALL_DIR="$(pwd)/dist" ./build.sh   # compile, signe en local, place l'appli dans dist/
codesign --force --options runtime --timestamp --entitlements Resources/DeSKSTAY.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "Signé (Developer ID) et archivé : $ZIP" >&2
    echo "Notarisation non faite : profil « $PROFILE » absent (voir l'en-tête de ce script)." >&2
    exit 2
fi
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"
echo "OK : $ZIP (notarisée)"
