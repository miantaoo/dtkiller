# -*- coding: utf-8 -*-
import io
import re
import sys

path = sys.argv[1]
kw = sys.argv[2:]
text = io.open(path, encoding="utf-8", errors="replace").read()
lines = text.splitlines()
for k in kw:
    hits = [l for l in lines if k in l]
    print("## %s : %d" % (k, len(hits)))
    for l in hits[:40]:
        print("   ", l[:200])
