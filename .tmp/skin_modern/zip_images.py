# -*- coding: utf-8 -*-
"""List image-ish entries inside workspace zips (read-only)."""
import io
import os
import sys
import zipfile

EXT = (".png", ".jpg", ".jpeg", ".webp", ".gif", ".pdf", ".car", ".ttf", ".otf", ".bundle")


def main():
    for path in sys.argv[1:]:
        try:
            z = zipfile.ZipFile(path)
        except Exception as exc:
            print("!! %s: %s" % (path, exc))
            continue
        names = z.namelist()
        imgs = [n for n in names if n.lower().endswith(EXT)]
        print("== %-46s entries=%-5d images=%d" % (os.path.basename(path), len(names), len(imgs)))
        for n in imgs[:12]:
            info = z.getinfo(n)
            print("     %7d  %s" % (info.file_size, n))
        if len(imgs) > 12:
            print("     ... +%d" % (len(imgs) - 12))


if __name__ == "__main__":
    main()
