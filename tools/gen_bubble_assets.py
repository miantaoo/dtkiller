#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DTKiller 气泡皮肤资源生成器（原创图形，CC0-1.0）

生成两套可再分发的「近似风格」气泡：
  wx8  —— 新版微信风格（扁平、白/绿、细边）
  qq9  —— QQ 风格（浅蓝渐变、白色对侧、圆角更大）

每个变体输出 1x/2x/3x PNG，透明背景、sRGB、直通 alpha。
九宫格 cap insets 与几何一起计算，写入 manifest.json。

用法：
  py -3.13 tools/gen_bubble_assets.py
  py -3.13 tools/gen_bubble_assets.py --out assets/DTKillerBubbles.bundle
"""

import argparse
import json
import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

SS = 4  # 超采样倍数

# ---------------------------------------------------------------------------
# 几何：1x 画布。self 尾巴在右，other 尾巴在左（镜像生成）。
# 画布 76x56；主体 0..70，尾巴 70..76。
# ---------------------------------------------------------------------------
BASE_W, BASE_H = 76, 56
BODY_W = 70
TAIL_X = BODY_W
TAIL_TOP, TAIL_TIP, TAIL_BOTTOM = 16, 26, 36

SKINS = {
    "wx8": {
        "display": "微信 8 风格（原创近似）",
        "radius": 8.0,
        "border": 0.75,
        "tail_control": 3.0,
        "light": {
            "self": ("#95EC69", "#7DD454"),
            "other": ("#FFFFFF", "#E4E4E4"),
        },
        "dark": {
            "self": ("#2F5D45", "#3E7256"),
            "other": ("#2C2C2E", "#3A3A3C"),
        },
        "highlight": {
            "self": ("#86DA5E", "#6FC44A"),
            "other": ("#F2F2F2", "#D8D8D8"),
        },
        "highlight_dark": {
            "self": ("#284F3B", "#37664C"),
            "other": ("#252527", "#333335"),
        },
        # 主体左上/右下两个角的圆角半径相同；cap insets 覆盖圆角 + 尾巴。
        "insets_self": (18, 20, 18, 26),
        "insets_other": (18, 26, 18, 20),
    },
    "qq9": {
        "display": "QQ 风格（原创近似，浅色可读版）",
        "radius": 10.0,
        "border": 0.75,
        "tail_control": 3.5,
        "gradient": True,
        "light": {
            "self": ("#D6EFFF", "#9FD8FF", "#7CC7F5"),
            "other": ("#FFFFFF", "#FFFFFF", "#DCDCDC"),
        },
        "dark": {
            "self": ("#1E3D52", "#173246", "#2A5675"),
            "other": ("#2C2C2E", "#2C2C2E", "#3A3A3C"),
        },
        "highlight": {
            "self": ("#C2E5FB", "#8CCDF7", "#69B8EA"),
            "other": ("#F2F2F2", "#F2F2F2", "#D0D0D0"),
        },
        "highlight_dark": {
            "self": ("#1A3547", "#132C3E", "#24506C"),
            "other": ("#252527", "#252527", "#333335"),
        },
        "insets_self": (20, 20, 18, 28),
        "insets_other": (20, 28, 18, 20),
    },
}


def hex_rgb(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def bezier(p0, p1, p2, steps=24):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t ** 2 * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t ** 2 * p2[1]
        pts.append((x, y))
    return pts


def build_mask(scale, radius, tail_right, tail_control):
    """返回超采样后的 L 模式 mask。scale 为 1/2/3，内部再乘 SS。"""
    W, H = BASE_W * scale * SS, BASE_H * scale * SS
    m = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(m)
    r = radius * SS
    body_w = BODY_W * scale * SS
    d.rounded_rectangle([0, 0, body_w - 1, H - 1], radius=r, fill=255)

    if tail_right:
        x0 = body_w - 2
        tip = (TAIL_X + 6) * scale * SS
        top, bottom = TAIL_TOP * scale * SS, TAIL_BOTTOM * scale * SS
        mid = TAIL_TIP * scale * SS
        c = tail_control * SS
        up = bezier((x0, top), (x0 + c, top + 2 * SS), (tip, mid))
        down = bezier((tip, mid), (x0 + c, bottom - 2 * SS), (x0, bottom))
        d.polygon(up + down, fill=255)
    else:
        # 先按右侧画，再整体镜像，保证两侧完全对称
        m = m.transpose(Image.FLIP_LEFT_RIGHT)

    return m


def render(skin, variant, side, appearance, scale):
    """variant: light | dark | highlight | highlight_dark"""
    W, H = BASE_W * scale * SS, BASE_H * scale * SS
    tail_right = (side == "self")
    cfg = SKINS[skin]
    m = build_mask(scale, cfg["radius"] * scale, tail_right, cfg["tail_control"])

    # 颜色表
    palette = cfg[variant][side]
    if cfg.get("gradient"):
        top, bottom, border = [hex_rgb(c) for c in palette]
        fill = Image.new("RGB", (W, H))
        px = fill.load()
        for y in range(H):
            t = y / max(1, H - 1)
            col = tuple(round(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
            for x in range(W):
                px[x, y] = col
    else:
        fill_c, border_c = [hex_rgb(c) for c in palette]
        fill = Image.new("RGB", (W, H), fill_c)
        border = border_c

    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    out.paste(fill, (0, 0), m)

    # 边框：mask 减去腐蚀后的 mask
    bw = max(1, round(cfg["border"] * scale * SS))
    if bw % 2 == 0:
        bw += 1
    eroded = m.filter(ImageFilter.MinFilter(bw))
    ring = ImageChops.subtract(m, eroded)
    border_img = Image.new("RGBA", (W, H), border + (255,))
    out.paste(border_img, (0, 0), ring)

    # 下采样到目标尺寸
    target = (BASE_W * scale, BASE_H * scale)
    if out.size != target:
        out = out.resize(target, Image.LANCZOS)
    return out


def mirror_insets(insets):
    t, l, b, r = insets
    return (t, r, b, l)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join("assets", "DTKillerBubbles.bundle"))
    args = ap.parse_args()

    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)

    manifest = {
        "schema": 1,
        "name": "DTKiller Bubble Skins",
        "identifier": "com.dt.dtkiller.bubbles",
        "version": "1.0.0",
        "license": "CC0-1.0 (original artwork; not Tencent assets)",
        "baseSize": [BASE_W, BASE_H],
        "skins": {},
    }

    for skin, cfg in SKINS.items():
        skin_dir = os.path.join(out_dir, skin)
        os.makedirs(skin_dir, exist_ok=True)
        entry = {
            "displayName": cfg["display"],
            "variants": {},
        }
        for side in ("self", "other"):
            insets = cfg["insets_self"] if side == "self" else cfg["insets_other"]
            side_entry = {
                "capInsets": list(insets),
                "resizingMode": "stretch",
                "images": {},
            }
            for appearance in ("light", "dark", "highlight", "highlight_dark"):
                names = {}
                for scale in (1, 2, 3):
                    suffix = "" if scale == 1 else "@%dx" % scale
                    name = "bubble_%s_%s%s.png" % (side, appearance, suffix)
                    img = render(skin, appearance, side, appearance, scale)
                    img.save(os.path.join(skin_dir, name), "PNG", optimize=True)
                    names[str(scale) + "x"] = name
                side_entry["images"][appearance] = names
            entry["variants"][side] = side_entry

        manifest["skins"][skin] = entry

        # 兼容现有 DTBatch2.m 的单图模式：normal = self/light
        for scale in (1, 2, 3):
            suffix = "" if scale == 1 else "@%dx" % scale
            src = os.path.join(skin_dir, "bubble_self_light%s.png" % suffix)
            dst = os.path.join(skin_dir, "normal%s.png" % suffix)
            with open(src, "rb") as f:
                data = f.read()
            with open(dst, "wb") as f:
                f.write(data)
        entry["legacy"] = {"normal": {"capInsets": list(cfg["insets_self"]),
                                      "note": "single-image fallback for old loader"}}

    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)

    info = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.dt.dtkiller.bubbles</string>
    <key>CFBundleName</key><string>DTKillerBubbles</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1.0.0</string>
</dict>
</plist>
"""
    with open(os.path.join(out_dir, "Info.plist"), "w", encoding="utf-8") as f:
        f.write(info)

    # 预览联系表：两套皮肤 × 明/暗 × self/other
    pad = 10
    cell_w, cell_h = BASE_W * 2 + pad * 2, BASE_H * 2 + pad * 2
    sheet = Image.new("RGBA", (cell_w * 4, cell_h * 2), (245, 245, 245, 255))
    yy = 0
    for skin in ("wx8", "qq9"):
        xx = 0
        for appearance in ("light", "dark"):
            for side in ("self", "other"):
                img = render(skin, appearance, side, appearance, 2)
                sheet.alpha_composite(img, (xx * cell_w + pad, yy * cell_h + pad))
                xx += 1
        yy += 1
    sheet = sheet.convert("RGB")
    sheet.save(os.path.join(os.path.dirname(out_dir), "preview.png"), "PNG", optimize=True)

    print("written:", out_dir)
    for root, _, files in os.walk(out_dir):
        pngs = [f for f in files if f.endswith(".png")]
        if pngs:
            print(" ", os.path.relpath(root, out_dir), len(pngs), "png")


if __name__ == "__main__":
    main()
