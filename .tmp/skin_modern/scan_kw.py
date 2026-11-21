# -*- coding: utf-8 -*-
"""Keyword scan over a UTF-8 strings dump; keywords come from a UTF-8 file."""
import io
import sys

dump = sys.argv[1]
kwfile = sys.argv[2]
kws = [l.strip() for l in io.open(kwfile, encoding="utf-8") if l.strip()]
lines = io.open(dump, encoding="utf-8", errors="replace").read().splitlines()
out = io.open(sys.argv[3], "w", encoding="utf-8")
for k in kws:
    hits = [l for l in lines if k in l]
    out.write("## %s : %d\n" % (k, len(hits)))
    for l in hits[:25]:
        out.write("    %s\n" % l[:220])
    out.write("\n")
out.close()
print("done")
