#!/bin/bash
# Compile DeskStay et produit build/DeskStay.app.
# Signature : certificat local stable (sign_app.sh), macOS garde ainsi les autorisations d'un build à l'autre.
# Autre identité : SIGN_IDENTITY="<empreinte SHA-1 ou nom du certificat>" ./build.sh
# Un build normal est déplacé dans ~/Applications/Utilitaires+ (INSTALL_DIR pour un autre dossier).
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
    DEST="${INSTALL_DIR:-$HOME/Applications/Utilitaires+}"
    mkdir -p "$DEST"
    pgrep -x DeskStay >/dev/null && echo "ATTENTION : DeskStay tourne, relancez-le pour utiliser la nouvelle version." >&2
    rm -rf "$DEST/DeskStay.app"
    mv "$APP" "$DEST/DeskStay.app"
    echo "OK : $DEST/DeskStay.app"
else
    echo "OK : $(pwd)/$APP (build d'essai)"
fi
