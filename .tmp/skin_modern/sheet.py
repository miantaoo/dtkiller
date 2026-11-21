# -*- coding: utf-8 -*-
"""Group carved WCPure images by hash and write a labelled contact sheet."""
import glob
import hashlib
import json
import os

from PIL import Image, ImageDraw

files = sorted(glob.glob("carved/WCPureExtension_png_*.png"))
groups = {}
for f in files:
    h = hashlib.sha256(open(f, "rb").read()).hexdigest()[:12]
    groups.setdefault(h, []).append(os.path.basename(f))

rows = []
for h, names in groups.items():
    im = Image.open("carved/" + names[0]).convert("RGBA")
    rows.append((h, names, im.size, os.path.getsize("carved/" + names[0])))
rows.sort(key=lambda r: r[1][0])

cols = 5
cw, ch = 400, 330
sheet = Image.new("RGB", (cols * cw, ((len(rows) + cols - 1) // cols) * ch), (245, 245, 247))
d = ImageDraw.Draw(sheet)
for i, (h, names, size, nbytes) in enumerate(rows):
    im = Image.open("carved/" + names[0]).convert("RGBA")
    bg = Image.new("RGBA", im.size, (255, 255, 255, 255))
    bg.alpha_composite(im)
    im = bg.convert("RGB")
    scale = min(2.2, 380 / im.width)
    im = im.resize((int(im.width * scale), int(im.height * scale)), Image.LANCZOS)
    x = (i % cols) * cw
    y = (i // cols) * ch
    sheet.paste(im, (x + 10, y + 10))
    d.text((x + 10, y + 10 + im.height + 6), "%s  %dx%d  %dB" % (h, size[0], size[1], nbytes),
           fill=(20, 20, 20))
    d.text((x + 10, y + 10 + im.height + 20), names[0][:44], fill=(90, 90, 90))
    if len(names) > 1:
        d.text((x + 10, y + 10 + im.height + 34), "dup x%d" % len(names), fill=(200, 60, 60))
sheet.save("contact_unique.png")
print(json.dumps({h: n for h, n in ((r[0], r[1]) for r in rows)}, indent=1, ensure_ascii=False))
print("unique:", len(rows), "total:", len(files))
