#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DTKillerBubbles 1.0.1 候选包审计 —— **仅用 Python 标准库**（无 numpy / 无 PIL）。

自带 PNG 解码（签名 + 逐 chunk CRC + zlib + 5 种行过滤器）与逐像素几何判定，
因此本脚本在任何自带 Python 3.8+ 的环境里都能直接跑：

    python assets/review-1.0.1/tools/audit_bubbles_1_0_1.py

只读检查，不修改任何文件。检查项：

 1. manifest 结构 / 版本 / 无 legacy alias
 2. manifest 每个引用存在；bundle 内 PNG 恰好 48 张且全部被引用
 3. PNG 签名、每 chunk CRC、IHDR(8bit RGBA/非隔行)、IDAT zlib 解压、行过滤器
 4. 尺寸 = baseSize × 倍率
 5. 尾巴区域含 alpha；尾巴整体落在固定 cap；不进入横/纵拉伸带
 6. 尾尖不裁（右/左留透明列）且收尖
 7. other 的 alpha 与 self 逐位镜像一致
 8. textColor 契约：light/highlight 深字、dark/highlight_dark 浅字、实测对比度 >= 4.5
 9. zip 仅含 candidate bundle（+README/LICENSE），逐项 sha256 与磁盘一致
10. 旧 1.0.0 包只读复现（other 无尾、尾巴进拉伸带、尾尖贴边），作为对照证据

注：生成器 tools/gen_bubble_assets_1_0_1.py 需要 Pillow + numpy（离线出图用），
    但本审计脚本与它们无关，删掉 Pillow/numpy 也能跑。
"""

import hashlib
import json
import os
import struct
import sys
import zipfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
# 默认审计 assets/review-1.0.1；DT_AUDIT_CAND 可指向副本做负向自测（不改变默认行为）
CAND = os.environ.get("DT_AUDIT_CAND") or os.path.dirname(HERE)   # assets/review-1.0.1
ROOT = os.path.dirname(os.path.dirname(CAND))      # out/dt
BUNDLE = os.path.join(CAND, "DTKillerBubbles.bundle")
ZIP = os.path.join(CAND, "DTKillerBubbles-1.0.1.zip")
OLD = os.path.join(ROOT, "assets", "DTKillerBubbles.bundle")

APPEARANCES = ("light", "dark", "highlight", "highlight_dark")
SCALES = (1, 2, 3)

failures = []
notes = []


def fail(check, detail):
    failures.append({"check": check, "detail": detail})


# ---------------------------------------------------------------------------
# PNG（纯标准库解码）
# ---------------------------------------------------------------------------
def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("bad signature")
    pos = 8
    idat = bytearray()
    chunks = []
    w = h = bd = ctype = inter = None
    seen_iend = False
    while pos < len(data):
        (ln,) = struct.unpack(">I", data[pos:pos + 4])
        typ = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + ln]
        (crc,) = struct.unpack(">I", data[pos + 8 + ln:pos + 12 + ln])
        calc = zlib.crc32(typ + payload) & 0xFFFFFFFF
        chunks.append({"type": typ.decode("latin1"), "len": ln, "crc_ok": crc == calc})
        if typ == b"IHDR":
            w, h, bd, ctype, comp, filt, inter = struct.unpack(">IIBBBBB", payload)
        elif typ == b"IDAT":
            idat += payload
        elif typ == b"IEND":
            seen_iend = True
            break
        pos += 12 + ln
    if not seen_iend:
        raise ValueError("no IEND")
    if bd != 8 or ctype != 6 or inter != 0:
        raise ValueError("expect 8-bit RGBA non-interlaced, got bd=%s ctype=%s inter=%s"
                         % (bd, ctype, inter))
    raw = zlib.decompress(bytes(idat))
    bpp = 4
    stride = w * bpp
    expect = h * (stride + 1)
    if len(raw) != expect:
        raise ValueError("IDAT size %d != %d" % (len(raw), expect))
    rows = []
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        f = raw[p]
        p += 1
        cur = bytearray(raw[p:p + stride])
        p += stride
        if f == 0:
            pass
        elif f == 1:
            for i in range(bpp, stride):
                cur[i] = (cur[i] + cur[i - bpp]) & 0xFF
        elif f == 2:
            for i in range(stride):
                cur[i] = (cur[i] + prev[i]) & 0xFF
        elif f == 3:
            for i in range(stride):
                left = cur[i - bpp] if i >= bpp else 0
                cur[i] = (cur[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif f == 4:
            for i in range(stride):
                a = cur[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                cur[i] = (cur[i] + paeth(a, b, c)) & 0xFF
        else:
            raise ValueError("bad filter %d at row %d" % (f, y))
        rows.append(cur)
        prev = cur
    return {"w": w, "h": h, "rows": rows, "chunks": chunks, "bytes": len(data)}


def alpha_rows(img):
    """每行抽出 alpha 通道，得到 [bytearray(w)]，供几何判定与镜像比对。"""
    w = img["w"]
    return [bytearray(row[3::4]) for row in img["rows"]] if w else []


def px(img, x, y):
    """(r, g, b, a)"""
    r = img["rows"][y]
    o = x * 4
    return r[o], r[o + 1], r[o + 2], r[o + 3]


# ---------------------------------------------------------------------------
# 颜色
# ---------------------------------------------------------------------------
def hex_rgb(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def rel_lum(rgb):
    def ch(v):
        c = v / 255.0
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(int(v)) for v in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = rel_lum(a), rel_lum(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
def check_manifest(manifest):
    if manifest.get("version") != "1.0.1":
        fail("manifest.version", "expect 1.0.1, got %r" % manifest.get("version"))
    if manifest.get("schema") != 2:
        fail("manifest.schema", "expect 2, got %r" % manifest.get("schema"))
    if manifest.get("legacy") or any(isinstance(e, dict) and e.get("legacy")
                                     for e in manifest["skins"].values()):
        fail("manifest.legacy", "legacy key still present")
    if any("normal" in n for v in manifest["skins"].values()
           for s in v["variants"].values() for a in s["images"].values() for n in a.values()):
        fail("manifest.legacy", "normal* referenced")
    compat = manifest.get("compat", {})
    if compat.get("legacyNormalAliases") is not False:
        fail("manifest.compat", "legacyNormalAliases must be false")
    if not compat.get("requiresScaleAwareLoader"):
        fail("manifest.compat", "requiresScaleAwareLoader must be true")
    if manifest.get("baseSize") != [80, 56]:
        fail("manifest.baseSize", "expect [80,56], got %r" % (manifest.get("baseSize"),))

    referenced = []
    total = 0
    for skin, entry in manifest["skins"].items():
        for side in ("self", "other"):
            v = entry["variants"][side]
            ins = v["capInsets"]
            if v.get("resizingMode") != "stretch":
                fail("manifest.resizingMode", "%s/%s" % (skin, side))
            if ins[1] + ins[3] >= 80 or ins[0] + ins[2] >= 56:
                fail("manifest.capInsets", "%s/%s has no stretch band" % (skin, side))
            sa = v["stretchArea"]
            if sa[2] <= 0 or sa[3] <= 0:
                fail("manifest.stretchArea", "%s/%s %r" % (skin, side, sa))
            want = [ins[1], ins[0], 80 - ins[1] - ins[3], 56 - ins[0] - ins[2]]
            if sa != want:
                fail("manifest.stretchArea", "%s/%s %r != caps-derived %r"
                     % (skin, side, sa, want))
            for a in APPEARANCES:
                tc = v["textColor"][a]
                if "color" not in tc or "minContrast" not in tc:
                    fail("manifest.textColor", "%s/%s/%s" % (skin, side, a))
                for s in SCALES:
                    name = v["images"][a]["%dx" % s]
                    referenced.append("%s/%s" % (skin, name))
                    total += 1
    if total != 48:
        fail("manifest.count", "referenced %d, expect 48" % total)

    on_disk = []
    for skin in manifest["skins"]:
        d = os.path.join(BUNDLE, skin)
        for f in sorted(os.listdir(d)):
            if f.endswith(".png"):
                on_disk.append("%s/%s" % (skin, f))
    if len(on_disk) != 48:
        fail("bundle.count", "disk has %d PNG, expect 48" % len(on_disk))
    missing = sorted(set(referenced) - set(on_disk))
    extra = sorted(set(on_disk) - set(referenced))
    if missing:
        fail("bundle.missing", ", ".join(missing))
    if extra:
        fail("bundle.unreferenced", ", ".join(extra))
    bad_names = [p for p in on_disk if os.path.basename(p).startswith("normal")]
    if bad_names:
        fail("bundle.legacyAlias", ", ".join(bad_names))
    return referenced


def check_image(manifest, skin, side, appearance, scale, path):
    rec = {"path": os.path.relpath(path, CAND).replace("\\", "/")}
    img = read_png(path)
    h, w = img["h"], img["w"]
    a = alpha_rows(img)
    rec.update({"w": w, "h": h, "bytes": os.path.getsize(path),
                "sha256": sha256_file(path),
                "crc_bad": [c["type"] for c in img["chunks"] if not c["crc_ok"]],
                "chunks": [c["type"] for c in img["chunks"]]})
    if rec["crc_bad"]:
        fail("png.crc", "%s %s" % (rec["path"], rec["crc_bad"]))
    exp_w, exp_h = 80 * scale, 56 * scale
    if (w, h) != (exp_w, exp_h):
        fail("png.size", "%s is %dx%d, expect %dx%d" % (rec["path"], w, h, exp_w, exp_h))

    v = manifest["skins"][skin]["variants"][side]
    ins = v["capInsets"]
    left, top = ins[1] * scale, ins[0] * scale
    right, bottom = ins[3] * scale, ins[2] * scale
    body_px = 72 * scale

    xs_all, ys_all = [], []
    for yy in range(h):
        row = a[yy]
        for xx in range(w):
            if row[xx]:
                xs_all.append(xx)
                ys_all.append(yy)
    rec["bbox"] = [min(xs_all), min(ys_all), max(xs_all), max(ys_all)]

    if side == "self":
        tx = [x for x in xs_all if x >= body_px]
        ty = [ys_all[i] for i, x in enumerate(xs_all) if x >= body_px]
        rec["tail_x_range"] = [min(tx), max(tx)]
        rec["tip_margin_px"] = int(w - 1 - max(xs_all))
        if max(xs_all) > w - 2:
            fail("tail.clipped", "%s xmax=%d w=%d" % (rec["path"], max(xs_all), w))
    else:
        tx = [x for x in xs_all if x < (w - body_px)]
        ty = [ys_all[i] for i, x in enumerate(xs_all) if x < (w - body_px)]
        rec["tail_x_range"] = [min(tx), max(tx)]
        rec["tip_margin_px"] = int(min(xs_all))
        if min(xs_all) < 1:
            fail("tail.clipped", "%s xmin=%d" % (rec["path"], min(xs_all)))
    rec["tail_y_range"] = [min(ty), max(ty)]
    rec["bottom_cap_px"] = int(bottom)
    if min(ty) < h - bottom:
        fail("tail.inStretchBandY", "%s tail ymin=%d, bottom cap starts %d"
             % (rec["path"], min(ty), h - bottom))
    if side == "self":
        if max(tx) < w - right:
            fail("tail.outsideCap", "%s tail xmax=%d < cap start %d"
                 % (rec["path"], max(tx), w - right))
        if min(tx) < w - right:
            notes.append("%s tail base enters band by %dpx (base is body overlap, ok)"
                         % (rec["path"], (w - right) - min(tx)))
    else:
        if min(tx) > left - 1:
            fail("tail.outsideCap", "%s tail xmin=%d > cap end %d"
                 % (rec["path"], min(tx), left))

    corners = [px(img, 0, 0)[3], px(img, w - 1, 0)[3],
               px(img, 0, h - 1)[3], px(img, w - 1, h - 1)[3]]
    rec["corner_alpha"] = corners
    if max(corners) != 0:
        fail("png.corner", "%s corner alpha %r != 0 (canvas must be rounded, not full-bleed)"
             % (rec["path"], corners))

    # 尾尖含 alpha（tip 附近 ±2pt）
    tipx, tipy = 78.6 * scale, 48.5 * scale
    x0, x1 = int(max(0, tipx - 2 * scale)), int(min(w, tipx + 2 * scale + 1))
    y0, y1 = int(max(0, tipy - 2 * scale)), int(min(h, tipy + 2 * scale + 1))
    tip_max = 0
    for yy in range(y0, y1):
        row = img["rows"][yy]
        for xx in range(x0, x1):
            if row[xx * 4 + 3] > tip_max:
                tip_max = row[xx * 4 + 3]
    rec["tip_alpha_max"] = tip_max
    if tip_max == 0:
        fail("tail.tipAlpha", "%s no alpha near tip" % rec["path"])

    # 拉伸带：完全不透明 + 每行颜色一致
    band_w, band_h = w - left - right, h - top - bottom
    rec["band_shape"] = [band_w, band_h]
    if band_w <= 0 or band_h <= 0:
        fail("band.empty", rec["path"])
    else:
        min_alpha = 255
        spread = 0
        for yy in range(top, h - bottom):
            row = img["rows"][yy]
            rmin = rmax = row[left * 4]
            gmin = gmax = row[left * 4 + 1]
            bmin = bmax = row[left * 4 + 2]
            for xx in range(left, w - right):
                o = xx * 4
                if row[o + 3] < min_alpha:
                    min_alpha = row[o + 3]
                r, g, b = row[o], row[o + 1], row[o + 2]
                rmin = r if r < rmin else rmin
                rmax = r if r > rmax else rmax
                gmin = g if g < gmin else gmin
                gmax = g if g > gmax else gmax
                bmin = b if b < bmin else bmin
                bmax = b if b > bmax else bmax
            row_spread = max(rmax - rmin, gmax - gmin, bmax - bmin)
            spread = row_spread if row_spread > spread else spread
        rec["band_row_spread"] = spread
        if min_alpha != 255:
            fail("band.alpha", "%s band has alpha %d" % (rec["path"], min_alpha))
        if spread > 2:
            fail("band.color", "%s row colour spread %d" % (rec["path"], spread))
    return rec, a


def check_text(manifest, skin, side, appearance, path, img):
    v = manifest["skins"][skin]["variants"][side]
    ins = v["capInsets"]
    seen = set()
    for yy in range(ins[0], 56 - ins[2]):
        row = img["rows"][yy]
        for xx in range(ins[1], 80 - ins[3]):
            o = xx * 4
            seen.add((row[o], row[o + 1], row[o + 2]))
    color = hex_rgb(v["textColor"][appearance]["color"])
    worst = min(contrast(color, row) for row in seen)
    declared = v["textColor"][appearance]["minContrast"]
    if worst < 4.5:
        fail("text.contrast", "%s/%s/%s %.2f < 4.5" % (skin, side, appearance, worst))
    if abs(worst - declared) > 0.15:
        fail("text.contrastMismatch", "%s/%s/%s declared %.2f measured %.2f"
             % (skin, side, appearance, declared, worst))
    lum = rel_lum(color)
    dark_text = appearance in ("light", "highlight")
    if dark_text and lum >= 0.5:
        fail("text.rule", "%s/%s/%s light appearance must use dark text" % (skin, side, appearance))
    if (not dark_text) and lum <= 0.5:
        fail("text.rule", "%s/%s/%s dark appearance must use light text" % (skin, side, appearance))
    return {"skin": skin, "side": side, "appearance": appearance,
            "color": v["textColor"][appearance]["color"],
            "declared": declared, "measured": round(worst, 2),
            "uniqueBg": len(seen)}


def check_zip(referenced):
    if not os.path.exists(ZIP):
        fail("zip.missing", ZIP)
        return {}
    zf = zipfile.ZipFile(ZIP)
    names = [i.filename for i in zf.infolist()]
    bad = [n for n in names if not n.startswith("DTKillerBubbles.bundle/")]
    if bad:
        fail("zip.outsideBundle", ", ".join(bad))
    if any("__MACOSX" in n or n.endswith("/") for n in names):
        fail("zip.junk", "directory or __MACOSX entry present")
    pngs = [n for n in names if n.endswith(".png")]
    if len(pngs) != 48:
        fail("zip.pngCount", "%d" % len(pngs))
    if any(os.path.basename(n).startswith("normal") for n in names):
        fail("zip.legacyAlias", "normal* present")
    for req in ("DTKillerBubbles.bundle/README.md", "DTKillerBubbles.bundle/LICENSE.txt"):
        if req not in names:
            fail("zip.required", req)
    mism = []
    hashes = {}
    for info in zf.infolist():
        if info.is_dir():
            continue
        disk = os.path.join(CAND, info.filename.replace("/", os.sep))
        if not os.path.exists(disk):
            mism.append(info.filename + " (not on disk)")
            continue
        h = hashlib.sha256(zf.read(info.filename)).hexdigest()
        hashes[info.filename] = h
        if info.file_size != os.path.getsize(disk):
            mism.append(info.filename + " size")
        elif h != sha256_file(disk):
            mism.append(info.filename + " sha256")
    if mism:
        fail("zip.mismatch", ", ".join(mism))
    on_disk = []
    for root, _, files in os.walk(BUNDLE):
        for f in files:
            on_disk.append(os.path.relpath(os.path.join(root, f), CAND).replace("\\", "/"))
    if sorted(on_disk) != sorted(names):
        fail("zip.coverage", "zip entry set != bundle files")
    return {"entries": len(names), "pngs": len(pngs),
            "bytes": os.path.getsize(ZIP), "sha256": sha256_file(ZIP),
            "mismatch": mism, "hashes": hashes}


def check_baseline():
    """只读对照 1.0.0 的 P0/P1，作为修复对照。"""
    mpath = os.path.join(OLD, "manifest.json")
    if not os.path.exists(mpath):
        return {"available": False}
    m = json.load(open(mpath, encoding="utf-8"))
    out = {"available": True, "version": m.get("version"), "cases": []}
    for skin, entry in m["skins"].items():
        for side in ("self", "other"):
            v = entry["variants"][side]
            name = v["images"]["light"]["2x"]
            img = read_png(os.path.join(OLD, skin, name))
            a = alpha_rows(img)
            h, w = img["h"], img["w"]
            body = 70 * 2
            # 只看 alpha > 128 的实体像素，避开 LANCZOS 振铃
            solid = [(x, y) for y in range(h) for x in range(w) if a[y][x] > 128]
            if side == "self":
                tail = [(x, y) for (x, y) in solid if x >= body]
            else:                                # 镜像侧：跳过贴边 1px 振铃
                tail = [(x, y) for (x, y) in solid if x < max(0, w - body - 1)]
            rec = {"skin": skin, "side": side, "tail_pixels": len(tail)}
            ys = [y for (_, y) in tail]
            xs = [x for (x, _) in solid]
            if tail:
                top_cap, bot_cap = v["capInsets"][0] * 2, v["capInsets"][2] * 2
                y0, y1 = min(ys), max(ys)
                rec["tail_y_range"] = [y0, y1]
                rec["top_cap_end"] = top_cap
                rec["bottom_cap_start"] = h - bot_cap
                rec["tail_enters_band"] = bool(y0 < h - bot_cap)
                rec["tail_out_of_caps"] = bool(y0 < top_cap or y1 > h - bot_cap)
            rec["max_x"] = max(xs)
            rec["canvas_w"] = w
            edge = w - 1 if side == "self" else 0
            col = [a[y][edge] for y in range(h)]
            rec["tip_edge_x"] = edge
            rec["tip_pixels"] = sum(1 for v_ in col if v_ > 128)
            rec["tip_alpha_max"] = max(col)
            rec["tip_at_edge"] = bool(rec["tip_alpha_max"] >= 128)
            out["cases"].append(rec)
    return out


def main():
    manifest = json.load(open(os.path.join(BUNDLE, "manifest.json"), encoding="utf-8"))
    referenced = check_manifest(manifest)

    files = {}
    alphas = {}
    texts = []
    for skin in manifest["skins"]:
        for side in ("self", "other"):
            for appearance in APPEARANCES:
                for scale in SCALES:
                    name = manifest["skins"][skin]["variants"][side]["images"][appearance]["%dx" % scale]
                    path = os.path.join(BUNDLE, skin, name)
                    if not os.path.exists(path):
                        fail("png.missing", path)
                        continue
                    rec, a = check_image(manifest, skin, side, appearance, scale, path)
                    files[rec["path"]] = rec
                    alphas[(skin, side, appearance, scale)] = a
                    if scale == 1:
                        texts.append(check_text(manifest, skin, side, appearance, path,
                                                read_png(path)))

    # 镜像一致性（alpha 逐位）
    mirror = []
    for skin in manifest["skins"]:
        for appearance in APPEARANCES:
            for scale in SCALES:
                s = alphas.get((skin, "self", appearance, scale))
                o = alphas.get((skin, "other", appearance, scale))
                if s is None or o is None:
                    continue
                ok = all(bytes(o[y]) == bytes(s[y][::-1]) for y in range(len(s)))
                mirror.append({"skin": skin, "appearance": appearance, "scale": scale, "ok": bool(ok)})
                if not ok:
                    diff = sum(1 for y in range(len(s))
                               for x in range(len(s[y])) if o[y][x] != s[y][len(s[y]) - 1 - x])
                    fail("mirror", "%s/%s/%dx differs in %d px" % (skin, appearance, scale, diff))

    zip_info = check_zip(referenced)
    base = check_baseline()

    summary = {
        "pass": len(failures) == 0,
        "failures": failures,
        "counts": {
            "png": len(files),
            "referenced": len(referenced),
            "mirror_pairs": len(mirror),
            "mirror_ok": sum(1 for m in mirror if m["ok"]),
            "text_contracts": len(texts),
            "zip_entries": zip_info.get("entries"),
            "bundle_png_bytes": sum(f["bytes"] for f in files.values()),
            "bundle_total_bytes": sum(
                os.path.getsize(os.path.join(r, f))
                for r, _, fs in os.walk(BUNDLE) for f in fs),
            "zip_bytes": zip_info.get("bytes"),
        },
        "min_contrast": min(t["measured"] for t in texts) if texts else None,
        "notes": notes,
    }

    report = {
        "generated_by": "assets/review-1.0.1/tools/audit_bubbles_1_0_1.py",
        "runtime": "CPython %s (stdlib only; no numpy, no Pillow)" % sys.version.split()[0],
        "bundle": os.path.relpath(BUNDLE, CAND).replace("\\", "/"),
        "zip": os.path.relpath(ZIP, CAND).replace("\\", "/"),
        "summary": summary,
        "files": files,
        "mirror": mirror,
        "text": texts,
        "zip": {k: v for k, v in zip_info.items() if k != "hashes"},
        "zip_hashes": zip_info.get("hashes", {}),
        "baseline_1_0_0": base,
    }
    out_json = os.path.join(CAND, "audit_report.json")
    with open(out_json, "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)

    # markdown
    lines = ["# DTBubbles 1.0.1 候选包审计报告", "",
             "生成器：`tools/audit_bubbles_1_0_1.py`（仅标准库：PNG 解码 + CRC + zlib，无 numpy / 无 Pillow）",
             "",
             "运行环境：CPython %s" % sys.version.split()[0], "",
             "## 结论", "",
             "- 自动检查：**%s**（失败 %d 项）" % ("PASS" if summary["pass"] else "FAIL", len(failures)),
             "- PNG：%d 张，被 manifest 引用 %d 张；bundle %d 字节；zip %d 字节 / %d 项" % (
                 summary["counts"]["png"], summary["counts"]["referenced"],
                 summary["counts"]["bundle_total_bytes"], summary["counts"]["zip_bytes"] or 0,
                 summary["counts"]["zip_entries"] or 0),
             "- alpha 镜像：%d/%d 组逐位一致" % (summary["counts"]["mirror_ok"], summary["counts"]["mirror_pairs"]),
             "- 文字契约：%d 组，最低实测对比度 %.2f:1" % (len(texts), summary["min_contrast"] or 0),
             ""]
    if failures:
        lines += ["## 失败项", ""] + ["- `%s` %s" % (f["check"], f["detail"]) for f in failures] + [""]
    lines += ["## 逐图检查", "",
              "| 文件 | 尺寸 | bytes | CRC | 尾 y 范围 | 尾尖留白 px | 拉伸带 |",
              "| --- | --- | --- | --- | --- | --- | --- |"]
    for p, r in sorted(files.items()):
        lines.append("| `%s` | %dx%d | %d | %s | %s | %d | %s |" % (
            p, r["w"], r["h"], r["bytes"], "ok" if not r["crc_bad"] else "BAD",
            "%d..%d" % tuple(r["tail_y_range"]), r["tip_margin_px"],
            "ok" if "band_shape" in r else "-"))
    lines += ["", "## textColor 契约", "",
              "| skin | side | appearance | color | 实测 | 声明 |", "| --- | --- | --- | --- | --- | --- |"]
    for t in texts:
        lines.append("| %s | %s | %s | `%s` | %.2f | %.2f |" % (
            t["skin"], t["side"], t["appearance"], t["color"], t["measured"], t["declared"]))
    if base.get("available"):
        lines += ["", "## 1.0.0 对照（只读复现）", "",
                  "| skin | side | 尾巴像素 | 尾 y 范围 | 进入拉伸带 | 尾尖贴边 |",
                  "| --- | --- | --- | --- | --- | --- |"]
        for c in base["cases"]:
            lines.append("| %s | %s | %d | %s | %s | %s |" % (
                c["skin"], c["side"], c["tail_pixels"],
                "%d..%d" % tuple(c["tail_y_range"]) if "tail_y_range" in c else "-",
                c.get("tail_enters_band", "-"), c["tip_at_edge"]))
    out_md = os.path.join(CAND, "audit_report.md")
    with open(out_md, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")

    print("PASS" if summary["pass"] else "FAIL", "failures=%d" % len(failures))
    for f_ in failures:
        print(" -", f_["check"], f_["detail"])
    print("python:", sys.version.split()[0], "(stdlib only)")
    print("json:", out_json)
    print("md  :", out_md)
    return 0 if summary["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
