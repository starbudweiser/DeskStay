"""Dessine l'icône de DeskStay (1024 px, couleurs Socle) puis produit icon.icns avec iconutil.
Une fenêtre qui reste en place, avec les icônes du Bureau en grille : DIM + Stay."""
import json, os, subprocess, sys, tempfile
from PyQt6.QtCore import QPointF, QRectF, Qt
from PyQt6.QtGui import QColor, QGuiApplication, QImage, QLinearGradient, QPainter, QPen

here = os.path.dirname(os.path.abspath(__file__))
tokens = {t["name"]: (t["value"]["dark"] if isinstance(t["value"], dict) else t["value"]) for t in
          json.load(open("/Volumes/SKYRIM/TOOLS/DESIGN/Socle/tokens.json"))["color"]["tokens"]}
c = lambda name: QColor(tokens[name])

app = QGuiApplication(sys.argv)
img = QImage(1024, 1024, QImage.Format.Format_ARGB32)
img.fill(Qt.GlobalColor.transparent)
p = QPainter(img)
p.setRenderHint(QPainter.RenderHint.Antialiasing)
p.setPen(Qt.PenStyle.NoPen)

# tuile sombre, comme csSETTINGS, kEYKODES et fOLDERFUSE
tile = QRectF(100, 100, 824, 824)
g = QLinearGradient(tile.topLeft(), tile.bottomLeft())
g.setColorAt(0, QColor("#2c2f34"))
g.setColorAt(1, QColor("#1b1d21"))
p.setBrush(g)
p.drawRoundedRect(tile, 180, 180)

# icônes du Bureau en L (haut gauche) : deux neutres, une accent ; le coin bas droit est pris par la fenêtre
size, gap, x0, y0 = 150, 44, 218, 218
cells = [(0, 0, c("text-muted")), (1, 0, c("accent")), (0, 1, c("text-muted"))]
for cx, cy, col in cells:
    p.setBrush(col)
    p.drawRoundedRect(QRectF(x0 + cx * (size + gap), y0 + cy * (size + gap), size, size), 42, 42)

# fenêtre épinglée (bas droite) : corps clair, zone de contenu sombre, épingle ambre
win = QRectF(430, 450, 380, 340)
p.setBrush(c("text-strong"))
p.drawRoundedRect(win, 48, 48)
p.setBrush(c("bg-inset"))
p.drawRoundedRect(QRectF(win.left() + 34, win.top() + 92, win.width() - 68, win.height() - 126), 26, 26)
pin = QPointF(win.right() - 6, win.top() + 6)
p.setBrush(c("action"))
p.drawEllipse(pin, 82, 82)
p.setBrush(QColor("#1b1d21"))
p.drawEllipse(pin, 28, 28)
p.end()

png = os.path.join(here, "icon.png")
img.save(png)
with tempfile.TemporaryDirectory() as tmp:
    iconset = os.path.join(tmp, "icon.iconset"); os.mkdir(iconset)
    for s in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            n = f"icon_{s}x{s}{'@2x' if scale == 2 else ''}.png"
            img.scaled(s * scale, s * scale, Qt.AspectRatioMode.KeepAspectRatio,
                       Qt.TransformationMode.SmoothTransformation).save(os.path.join(iconset, n))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(here, "icon.icns")], check=True)
print("icon.icns OK")
