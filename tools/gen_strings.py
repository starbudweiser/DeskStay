"""Génère Resources/<langue>.lproj/{Localizable,InfoPlist}.strings à partir de tools/strings_table.py."""
import os, sys
sys.path.insert(0, os.path.dirname(__file__))
from strings_table import T, INFOPLIST, LANGS

def esc(s): return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources")
for i, lang in enumerate(LANGS):
    d = os.path.join(root, f"{lang}.lproj"); os.makedirs(d, exist_ok=True)
    for name, table in (("Localizable", T), ("InfoPlist", INFOPLIST)):
        with open(os.path.join(d, f"{name}.strings"), "w", encoding="utf-8") as f:
            f.write(f"/* DeskStay — {lang}. Fichier généré par tools/gen_strings.py : modifier tools/strings_table.py. */\n")
            for row in table:
                f.write(f'"{row[0]}" = "{esc(row[i + 1])}";\n')
print("OK", len(T), "textes,", len(LANGS), "langues")
