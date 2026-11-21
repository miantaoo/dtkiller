# -*- coding: utf-8 -*-
"""Measure design tokens from WCPure's embedded preview thumbnails."""
import glob
import json
import os
from collections import Counter

from PIL import Image

files = sorted(set(glob.glob("carved/WCPureExtension_png_*.png")))
seen = {}
for f in files:
    im = Image.open(f).convert("RGBA")
    key = im.tobytes()
    if key in seen:
        continue
    seen[key] = f

out = []
for f in seen.values():
    im = Image.open(f).convert("RGBA")
    w, h = im.size
    px = im.load()
    colors = Counter()
    opaque = 0
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a > 200:
                opaque += 1
                colors[(r, g, b)] += 1
    top = colors.most_common(6)
    # horizontal scan through vertical centre: runs of "ink" (alpha>128)
    ymid = h // 2
    runs = []
    cur = None
    for x in range(w):
        a = px[x, ymid][3]
        if a > 128 and cur is None:
            cur = x
        elif a <= 128 and cur is not None:
            runs.append((cur, x - 1))
            cur = None
    if cur is not None:
        runs.append((cur, w - 1))
    # leftmost/rightmost opaque columns
    cols = [x for x in range(w) if any(px[x, y][3] > 128 for y in range(h))]
    rows = [y for y in range(h) if any(px[x, y][3] > 128 for x in range(w))]
    out.append({
        "file": f,
        "size": [w, h],
        "opaque_px": opaque,
        "top_colors": [("#%02X%02X%02X" % c, n) for c, n in top],
        "row_runs_ymid": runs[:8],
        "bbox": [min(cols), min(rows), max(cols), max(rows)] if cols else None,
    })

json.dump(out, open("measure.json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
for o in out:
    print(o["file"], o["size"], o["bbox"])
    for c, n in o["top_colors"][:4]:
        print("    ", c, n)
    print("    runs", o["row_runs_ymid"][:6])
