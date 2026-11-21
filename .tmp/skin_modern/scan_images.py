#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Read-only scanner: carve PNG/JPEG/WebP and asset-related strings from Mach-O dylibs.

Stdlib only. No writes into the scanned files.
Usage: py -3 scan_images.py OUT_JSON FILE [FILE...]
"""
import hashlib
import json
import os
import struct
import sys
import zlib

PNG_SIG = b"\x89PNG\r\n\x1a\n"


def u32(b, o):
    return struct.unpack(">I", b[o:o + 4])[0]


def scan_png(data, path):
    out = []
    i = 0
    n = len(data)
    while True:
        i = data.find(PNG_SIG, i)
        if i < 0:
            break
        pos = i + 8
        chunks = []
        ok = True
        w = h = bitdepth = colortype = None
        idat = []
        while pos + 12 <= n:
            ln = u32(data, pos)
            ctype = data[pos + 4:pos + 8]
            if ln > 64 * 1024 * 1024 or pos + 12 + ln > n:
                ok = False
                break
            body = data[pos + 8:pos + 8 + ln]
            crc_stored = u32(data, pos + 8 + ln)
            crc_calc = zlib.crc32(ctype + body) & 0xFFFFFFFF
            chunks.append(ctype.decode("latin-1"))
            if crc_stored != crc_calc:
                ok = False
                break
            if ctype == b"IHDR":
                w = u32(body, 0)
                h = u32(body, 4)
                bitdepth = body[8]
                colortype = body[9]
            elif ctype == b"IDAT":
                idat.append(body)
            elif ctype == b"IEND":
                end = pos + 12
                blob = data[i:end]
                out.append({
                    "offset": i,
                    "length": len(blob),
                    "width": w,
                    "height": h,
                    "bitdepth": bitdepth,
                    "colortype": colortype,
                    "crc_ok": ok,
                    "chunks": chunks[:12],
                    "sha256": hashlib.sha256(blob).hexdigest(),
                    "idat_bytes": sum(len(x) for x in idat),
                    "_blob": blob,
                })
                i = end
                break
            pos += 12 + ln
        else:
            ok = False
        if not ok:
            i += 1
    return out


def scan_jpeg(data, path):
    out = []
    i = 0
    n = len(data)
    while True:
        i = data.find(b"\xff\xd8\xff", i)
        if i < 0 or i + 4 > n:
            break
        # parse segments, find SOF for dims, walk to EOI
        pos = i + 2
        w = h = None
        ok = False
        while pos + 4 <= n:
            if data[pos] != 0xFF:
                break
            marker = data[pos + 1]
            if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
                pos += 2
                continue
            if marker == 0xD9:
                pos += 2
                ok = True
                break
            seglen = struct.unpack(">H", data[pos + 2:pos + 4])[0]
            if seglen < 2 or pos + 2 + seglen > n:
                break
            if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                h = struct.unpack(">H", data[pos + 5:pos + 7])[0]
                w = struct.unpack(">H", data[pos + 7:pos + 9])[0]
            if marker == 0xDA:
                # scan data: skip to next non-stuffed marker
                p = pos + 2 + seglen
                while p + 1 < n:
                    if data[p] == 0xFF and data[p + 1] not in (0x00, 0xFF) and not (0xD0 <= data[p + 1] <= 0xD7):
                        break
                    p += 1
                pos = p
                continue
            pos += 2 + seglen
        if ok:
            blob = data[i:pos]
            if len(blob) > 256:
                out.append({
                    "offset": i,
                    "length": len(blob),
                    "width": w,
                    "height": h,
                    "crc_ok": True,
                    "sha256": hashlib.sha256(blob).hexdigest(),
                    "idat_bytes": None,
                    "_blob": blob,
                })
            i = pos
        else:
            i += 1
    return out


def scan_webp(data, path):
    out = []
    i = 0
    n = len(data)
    while True:
        i = data.find(b"RIFF", i)
        if i < 0 or i + 12 > n:
            break
        if data[i + 8:i + 12] != b"WEBP":
            i += 4
            continue
        size = struct.unpack("<I", data[i + 4:i + 8])[0]
        end = i + 8 + size
        if end > n:
            i += 4
            continue
        blob = data[i:end]
        fmt = data[i + 12:i + 16]
        w = h = None
        if fmt == b"VP8X":
            w = 1 + int.from_bytes(data[i + 24:i + 27], "little")
            h = 1 + int.from_bytes(data[i + 27:i + 30], "little")
        out.append({
            "offset": i,
            "length": len(blob),
            "width": w,
            "height": h,
            "crc_ok": True,
            "sha256": hashlib.sha256(blob).hexdigest(),
            "idat_bytes": None,
            "_blob": blob,
        })
        i = end
    return out


def interesting_strings(data):
    """Asset-ish tokens: bundle names, @2x/@3x, imageNamed, .car, Assets, skin dirs."""
    import re
    pats = [
        rb"[\x20-\x7e]{4,120}\.bundle",
        rb"[\x20-\x7e]{2,80}@[23]x\.(?:png|jpg|jpeg|webp)",
        rb"[\x20-\x7e]{4,100}Assets\.car",
        rb"imageNamed:[\x20-\x7e]{0,80}",
        rb"[\x20-\x7e]{4,100}\.(?:png|webp|jpg|jpeg)",
        rb"[\x20-\x7e]{4,100}(?:[Bb]ubble|[Bb]alloon|[Ss]kin|[Tt]heme)[\x20-\x7e]{0,40}",
    ]
    hits = {}
    for p in pats:
        for m in re.finditer(p, data):
            s = m.group(0)
            try:
                s = s.decode("utf-8", "replace")
            except Exception:
                continue
            if len(s) < 4:
                continue
            hits[s] = hits.get(s, 0) + 1
    # keep it bounded
    items = sorted(hits.items(), key=lambda kv: -kv[1])[:400]
    return items


def main():
    out_path = sys.argv[1]
    files = sys.argv[2:]
    report = {"files": [], "generated_by": "scan_images.py (stdlib)"}
    carve_dir = os.path.join(os.path.dirname(out_path), "carved")
    os.makedirs(carve_dir, exist_ok=True)
    for path in files:
        with open(path, "rb") as fh:
            data = fh.read()
        rec = {
            "path": os.path.abspath(path),
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "magic": data[:8].hex(),
            "png": [],
            "jpeg": [],
            "webp": [],
            "strings": [],
        }
        for kind, fn in (("png", scan_png), ("jpeg", scan_jpeg), ("webp", scan_webp)):
            for item in fn(data, path):
                blob = item.pop("_blob")
                base = os.path.basename(path).replace(".dylib", "")
                name = "%s_%s_%08x.%s" % (base, kind, item["offset"], kind)
                with open(os.path.join(carve_dir, name), "wb") as w:
                    w.write(blob)
                item["carved_as"] = name
                rec[kind].append(item)
        rec["strings"] = interesting_strings(data)
        report["files"].append(rec)
        print("[scan] %-40s png=%d jpeg=%d webp=%d" % (
            os.path.basename(path), len(rec["png"]), len(rec["jpeg"]), len(rec["webp"])))
    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=1)
    print("[write]", out_path)


if __name__ == "__main__":
    main()
