# -*- coding: utf-8 -*-
"""Probe zip/gzip candidates inside dylibs: try to read their central directory / decompress."""
import io
import os
import struct
import sys
import zipfile
import zlib


def probe_zip(path, off):
    data = open(path, "rb").read()
    print("-- zip candidate at %#x in %s" % (off, os.path.basename(path)))
    # find EOCD in the next 4MB
    end = min(len(data), off + 8 * 1024 * 1024)
    eocd = data.rfind(b"PK\x05\x06", off, end)
    print("   EOCD:", hex(eocd) if eocd > 0 else None)
    if eocd > 0:
        n, = struct.unpack("<H", data[eocd + 10:eocd + 12])
        print("   entries:", n)
    head = data[off:off + 80]
    print("   head:", head[:40])
    try:
        bio = io.BytesIO(data[off:])
        z = zipfile.ZipFile(bio)
        names = z.namelist()[:20]
        print("   zipfile OK entries:", len(z.namelist()), names)
    except Exception as exc:
        print("   zipfile failed:", exc)


def probe_gzip(path, off):
    data = open(path, "rb").read()
    print("-- gzip candidate at %#x in %s" % (off, os.path.basename(path)))
    print("   head:", data[off:off + 24].hex())
    try:
        d = zlib.decompressobj(16 + zlib.MAX_WBITS)
        out = d.decompress(data[off:off + 2 * 1024 * 1024])
        print("   inflated:", len(out), "eof:", d.eof, "head:", out[:60])
    except Exception as exc:
        print("   gzip failed:", exc)


if __name__ == "__main__":
    for arg in sys.argv[1:]:
        if ":" in arg:
            p, kind, off = arg.split(":")
            if kind == "zip":
                probe_zip(p, int(off, 16))
            else:
                probe_gzip(p, int(off, 16))
