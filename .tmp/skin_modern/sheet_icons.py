# -*- coding: utf-8 -*-
import glob
import os

from PIL import Image, ImageDraw

files = sorted(glob.glob("b64/*.png"))
cell = 96
cols = 6
rows = (len(files) + cols - 1) // cols
sheet = Image.new("RGB", (cols * cell, rows * (cell + 14)), (250, 250, 252))
d = ImageDraw.Draw(sheet)
for i, f in enumerate(files):
    im = Image.open(f).convert("RGBA")
    bg = Image.new("RGBA", im.size, (255, 255, 255, 255))
    bg.alpha_composite(im)
    im = bg.convert("RGB").resize((80, 80), Image.LANCZOS)
    x = (i % cols) * cell
    y = (i // cols) * (cell + 14)
    sheet.paste(im, (x + 8, y + 4))
    d.text((x + 4, y + 86), os.path.basename(f).split("_")[-1][:10], fill=(40, 40, 40))
sheet.save("contact_hb_icons.png")
print(sheet.size, len(files))
