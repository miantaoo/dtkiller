# -*- coding: utf-8 -*-
"""Look for embedded fonts, icon-font names and remote asset hosts."""
import io
import os
import re
import sys

FONT_SIGS = [("ttf", b"\x00\x01\x00\x00\x00"), ("otto", b"OTTO"), ("true", b"true"), ("ttcf", b"ttcf"),
             ("woff", b"wOFF"), ("woff2", b"wOF2")]
ICON = rb"iconfont|icon_font|[Ii]conFont|FontAwesome|Ionicons|MaterialIcons"
HOST = rb"(?:https?://)?(?:[a-z0-9-]{2,30}\.){1,3}(?:com|cn|net|org|io|xyz|top|vip|cc)(?:/[A-Za-z0-9_./?=&%-]{0,60})?"


def main():
    out = io.open(sys.argv[1], "w", encoding="utf-8")
    for path in sys.argv[2:]:
        data = open(path, "rb").read()
        out.write("=== %s (%d bytes)\n" % (path, len(data)))
        for name, sig in FONT_SIGS:
            n = data.count(sig)
            if n:
                out.write("  font %s x%d\n" % (name, n))
        icons = sorted(set(m.group(0).decode("latin-1") for m in re.finditer(ICON, data)))
        out.write("  iconfont tokens: %s\n" % icons[:12])
        hosts = {}
        for m in re.finditer(HOST, data):
            h = m.group(0).decode("latin-1")
            if len(h) < 8 or h.startswith("com.") or ".apple.com" in h or "gnu.org" in h:
                continue
            hosts[h] = hosts.get(h, 0) + 1
        top = sorted(hosts.items(), key=lambda kv: -kv[1])[:25]
        out.write("  hosts:\n")
        for h, c in top:
            out.write("    %5d  %s\n" % (c, h))
        out.write("\n")
    out.close()
    print("done")


if __name__ == "__main__":
    main()
