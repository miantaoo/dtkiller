#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import audit_bubbles as A
B = A.BUNDLE

def prof(rel):
    img = A.decode(os.path.join(B, rel.replace("/", os.sep)))
    W, H = img["w"], img["h"]
    cols = []
    for x in range(W):
        cols.append(max(A.alpha_at(img, x, y) for y in range(H)))
    nz = [x for x in range(W) if cols[x] > 0]
    nz8 = [x for x in range(W) if cols[x] > 8]
    print("%-38s W=%d  alpha>0 x:%d..%d   alpha>8 x:%d..%d" % (rel, W, nz[0], nz[-1], nz8[0], nz8[-1]))
    print("   right cols 138..%d maxalpha=%s" % (W - 1, [cols[x] for x in range(138, W)]))
    print("   left  cols 0..13    maxalpha=%s" % [cols[x] for x in range(0, 14)])

for r in ("wx8/bubble_self_light@2x.png", "wx8/bubble_other_light@2x.png",
          "qq9/bubble_self_light@2x.png", "qq9/bubble_other_light@2x.png"):
    prof(r)

# mirror symmetry test on the alpha channel
import hashlib
def amap(rel):
    img = A.decode(os.path.join(B, rel.replace("/", os.sep)))
    W, H = img["w"], img["h"]
    return bytearray(img["px"][i] for i in range(3, len(img["px"]), 4)), W, H

for skin in ("wx8", "qq9"):
    a, W, H = amap("%s/bubble_self_light@2x.png" % skin)
    b, _, _ = amap("%s/bubble_other_light@2x.png" % skin)
    diff = 0
    maxd = 0
    for y in range(H):
        for x in range(W):
            d = abs(a[y * W + x] - b[y * W + (W - 1 - x)])
            if d > 8:
                diff += 1
            maxd = max(maxd, d)
    print("%s mirror mismatch pixels(>8)=%d maxdiff=%d" % (skin, diff, maxd))
