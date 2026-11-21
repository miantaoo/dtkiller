# -*- coding: utf-8 -*-
"""Broader embedded-media reconnaissance across dylibs (stdlib only, read-only)."""
import base64
import hashlib
import io
import json
import os
import re
import struct
import sys

SIGS = [
    ("png", b"\x89PNG\r\n\x1a\n"),
    ("jpeg", b"\xff\xd8\xff"),
    ("gif89", b"GIF89a"),
    ("gif87", b"GIF87a"),
    ("webp", b"WEBP"),
    ("bmp", b"BM"),
    ("tiff_le", b"II*\x00"),
    ("tiff_be", b"MM\x00*"),
    ("heic", b"ftypheic"),
    ("heif", b"ftypheif"),
    ("avif", b"ftypavif"),
    ("pdf", b"%PDF-"),
    ("car_magic", b"BOMStore"),
    ("bplist", b"bplist00"),
    ("zip", b"PK\x03\x04"),
    ("gzip", b"\x1f\x8b\x08"),
    ("b64_png", b"iVBORw0KGgo"),
    ("b64_jpeg", b"/9j/4AAQ"),
    ("data_uri", b"data:image/"),
    ("asset_catalog", b"Assets.car"),
    ("png_name", b".png"),
    ("imageset", b".imageset"),
]

PATHS = [
    rb"[\x20-\x7e]{3,90}\.png",
    rb"[\x20-\x7e]{3,90}\.jpg",
    rb"[\x20-\x7e]{3,90}\.jpeg",
    rb"[\x20-\x7e]{3,90}\.webp",
    rb"[\x20-\x7e]{3,90}\.gif",
    rb"[\x20-\x7e]{3,90}\.bundle",
    rb"[\x20-\x7e]{3,90}\.car",
    rb"[\x20-\x7e]{3,90}\.(?:bundle|framework)/[A-Za-z0-9_@./-]{1,60}",
    rb"[A-Za-z0-9_@-]{2,60}@[23]x",
]

URL = rb"https?://[A-Za-z0-9._~:/?#@!$&'()*+,;=%\-]{6,140}"
SKIN = rb"[\x20-\x7e]{0,30}(?:[Bb]ubble|[Bb]alloon|[Tt]heme|[Ss]kin)[\x20-\x7e]{0,40}"


def main():
    outdir = os.path.dirname(os.path.abspath(sys.argv[1]))
    report = {}
    for path in sys.argv[2:]:
        data = open(path, "rb").read()
        rec = {
            "path": os.path.abspath(path),
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "sigs": {},
            "names": {},
            "urls": [],
            "skin_like": [],
        }
        for name, sig in SIGS:
            offs = [m.start() for m in re.finditer(re.escape(sig), data)]
            if offs:
                rec["sigs"][name] = {"count": len(offs), "first": [hex(o) for o in offs[:6]]}
        for pat in PATHS:
            for m in re.finditer(pat, data):
                s = m.group(0).decode("utf-8", "replace")
                rec["names"][s] = rec["names"].get(s, 0) + 1
        for m in re.finditer(URL, data):
            u = m.group(0).decode("utf-8", "replace")
            if u not in rec["urls"]:
                rec["urls"].append(u)
        for m in re.finditer(SKIN, data):
            s = m.group(0).decode("utf-8", "replace").strip()
            if len(s) > 4:
                rec["skin_like"].append(s)
        rec["urls"] = rec["urls"][:120]
        rec["skin_like"] = sorted(set(rec["skin_like"]))[:120]
        rec["names"] = dict(sorted(rec["names"].items(), key=lambda kv: -kv[1])[:200])
        report[os.path.basename(path)] = rec
        print("%-34s sigs=%s names=%d urls=%d" % (
            os.path.basename(path),
            ",".join("%s:%d" % (k, v["count"]) for k, v in rec["sigs"].items()),
            len(rec["names"]), len(rec["urls"])))
    with io.open(os.path.abspath(sys.argv[1]), "w", encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
