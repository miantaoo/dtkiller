#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""DTKiller bubble bundle audit: pure-python PNG decode, no PIL.
Reads only; writes artifacts under .tmp/skin_audit/.
"""
import json, os, struct, zlib, hashlib, sys, zipfile, time

BASE = r"D:\deepseek harness\wechat\out\dt"
BUNDLE = os.path.join(BASE, "assets", "DTKillerBubbles.bundle")
OUTDIR = os.path.join(BASE, ".tmp", "skin_audit")
os.makedirs(OUTDIR, exist_ok=True)

# ---------------------------------------------------------------- PNG decode
def parse_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("bad signature")
    pos, chunks, idat = 8, [], b""
    ihdr = None
    while pos + 8 <= len(data):
        ln = struct.unpack(">I", data[pos:pos + 4])[0]
        typ = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + ln]
        crc_ok = (zlib.crc32(typ + payload) & 0xffffffff) == \
                 struct.unpack(">I", data[pos + 8 + ln:pos + 12 + ln])[0]
        chunks.append((typ.decode("latin1"), ln, crc_ok))
        if typ == b"IHDR":
            w, h, bd, ct, comp, filt, inter = struct.unpack(">IIBBBBB", payload)
            ihdr = dict(w=w, h=h, bitdepth=bd, colortype=ct,
                        compression=comp, filter=filt, interlace=inter)
        elif typ == b"IDAT":
            idat += payload
        pos += 12 + ln
        if typ == b"IEND":
            break
    return dict(data=data, chunks=chunks, ihdr=ihdr, idat=idat)


def unfilter(raw, w, h, bpp, stride):
    out, prev, p = bytearray(), bytearray(stride), 0
    for _ in range(h):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if f == 0:
            pass
        elif f == 1:
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 255
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        else:
            raise ValueError("filter %d" % f)
        out += line
        prev = line
    return out


def decode(path):
    p = parse_png(path)
    ih = p["ihdr"]
    assert ih["bitdepth"] == 8 and ih["interlace"] == 0, ih
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ih["colortype"]]
    w, h = ih["w"], ih["h"]
    stride = w * ch
    raw = zlib.decompress(p["idat"])
    assert len(raw) == (stride + 1) * h, (len(raw), (stride + 1) * h)
    px = unfilter(raw, w, h, ch, stride)
    return dict(p=p, ihdr=ih, ch=ch, w=w, h=h, px=px)


def alpha_at(img, x, y):
    ch, px, w = img["ch"], img["px"], img["w"]
    if ch != 4:
        return 255
    return px[(y * w + x) * ch + 3]


def rgb_at(img, x, y):
    ch, px, w = img["ch"], img["px"], img["w"]
    o = (y * w + x) * ch
    return px[o], px[o + 1], px[o + 2], (px[o + 3] if ch == 4 else 255)


def bbox_alpha(img, thr=8):
    a = img
    w, h, ch, px = a["w"], a["h"], a["ch"], a["px"]
    if ch != 4:
        return 0, 0, w - 1, h - 1
    minx, miny, maxx, maxy = w, h, -1, -1
    for y in range(h):
        row = y * w * ch
        for x in range(w):
            if px[row + x * ch + 3] > thr:
                if x < minx: minx = x
                if x > maxx: maxx = x
                if y < miny: miny = y
                if y > maxy: maxy = y
    return minx, miny, maxx, maxy


def lum(rgb):
    def c(v):
        v /= 255.0
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = rgb
    return 0.2126 * c(r) + 0.7152 * c(g) + 0.0722 * c(b)


def contrast(a, b):
    la, lb = lum(a), lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


# ------------------------------------------------------------- contact sheet
def new_rgba(w, h, color):
    return bytearray(bytes(color) * (w * h)), w, h


def blit(dst, dw, dh, src_img, ox, oy, bg=None):
    """alpha-composite src_img (RGBA8 decoded) onto dst at ox,oy."""
    sw, sh, sch, spx = src_img["w"], src_img["h"], src_img["ch"], src_img["px"]
    for y in range(sh):
        ty = oy + y
        if not (0 <= ty < dh):
            continue
        for x in range(sw):
            tx = ox + x
            if not (0 <= tx < dw):
                continue
            o = (y * sw + x) * sch
            r, g, b = spx[o], spx[o + 1], spx[o + 2]
            a = spx[o + 3] if sch == 4 else 255
            d = (ty * dw + tx) * 4
            if a == 255:
                dst[d:d + 4] = bytes((r, g, b, 255))
            elif a == 0:
                continue
            else:
                af = a / 255.0
                for i, v in enumerate((r, g, b)):
                    dst[d + i] = int(v * af + dst[d + i] * (1 - af)) & 255


def save_png(path, buf, w, h):
    raw = bytearray()
    stride = w * 4
    for y in range(h):
        raw.append(0)
        raw += buf[y * stride:(y + 1) * stride]
    def chunk(t, d):
        return (struct.pack(">I", len(d)) + t + d +
                struct.pack(">I", zlib.crc32(t + d) & 0xffffffff))
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    out = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) +
           chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))
    open(path, "wb").write(out)


def stretch9(img, target_w, target_h, insets_pt, scale):
    """Nearest-neighbour 9-slice simulation, mirrors UIKit stretch semantics."""
    t, l, b, r = [int(round(v * scale)) for v in insets_pt]
    sw, sh, sch, spx = img["w"], img["h"], img["ch"], img["px"]
    l = min(l, sw // 2); r = min(r, sw // 2)
    t = min(t, sh // 2); b = min(b, sh // 2)
    mid_src_w = sw - l - r
    mid_src_h = sh - t - b
    mid_dst_w = target_w - l - r
    mid_dst_h = target_h - t - b
    out = bytearray(target_w * target_h * 4)
    for y in range(target_h):
        if y < t:
            sy = y
        elif y >= target_h - b:
            sy = sh - (target_h - y)
        else:
            sy = t + int((y - t) * mid_src_h / max(1, mid_dst_h))
        sy = max(0, min(sh - 1, sy))
        for x in range(target_w):
            if x < l:
                sx = x
            elif x >= target_w - r:
                sx = sw - (target_w - x)
            else:
                sx = l + int((x - l) * mid_src_w / max(1, mid_dst_w))
            sx = max(0, min(sw - 1, sx))
            so = (sy * sw + sx) * sch
            do = (y * target_w + x) * 4
            a = spx[so + 3] if sch == 4 else 255
            out[do:do + 3] = bytes((spx[so], spx[so + 1], spx[so + 2]))
            out[do + 3] = a
    return dict(w=target_w, h=target_h, ch=4, px=out)


# --------------------------------------------------------------------- audit
def main():
    t0 = time.time()
    manifest = json.load(open(os.path.join(BUNDLE, "manifest.json"), encoding="utf-8"))
    base_w, base_h = manifest["baseSize"]
    report = {"manifest": {}, "files": {}, "checks": [], "legacy": {}}

    def add(level, code, msg):
        report["checks"].append({"level": level, "code": code, "msg": msg})

    referenced = {}
    for skin, sk in manifest["skins"].items():
        for side, var in sk["variants"].items():
            ins = var["capInsets"]
            report["manifest"]["%s/%s" % (skin, side)] = {
                "capInsets": ins,
                "sum_x": ins[1] + ins[3], "sum_y": ins[0] + ins[2],
                "resizingMode": var.get("resizingMode"),
            }
            if ins[1] + ins[3] >= base_w:
                add("FAIL", "caps-x", "%s/%s left+right=%d >= canvas %d" % (skin, side, ins[1] + ins[3], base_w))
            if ins[0] + ins[2] >= base_h:
                add("FAIL", "caps-y", "%s/%s top+bottom=%d >= canvas %d" % (skin, side, ins[0] + ins[2], base_h))
            for app, m in var["images"].items():
                for k, fn in m.items():
                    key = (skin, fn)
                    if key in referenced:
                        add("FAIL", "dup-ref", "%s/%s also referenced by %s" % (skin, fn, referenced[key]))
                    referenced[key] = "%s/%s/%s/%s" % (skin, side, app, k)

    # existence / dangling
    on_disk = set()
    for root, _, files in os.walk(BUNDLE):
        for f in files:
            rel = os.path.relpath(os.path.join(root, f), BUNDLE).replace("\\", "/")
            on_disk.add(rel)
    pngs = sorted(p for p in on_disk if p.lower().endswith(".png"))
    ref_full = set()
    for (skin, ref), where in sorted(referenced.items()):
        full = "%s/%s" % (skin, ref)
        ref_full.add(full)
        if full not in on_disk:
            add("FAIL", "missing-ref", "%s -> %s" % (where, full))
    orphans = [p for p in pngs if p not in ref_full]
    for o in orphans:
        add("WARN", "orphan", "%s (not referenced by manifest)" % o)

    # per-file pixel facts
    for rel in pngs:
        img = decode(os.path.join(BUNDLE, rel.replace("/", os.sep)))
        ih = img["ihdr"]
        try:
            scale = int(rel.split("@")[1][0]) if "@" in rel else 1
        except Exception:
            scale = 1
        minx, miny, maxx, maxy = bbox_alpha(img)
        h = hashlib.sha256(img["p"]["data"]).hexdigest()
        # sample body center (25% width, 50% height) + border pixel
        cx, cy = max(1, int(img["w"] * 0.25)), img["h"] // 2
        body = rgb_at(img, cx, cy)
        chans = {}
        for t, ln, ok in img["p"]["chunks"]:
            chans[t] = chans.get(t, 0) + 1
        crc_bad = [t for t, ln, ok in img["p"]["chunks"] if not ok]
        report["files"][rel] = {
            "bytes": len(img["p"]["data"]), "w": img["w"], "h": img["h"],
            "iz": ih, "scale_from_name": scale,
            "dim_ok": (img["w"], img["h"]) == (base_w * scale, base_h * scale),
            "alpha": ih["colortype"] in (4, 6),
            "bbox": [minx, miny, maxx, maxy],
            "bbox_edges": [minx, miny, img["w"] - 1 - maxx, img["h"] - 1 - maxy],
            "corner_alpha": [alpha_at(img, 0, 0), alpha_at(img, img["w"] - 1, 0),
                             alpha_at(img, 0, img["h"] - 1), alpha_at(img, img["w"] - 1, img["h"] - 1)],
            "body_rgb": body[:3],
            "chunks": chans, "crc_bad": crc_bad,
            "sha256": h,
            "contrast_vs_white": round(contrast(body[:3], (255, 255, 255)), 2),
            "contrast_vs_black": round(contrast(body[:3], (0, 0, 0)), 2),
        }
        if not report["files"][rel]["dim_ok"]:
            add("FAIL", "dims", "%s is %dx%d, expected %dx%d" %
                (rel, img["w"], img["h"], base_w * scale, base_h * scale))
        if not report["files"][rel]["alpha"]:
            add("FAIL", "alpha", "%s has no alpha channel (colortype %d)" % (rel, ih["colortype"]))
        if crc_bad:
            add("FAIL", "crc", "%s bad CRC in %s" % (rel, crc_bad))
        for t in ("tEXt", "iTXt", "zTXt", "eXIf"):
            if t in chans:
                add("WARN", "metadata", "%s contains %s chunk" % (rel, t))

    # legacy normal == self/light ?
    for skin in manifest["skins"]:
        for sc in ("", "@2x", "@3x"):
            a = "%s/normal%s.png" % (skin, sc)
            b = "%s/bubble_self_light%s.png" % (skin, sc)
            report["legacy"]["%s%s" % (skin, sc)] = (
                report["files"].get(a, {}).get("sha256") == report["files"].get(b, {}).get("sha256"))
        leg = manifest["skins"][skin].get("legacy", {})
        report["legacy"][skin + "/manifest-keys"] = list(leg.get("normal", {}).keys())

    # geometry: tail vs vertical stretch band, per side, at 1x/2x/3x
    geo = {}
    for skin in manifest["skins"]:
        for side in ("self", "other"):
            ins = manifest["skins"][skin]["variants"][side]["capInsets"]
            t, l, b, r = ins
            band = (t, base_h - b)
            img = decode(os.path.join(BUNDLE, skin, "bubble_%s_light@2x.png" % side))
            W, H = img["w"], img["h"]
            body_px = int(70 * 2)          # generator: BODY_W=70pt
            # columns strictly outside the body rectangle carry only the tail
            tail_cols = list(range(body_px + 1, W)) if side == "self" else list(range(0, W - body_px - 1))
            ys = [y for y in range(H) if any(alpha_at(img, x, y) > 8 for x in tail_cols)]
            tail_pt = (min(ys) / 2.0, max(ys) / 2.0) if ys else None
            overlap = 0.0
            if tail_pt:
                lo = max(band[0], tail_pt[0]); hi = min(band[1], tail_pt[1])
                overlap = max(0.0, hi - lo)
            # tip flatness: outermost column on the tail side
            tipx = W - 1 if side == "self" else 0
            tip_hits = [y for y in range(H) if alpha_at(img, tipx, y) > 0]
            geo["%s/%s" % (skin, side)] = {
                "band_pt": band, "tail_y_pt": tail_pt,
                "tail_in_band_pt": round(overlap, 2),
                "tip_rows_alpha_gt0": len(tip_hits),
                "tip_rows_alpha_gt200": len([y for y in tip_hits if alpha_at(img, tipx, y) > 200]),
                "tail_thickness_pt": (round(tail_pt[1] - tail_pt[0], 2) if tail_pt else None),
                "vstretch_factor_100pt": round((100.0 - (t + b)) / (base_h - (t + b)), 2),
                "tail_h_at_100pt": (round((tail_pt[1] - tail_pt[0]) *
                                          (100.0 - (t + b)) / (base_h - (t + b)), 1) if tail_pt else None),
            }
    report["geometry"] = geo

    # ---- contact sheet from the SHIPPED 2x files
    cell_w, cell_h, pad = base_w * 2, base_h * 2, 12
    rows = [
        ("light", (245, 245, 245, 255), ["wx8/self/light", "wx8/other/light", "qq9/self/light", "qq9/other/light"]),
        ("dark", (17, 17, 19, 255), ["wx8/self/dark", "wx8/other/dark", "qq9/self/dark", "qq9/other/dark"]),
        ("highlight", (245, 245, 245, 255), ["wx8/self/highlight", "qq9/self/highlight", None, None]),
        ("highlight_dark", (17, 17, 19, 255), ["wx8/self/highlight_dark", "qq9/self/highlight_dark", None, None]),
    ]
    SW = 4 * (cell_w + pad) + pad
    SH = 4 * (cell_h + pad) + pad
    buf, _, _ = new_rgba(SW, SH, (255, 0, 255, 255))
    for ri, (name, bg, items) in enumerate(rows):
        # paint row background
        for y in range(ri * (cell_h + pad) + pad, (ri * (cell_h + pad) + pad) + cell_h):
            for x in range(pad, SW - pad):
                o = (y * SW + x) * 4
                buf[o:o + 4] = bytes(bg)
        for ci, key in enumerate(items):
            if not key:
                continue
            skin, side, app = key.split("/")
            img = decode(os.path.join(BUNDLE, skin, "bubble_%s_%s@2x.png" % (side, app)))
            blit(buf, SW, SH, img, pad + ci * (cell_w + pad), ri * (cell_h + pad) + pad)
    sheet1 = os.path.join(OUTDIR, "contact_shipped_2x.png")
    save_png(sheet1, buf, SW, SH)

    # ---- stretch simulation (9-slice to 220x140 pt @2x) for wx8/self and qq9/self
    tw, th = 220 * 2, 140 * 2
    sim_items = []
    for skin in ("wx8", "qq9"):
        for side in ("self", "other"):
            ins = manifest["skins"][skin]["variants"][side]["capInsets"]
            img = decode(os.path.join(BUNDLE, skin, "bubble_%s_light@2x.png" % side))
            sim_items.append((skin, side, img, ins))
    CW, CH = tw + 24, th + 24
    SW2, SH2 = 2 * CW, 2 * CH
    buf2, _, _ = new_rgba(SW2, SH2, (235, 235, 235, 255))
    for i, (skin, side, img, ins) in enumerate(sim_items):
        st = stretch9(img, tw, th, ins, 2)
        blit(buf2, SW2, SH2, st, (i % 2) * CW + 12, (i // 2) * CH + 12)
    sheet2 = os.path.join(OUTDIR, "stretch_sim_220x140pt_2x.png")
    save_png(sheet2, buf2, SW2, SH2)
    report["artifacts"] = {"contact": sheet1, "stretch": sheet2}

    # ---- zip audit
    zp = os.path.join(BASE, "assets", "DTKillerBubbles-1.0.0.zip")
    zi = []
    with zipfile.ZipFile(zp) as z:
        for info in z.infolist():
            nm = info.filename
            h = hashlib.sha256(z.read(nm)).hexdigest()
            disk = rel_disk = None
            if nm.startswith("DTKillerBubbles.bundle/"):
                rel_disk = nm[len("DTKillerBubbles.bundle/"):]
                dpath = os.path.join(BUNDLE, rel_disk.replace("/", os.sep))
                if os.path.exists(dpath):
                    disk = hashlib.sha256(open(dpath, "rb").read()).hexdigest()
            zi.append({"name": nm, "bytes": info.file_size,
                       "match_disk": (h == disk) if disk else None})
    report["zip"] = {
        "entries": len(zi),
        "has_preview": any("preview" in e["name"] for e in zi),
        "has_reference": any("reference/" in e["name"] for e in zi),
        "stale": [e["name"] for e in zi if e["match_disk"] is False],
        "missing_from_zip": sorted(set(on_disk) - {e["name"][len("DTKillerBubbles.bundle/"):] for e in zi if e["match_disk"] is not None}),
        "list": zi,
    }
    if report["zip"]["stale"]:
        add("WARN", "zip-stale", "%d zip entries differ from files on disk" % len(report["zip"]["stale"]))
    if report["zip"]["missing_from_zip"]:
        add("WARN", "zip-missing", "on disk but not in zip: %s" % report["zip"]["missing_from_zip"])

    # bundle size
    total = sum(os.path.getsize(os.path.join(BUNDLE, p.replace('/', os.sep))) for p in on_disk)
    report["totals"] = {"png_count": len(pngs), "bundle_files": len(on_disk), "bundle_bytes": total,
                        "png_bytes": sum(report["files"][p]["bytes"] for p in pngs)}

    json.dump(report, open(os.path.join(OUTDIR, "audit.json"), "w", encoding="utf-8"),
              indent=1, ensure_ascii=False)

    # ------------------------------------------------------------- console
    print("elapsed %.1fs" % (time.time() - t0))
    print("png=%d files=%d bundle_bytes=%d" % (len(pngs), len(on_disk), total))
    print("dims/alpha summary:")
    bad = [p for p in pngs if not report["files"][p]["dim_ok"] or not report["files"][p]["alpha"]]
    print("  nonconforming:", bad if bad else "none")
    print("alpha bbox edges (l,t,r,b px, 1x=76x56):")
    for p in pngs:
        f = report["files"][p]
        if p.endswith(("_light.png", "_dark.png")) or "normal" in p:
            print("  %-42s %dx%d edges=%s corners=%s body=%s cW=%.2f cB=%.2f" % (
                p, f["w"], f["h"], f["bbox_edges"], f["corner_alpha"], f["body_rgb"],
                f["contrast_vs_white"], f["contrast_vs_black"]))
    print("geometry:")
    for k, v in geo.items():
        print("  %-12s band=%s tail_y=%s overlap=%s tip_rows=%s/%s thick=%s" % (
            k, v["band_pt"], v["tail_y_pt"], v["tail_in_band_pt"],
            v["tip_rows_alpha_gt200"], v["tip_rows_alpha_gt0"], v["tail_thickness_pt"]))
    print("legacy normal==self_light:", {k: v for k, v in report["legacy"].items() if not k.endswith("keys")})
    print("orphans:", orphans)
    print("checks:")
    for c in report["checks"]:
        print("  [%s] %s: %s" % (c["level"], c["code"], c["msg"]))
    print("zip:", {k: v for k, v in report["zip"].items() if k != "list"})
    print("artifacts:", report["artifacts"])


if __name__ == "__main__":
    main()
