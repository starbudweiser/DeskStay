#!/bin/bash
# Compile DeskStay et produit build/DeskStay.app.
# Signature : SIGN_IDENTITY="<empreinte SHA-1 ou nom du certificat>" ./build.sh
# Sans SIGN_IDENTITY, signature ad hoc ("-") : macOS redemandera les autorisations après chaque recompilation.
set -euo pipefail
cd "$(dirname "$0")"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/DeskStay.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/DeskStay"
[ -x "$BIN" ] || { echo "Binaire introuvable : $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DeskStay"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "OK : $(pwd)/$APP"
