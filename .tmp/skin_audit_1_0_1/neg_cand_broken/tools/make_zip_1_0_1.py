#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 assets/review-1.0.1/DTKillerBubbles.bundle 打包成 DTKillerBubbles-1.0.1.zip。

只包含 candidate bundle 内的文件（README.md / LICENSE.txt 位于 bundle 根），
不写目录项、不写 __MACOSX、时间戳固定，便于重复构建得到相同字节。
"""

import os
import zipfile

CAND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUNDLE = os.path.join(CAND, "DTKillerBubbles.bundle")
ZIP = os.path.join(CAND, "DTKillerBubbles-1.0.1.zip")
STAMP = (2026, 11, 21, 2, 30, 0)


def main():
    entries = []
    for root, _, files in os.walk(BUNDLE):
        for f in files:
            p = os.path.join(root, f)
            rel = os.path.relpath(p, CAND).replace("\\", "/")
            entries.append((rel, p))
    entries.sort()
    if os.path.exists(ZIP):
        os.remove(ZIP)
    with zipfile.ZipFile(ZIP, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for rel, p in entries:
            info = zipfile.ZipInfo(rel, date_time=STAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            with open(p, "rb") as f:
                zf.writestr(info, f.read())
    print("zip:", ZIP, os.path.getsize(ZIP), "bytes,", len(entries), "entries")


if __name__ == "__main__":
    main()
