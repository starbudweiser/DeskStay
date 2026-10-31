#!/bin/bash
# Compile DeskStay et produit build/DeskStay.app.
# Signature : certificat local stable (sign_app.sh), macOS garde ainsi les autorisations d'un build à l'autre.
# Autre identité : SIGN_IDENTITY="<empreinte SHA-1 ou nom du certificat>" ./build.sh
# Essais réels : SELFTEST=1 ./build.sh ajoute le pilotage sans menu (voir SelfTest.swift).
set -euo pipefail
cd "$(dirname "$0")"

SIGN_TOOL="/Volumes/SKYRIM/TOOLS/MAC/_tools/sign_app.sh"
APP="build/DeskStay.app"
FLAGS=()
[ "${SELFTEST:-0}" = "1" ] && FLAGS=(-Xswiftc -DDESKSTAY_SELFTEST)

swift build -c release ${FLAGS[@]+"${FLAGS[@]}"}
BIN="$(swift build -c release ${FLAGS[@]+"${FLAGS[@]}"} --show-bin-path)/DeskStay"
[ -x "$BIN" ] || { echo "Binaire introuvable : $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DeskStay"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
    codesign --verify --strict "$APP"
else
    "$SIGN_TOOL" "$APP"
fi
echo "OK : $(pwd)/$APP"
