#!/usr/bin/env python3
"""Genera el icono de la app (1024x1024) en el asset catalog."""
from pathlib import Path
from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "Shield/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
S = 1024
img = Image.new("RGB", (S, S))
d = ImageDraw.Draw(img)
for y in range(S):
    t = y / S
    d.line([(0, y), (S, y)], fill=(int(255 - 25 * t), int(95 - 45 * t), int(30 - 10 * t)))
cx = S / 2
d.polygon([(cx, 170), (820, 280), (800, 560), (cx, 880), (224, 560), (204, 280)], fill=(255, 255, 255))
d.polygon([(cx, 240), (750, 325), (735, 545), (cx, 800), (289, 545), (274, 325)], fill=(245, 110, 35))
d.line([(380, 520), (480, 620), (660, 410)], fill=(255, 255, 255), width=60, joint="curve")
img.save(OUT)
