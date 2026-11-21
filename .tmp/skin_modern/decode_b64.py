# -*- coding: utf-8 -*-
"""Decode base64 image literals embedded in a Mach-O dylib (read-only)."""
import base64
import binascii
import hashlib
import io
import json
import os
import re
import struct
import sys

PAT = re.compile(rb"[A-Za-z0-9+/=]{80,}")
HEAD = {b"iVBORw0KGgo": "png", b"/9j/": "jpeg", b"R0lGOD": "gif", b"UklGR": "webp"}


def png_size(blob):
    if len(blob) > 24 and blob[:8] == b"\x89PNG\r\n\x1a\n":
        w, h = struct.unpack(">II", blob[16:24])
        return w, h
    return None, None


def main():
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    results = []
    for path in sys.argv[2:]:
        data = open(path, "rb").read()
        base = os.path.basename(path).replace(".dylib", "")
        for m in PAT.finditer(data):
            s = m.group(0)
            if not any(k in s[:16] for k in HEAD):
                continue
            try:
                blob = base64.b64decode(s + b"=" * (-len(s) % 4), validate=False)
            except (binascii.Error, ValueError):
                continue
            kind = None
            if blob[:8] == b"\x89PNG\r\n\x1a\n":
                kind = "png"
            elif blob[:3] == b"\xff\xd8\xff":
                kind = "jpeg"
            elif blob[:6] in (b"GIF89a", b"GIF87a"):
                kind = "gif"
            elif blob[:4] == b"RIFF" and blob[8:12] == b"WEBP":
                kind = "webp"
            if not kind:
                continue
            w, h = png_size(blob)
            name = "%s_b64_%08x.%s" % (base, m.start(), kind)
            with open(os.path.join(outdir, name), "wb") as fh:
                fh.write(blob)
            results.append({
                "dylib": path,
                "offset": m.start(),
                "b64_len": len(s),
                "bytes": len(blob),
                "kind": kind,
                "width": w,
                "height": h,
                "sha256": hashlib.sha256(blob).hexdigest(),
                "file": name,
                "head_ascii": s[:24].decode("latin-1"),
            })
            print("%-28s %08x %-5s %sx%s %6dB -> %s" % (base, m.start(), kind, w, h, len(blob), name))
    with io.open(os.path.join(outdir, "b64_images.json"), "w", encoding="utf-8") as fh:
        json.dump(results, fh, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
