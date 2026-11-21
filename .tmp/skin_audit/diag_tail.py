#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import audit_bubbles as A

B = A.BUNDLE
for rel in ("wx8/bubble_self_light@2x.png", "qq9/bubble_self_light@2x.png"):
    img = A.decode(os.path.join(B, rel.replace("/", os.sep)))
    W, H = img["w"], img["h"]
    print("==", rel, W, H)
    for x in (134, 136, 138, 139, 140, 141, 144, 148, 150, 151):
        ys = [y for y in range(H) if A.alpha_at(img, x, y) > 8]
        if ys:
            print("  x=%d  y=%d..%d pt=%.1f..%.1f n=%d" % (x, ys[0], ys[-1], ys[0]/2.0, ys[-1]/2.0, len(ys)))
        else:
            print("  x=%d  empty" % x)
    # body-only check: column 120
    ys = [y for y in range(H) if A.alpha_at(img, 120, y) > 8]
    print("  x=120 body y=%d..%d" % (ys[0], ys[-1]))
    # row scan at mid
    xs = [x for x in range(W) if A.alpha_at(img, x, H//2) > 8]
    print("  row mid x=%d..%d" % (xs[0], xs[-1]))
