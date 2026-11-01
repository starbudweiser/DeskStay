#!/bin/bash
# Compile DeSKSTAY et produit build/DeSKSTAY.app.
# Signature : certificat local stable (sign_app.sh), macOS garde ainsi les autorisations d'un build à l'autre.
# Autre identité : SIGN_IDENTITY="<empreinte SHA-1 ou nom du certificat>" ./build.sh
# Un build normal est déplacé dans ~/Applications/Home Applications (INSTALL_DIR pour un autre dossier).
# Essais réels : SELFTEST=1 ./build.sh ajoute le pilotage sans menu (voir SelfTest.swift).
set -euo pipefail
cd "$(dirname "$0")"

SIGN_TOOL="/Volumes/SKYRIM/TOOLS/MAC/_tools/sign_app.sh"
APP="build/DeSKSTAY.app"
FLAGS=()
[ "${SELFTEST:-0}" = "1" ] && FLAGS=(-Xswiftc -DDESKSTAY_SELFTEST)

swift build -c release ${FLAGS[@]+"${FLAGS[@]}"}
BIN="$(swift build -c release ${FLAGS[@]+"${FLAGS[@]}"} --show-bin-path)/DeSKSTAY"
[ -x "$BIN" ] || { echo "Binaire introuvable : $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DeSKSTAY"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/" # textes fr, en, es, it
cp assets/icon.icns "$APP/Contents/Resources/icon.icns"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP"
    codesign --verify --strict "$APP"
else
    "$SIGN_TOOL" "$APP"
fi

# Build normal : l'app est déplacée (plus de copie dans build/). Le build d'essai reste dans build/.
if [ "${SELFTEST:-0}" != "1" ]; then
    DEST="${INSTALL_DIR:-$HOME/Applications/Home Applications}"
    mkdir -p "$DEST"
    pgrep -x DeSKSTAY >/dev/null && echo "ATTENTION : DeSKSTAY tourne, relancez-le pour utiliser la nouvelle version." >&2
    rm -rf "$DEST/DeSKSTAY.app" "$DEST/DeskStay.app" # DeskStay.app : ancien nom
    mv "$APP" "$DEST/DeSKSTAY.app"
    echo "OK : $DEST/DeSKSTAY.app"
else
    echo "OK : $(pwd)/$APP (build d'essai)"
fi
