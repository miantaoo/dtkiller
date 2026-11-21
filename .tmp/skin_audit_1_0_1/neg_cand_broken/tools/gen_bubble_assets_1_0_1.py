#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DTKiller 气泡皮肤资源生成器 —— 候选 1.0.1（原创图形，CC0-1.0）

相对 1.0.0 的修复（对应独立审计 P0/P1）：

A. 尾巴不再只画在 self 上：mask 永远绘制「主体 + 右侧尾巴」，other 由同一张
   RGBA 整体水平镜像得到，因此两向 alpha 逐位镜像一致。
B. 尾巴整体移入底部固定 cap：尾巴 y 34..54.5，底部 cap >= 24；上下可拉伸带
   y 18..32 与尾巴不相交，纵向拉伸不会再拉长尾巴。
C. 画布从 76x56 扩到 80x56，主体 72 宽，尾尖 x=78.6，右侧留 1.4pt 透明边，
   尾尖不再落在画布外缘被裁。
D. manifest 增加 textColor 契约（每种 skin/side/appearance 一项，含实测
   WCAG 对比度与最差背景色）；导航条/文字颜色由调用方读取，不在资源层硬编码。
E. 不再生成 normal*.png legacy alias，也不再写 legacy 段；bundle 只含
   manifest 引用的 48 张 PNG。

用法：
  py -3.13 assets/review-1.0.1/tools/gen_bubble_assets_1_0_1.py
"""

import argparse
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter

SS = 4  # 超采样倍数

# ---------------------------------------------------------------------------
# 几何（1x，单位 pt）
#
#   canvas 80x56
#   body   0..72 x 0..56, 圆角 radius
#   tail   尾根在 x=70（落在主体内部 2pt，避免接缝），尾尖 (78.6, 42)
#          y 方向 34..54.5，完全落在 bottom cap 内
#
#   纵向可拉伸带: [top, 56-bottom] = [18, 32]（wx8）/ [20, 32]（qq9）
#   横向可拉伸带: [left, 80-right]
#   尾巴 x >= 70 / y >= 34，与两条带都不相交。
# ---------------------------------------------------------------------------
BASE_W, BASE_H = 80, 56
BODY_W = 72.0

TAIL_TOP = 34.0
TAIL_BOTTOM = 54.5
TAIL_BASE_X = BODY_W - 2.0          # 70.0
TAIL_TIP = (78.6, 48.5)
TAIL_CTRL_UP = (76.2, 40.0)
TAIL_END = (67.5, 54.5)
TAIL_CTRL_DOWN = (76.4, 52.6)
TAIL_STEPS = 96

DARK_TEXT = "#191919"
LIGHT_TEXT = "#F2F2F7"

APPEARANCES = ("light", "dark", "highlight", "highlight_dark")
SCALES = (1, 2, 3)

SKINS = {
    "wx8": {
        "display": "微信 8 风格（原创近似）",
        "radius": 8.0,
        "border": 0.75,
        "insets_self": (18, 18, 24, 28),      # top, left, bottom, right
        "insets_other": (18, 28, 24, 18),
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
    },
    "qq9": {
        "display": "QQ 风格（原创近似，浅色可读版）",
        "radius": 10.0,
        "border": 0.75,
        "insets_self": (20, 20, 24, 30),
        "insets_other": (20, 30, 24, 20),
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
    },
}


# ---------------------------------------------------------------------------
# 颜色
# ---------------------------------------------------------------------------
def hex_rgb(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def rel_luminance(rgb):
    def ch(v):
        c = v / 255.0
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (ch(v) for v in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(a, b):
    la, lb = rel_luminance(a), rel_luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def text_rule(appearance):
    """返回 (颜色 hex, 是否深色字)。"""
    if appearance in ("light", "highlight"):
        return DARK_TEXT, True
    return LIGHT_TEXT, False


def palette_parts(cfg, appearance, side):
    pal = cfg[appearance][side]
    if len(pal) == 3:
        return hex_rgb(pal[0]), hex_rgb(pal[1]), hex_rgb(pal[2])
    return hex_rgb(pal[0]), hex_rgb(pal[0]), hex_rgb(pal[1])


def text_contract(cfg, appearance, side):
    top, bottom, _border = palette_parts(cfg, appearance, side)
    color_hex, dark = text_rule(appearance)
    color = hex_rgb(color_hex)
    worst = min(((contrast_ratio(color, bg), bg) for bg in (top, bottom)),
                key=lambda kv: kv[0])
    ratio, bg = worst
    lum = rel_luminance(color)
    if dark and lum >= 0.5:
        raise AssertionError("light appearance must use dark text (%s)" % appearance)
    if (not dark) and lum <= 0.5:
        raise AssertionError("dark appearance must use light text (%s)" % appearance)
    if ratio < 4.5:
        raise AssertionError("contrast %.2f < 4.5 for %s/%s" % (ratio, appearance, side))
    return {
        "color": color_hex,
        "minContrast": round(ratio, 2),
        "against": "#%02X%02X%02X" % bg,
        "wcag": "AA-normal-text (>=4.5:1)",
    }


# ---------------------------------------------------------------------------
# 形状
# ---------------------------------------------------------------------------
def bezier(p0, p1, p2, steps=TAIL_STEPS):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        x = (1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t ** 2 * p2[0]
        y = (1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t ** 2 * p2[1]
        pts.append((x, y))
    return pts


def tail_outline():
    up = bezier((TAIL_BASE_X, TAIL_TOP), TAIL_CTRL_UP, TAIL_TIP)
    down = bezier(TAIL_TIP, TAIL_CTRL_DOWN, TAIL_END)
    return up + down[1:]


def build_mask(scale, radius):
    """1x 逻辑坐标下的 mask，超采样 SS 倍。始终含右侧尾巴。"""
    w = BASE_W * scale * SS
    h = BASE_H * scale * SS
    k = scale * SS
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, BODY_W * k - 1, h - 1], radius=radius * k, fill=255)
    d.polygon([(x * k, y * k) for (x, y) in tail_outline()], fill=255)
    return m


def border_width(cfg, scale):
    bw = int(round(cfg["border"] * scale * SS))
    if bw < 3:
        bw = 3
    if bw % 2 == 0:
        bw += 1
    return bw


def fill_image(cfg, appearance, side, w, h):
    top, bottom, _border = palette_parts(cfg, appearance, side)
    t = np.linspace(0.0, 1.0, h, dtype=np.float64)[:, None]
    rows = np.array(top, dtype=np.float64) * (1 - t) + np.array(bottom, dtype=np.float64) * t
    return np.repeat(rows[:, None, :], w, axis=1)


def render(cfg, appearance, side, scale):
    """返回 RGBA 图；other 由 self 形状整体镜像，alpha 与 self 逐位镜像一致。"""
    radius = cfg["radius"]
    hi = build_mask(scale, radius)
    bw = border_width(cfg, scale)
    ring_hi = ImageChops.subtract(hi, hi.filter(ImageFilter.MinFilter(bw)))

    tw, th = BASE_W * scale, BASE_H * scale
    mask = np.asarray(hi.resize((tw, th), Image.BOX), dtype=np.float64) / 255.0
    ring = np.asarray(ring_hi.resize((tw, th), Image.BOX), dtype=np.float64) / 255.0

    fill = fill_image(cfg, appearance, side, tw, th)
    _top, _bottom, border_rgb = palette_parts(cfg, appearance, side)
    border = np.array(border_rgb, dtype=np.float64)

    a_out = np.clip(mask + ring * (1.0 - mask), 0.0, 1.0)
    den = np.where(a_out > 1e-6, a_out, 1.0)[..., None]
    rgb = (border[None, None, :] * ring[..., None]
           + fill * mask[..., None] * (1.0 - ring[..., None])) / den
    rgb = np.where(a_out[..., None] > 1e-6, rgb, 0.0)

    out = np.dstack([np.clip(rgb, 0, 255), np.clip(a_out * 255.0, 0, 255)]).astype(np.uint8)
    img = Image.fromarray(out, "RGBA")
    if side == "other":
        img = img.transpose(Image.FLIP_LEFT_RIGHT)
    return img


# ---------------------------------------------------------------------------
# manifest
# ---------------------------------------------------------------------------
def stretch_area(insets):
    top, left, bottom, right = insets
    return [left, top, BASE_W - left - right, BASE_H - top - bottom]


def build_manifest():
    manifest = {
        "schema": 2,
        "name": "DTKiller Bubble Skins",
        "identifier": "com.dt.dtkiller.bubbles",
        "version": "1.0.1",
        "license": "CC0-1.0 (original artwork; not Tencent assets)",
        "baseSize": [BASE_W, BASE_H],
        "geometry": {
            "canvas": [BASE_W, BASE_H],
            "body": [BODY_W, BASE_H],
            "tail": {
                "shape": "single bezier tail, mirrored for other",
                "rangeY": [TAIL_TOP, TAIL_BOTTOM],
                "tip": [TAIL_TIP[0], TAIL_TIP[1]],
                "baseX": TAIL_BASE_X,
                "tailLength": round(TAIL_TIP[0] - BODY_W, 2),
                "canvasMarginRight": round(BASE_W - TAIL_TIP[0], 2),
                "sides": {"self": "right", "other": "left"},
                "insideFixedCaps": True,
            },
            "bodyRadius": {s: SKINS[s]["radius"] for s in SKINS},
        },
        "compat": {
            "legacyNormalAliases": False,
            "note": ("1.0.1 deliberately ships no normal.png / normal@2x.png / "
                     "normal@3x.png. A legacy loader that reads a single image at "
                     "scale=1 would mis-read @2x/@3x caps by 2x/3x. Loaders MUST "
                     "honour the @2x/@3x suffix (UIImage imageWithData:scale:) and "
                     "the capInsets below; otherwise this bundle must not be used."),
            "requiresScaleAwareLoader": True,
            "minimumLoader": "DTBubbleSkin 1.0.1 (assets/review-1.0.1/reference)",
        },
        "colorContract": {
            "standard": "WCAG 2.1 contrast ratio, normal text >= 4.5:1",
            "light": "dark text",
            "highlight": "dark text",
            "dark": "light text",
            "highlight_dark": "light text",
            "consumer": ("variant.textColor[appearance].color is the colour the cell "
                         "must apply to the message label; the manifest is the only "
                         "source of truth, do not hard-code white/black."),
        },
        "skins": {},
    }

    for skin, cfg in SKINS.items():
        entry = {
            "displayName": cfg["display"],
            "radius": cfg["radius"],
            "variants": {},
        }
        for side in ("self", "other"):
            insets = cfg["insets_self"] if side == "self" else cfg["insets_other"]
            variant = {
                "capInsets": list(insets),
                "resizingMode": "stretch",
                "tailSide": "right" if side == "self" else "left",
                "stretchArea": stretch_area(insets),
                "textColor": {a: text_contract(cfg, a, side) for a in APPEARANCES},
                "images": {},
            }
            for appearance in APPEARANCES:
                names = {}
                for scale in SCALES:
                    suffix = "" if scale == 1 else "@%dx" % scale
                    names["%dx" % scale] = "bubble_%s_%s%s.png" % (side, appearance, suffix)
                variant["images"][appearance] = names
            entry["variants"][side] = variant
        manifest["skins"][skin] = entry
    return manifest


README = """# DTKillerBubbles.bundle (candidate 1.0.1)

DTKiller 气泡皮肤资源包候选版。原创图形，非腾讯素材，CC0-1.0。

**这是待用户视觉确认的候选包，尚未接入 DTKiller 主工程。**

## 相对 1.0.0 的修复

| 编号 | 问题 | 1.0.1 处理 |
| --- | --- | --- |
| P0-1 | `build_mask` 只为 self 画尾巴，other 是空白 mask 的水平翻转（无尾巴） | 始终绘制「主体 + 右尾」，other 由同一张 RGBA 整体镜像；审计逐像素比对 alpha 镜像 |
| P0-2 | 尾巴 y=16..36 与纵向九宫格拉伸带相交，多行气泡会把尾巴拉长 | 尾巴移到 y=34..54.5，整体落在 bottom cap（24pt）内；纵向拉伸带只剩 y=18..32 |
| P1-1 | 尾尖 x=76 正好在 76px 画布外缘，被裁掉 1px | 画布扩到 80pt，主体 72pt，尾尖 x=78.6，右侧留 1.4pt 透明边 |
| P1-2 | 文字颜色无 manifest 契约，亮色气泡上白字不可读 | 每个 skin/side/appearance 写 `textColor`（含实测 WCAG 对比度与最差背景色） |
| P1-3 | `normal*.png` alias 会被 scale=1 的老 loader 错读 | 不再生成 alias，也不再写 `legacy` 段；只保留 manifest 引用的 48 张 PNG |

## 几何（1x，单位 pt）

```
canvas 80 x 56      body 72 x 56 (x: 0..72)
tail   y 34..54.5   tip (78.6, 48.5)   base x=70
```

| 皮肤 | 方向 | capInsets (t,l,b,r) | 横向可拉伸带 | 纵向可拉伸带 |
| --- | --- | --- | --- | --- |
| wx8 | self  | 18,18,24,28 | x 18..52 (34) | y 18..32 (14) |
| wx8 | other | 18,28,24,18 | x 28..62 (34) | y 18..32 (14) |
| qq9 | self  | 20,20,24,30 | x 20..50 (30) | y 20..32 (12) |
| qq9 | other | 20,30,24,20 | x 30..60 (30) | y 20..32 (12) |

尾巴像素范围（1x）：self x 70..78.6 / y 34..54.5；other 为其镜像 x 1.4..10 / y 34..54.5。
两条可拉伸带与尾巴均不相交，尾尖距画布右缘 1.4pt。

## 文件

```
DTKillerBubbles.bundle/
├── Info.plist          # CFBundleShortVersionString = 1.0.1
├── manifest.json       # schema 2：几何 + capInsets + textColor + 48 个文件名
├── README.md
├── LICENSE.txt
├── wx8/                 # 24 PNG = 2 sides x 4 appearances x 3 scales
└── qq9/                 # 24 PNG
```

共 48 张 PNG，全部被 manifest 引用；没有 `normal*` 别名，没有未被引用的图。

## 加载契约

1. 必须按文件名的 `@2x` / `@3x` 后缀设置 `UIImage` scale，禁止把 @2x 当 1x 读。
2. `capInsets` 必须来自本 manifest，单位 pt，**不要**对 @2x/@3x 再乘倍率。
3. 取图后 `resizableImageWithCapInsets:resizingMode:UIImageResizingModeStretch`。
4. 文案颜色取 `skins.<id>.variants.<side>.textColor.<appearance>.color`；
   `light` / `highlight` 是深色字，`dark` / `highlight_dark` 是浅色字。
5. 找不到 manifest / 文件时回退调用方内置绘制，不要退回 `normal.png`。

## 许可

本目录内的 PNG 与 manifest 由 DTKiller 项目原创生成，以 **CC0 1.0 Universal**
发布（见 `LICENSE.txt`）。不包含、也不得放入从微信 / QQ 客户端提取的任何图片、
图标、字体或 `Assets.car` 内容。

"微信"、"QQ" 是腾讯的商标；本资源包是风格近似，与腾讯无关联，不得宣称为官方素材。
"""

LICENSE = """CC0 1.0 Universal (Public Domain Dedication)

The PNG images and JSON manifests in this bundle were generated by the
DTKiller project from geometric primitives. To the extent possible under law,
the authors have waived all copyright and related or neighboring rights to
this artwork worldwide.

Full text: https://creativecommons.org/publicdomain/zero/1.0/legalcode

This bundle contains NO assets extracted from Tencent WeChat or QQ.
"微信" and "QQ" are trademarks of Tencent; this artwork is an original
style approximation and is not affiliated with or endorsed by Tencent.
"""

INFO_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.dt.dtkiller.bubbles</string>
    <key>CFBundleName</key><string>DTKillerBubbles</string>
    <key>CFBundlePackageType</key><string>BNDL</string>
    <key>CFBundleShortVersionString</key><string>1.0.1</string>
    <key>CFBundleVersion</key><string>1.0.1</string>
</dict>
</plist>
"""


# ---------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join("assets", "review-1.0.1", "DTKillerBubbles.bundle"))
    args = ap.parse_args()
    out_dir = os.path.abspath(args.out)
    os.makedirs(out_dir, exist_ok=True)

    manifest = build_manifest()

    for skin, cfg in SKINS.items():
        skin_dir = os.path.join(out_dir, skin)
        os.makedirs(skin_dir, exist_ok=True)
        for side in ("self", "other"):
            for appearance in APPEARANCES:
                for scale in SCALES:
                    img = render(cfg, appearance, side, scale)
                    name = manifest["skins"][skin]["variants"][side]["images"][appearance]["%dx" % scale]
                    img.save(os.path.join(skin_dir, name), "PNG", optimize=True)
                    if scale == 1:
                        _self_check(img, cfg, side, scale, "%s/%s/%s" % (skin, side, appearance))
                        refine_text_contract(manifest, cfg, skin, side, appearance, img)

    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=2)
        f.write("\n")
    with open(os.path.join(out_dir, "README.md"), "w", encoding="utf-8") as f:
        f.write(README)
    with open(os.path.join(out_dir, "LICENSE.txt"), "w", encoding="utf-8") as f:
        f.write(LICENSE)
    with open(os.path.join(out_dir, "Info.plist"), "w", encoding="utf-8") as f:
        f.write(INFO_PLIST)

    print("written:", out_dir)
    for root, _, files in os.walk(out_dir):
        pngs = [f for f in files if f.endswith(".png")]
        if pngs:
            print(" ", os.path.relpath(root, out_dir), len(pngs), "png")


def refine_text_contract(manifest, cfg, skin, side, appearance, img):
    """用真正落在文字区的像素重算对比度（渐变皮肤在两段 cap 之外仍有色差）。"""
    insets = cfg["insets_self"] if side == "self" else cfg["insets_other"]
    top, left, bottom, right = insets
    arr = np.asarray(img.convert("RGB"), dtype=np.int32)
    band = arr[top:BASE_H - bottom, left:BASE_W - right]
    if band.size == 0:
        return
    rows = np.unique(band.reshape(-1, 3), axis=0)
    color_hex, dark = text_rule(appearance)
    color = np.array(hex_rgb(color_hex), dtype=np.float64)
    worst = min(((contrast_ratio(color, row), tuple(int(v) for v in row)) for row in rows),
                key=lambda kv: kv[0])
    ratio, bg = worst
    manifest["skins"][skin]["variants"][side]["textColor"][appearance] = {
        "color": color_hex,
        "minContrast": round(ratio, 2),
        "against": "#%02X%02X%02X" % bg,
        "wcag": "AA-normal-text (>=4.5:1)",
    }


def _self_check(img, cfg, side, scale, tag):
    """生成期最小自检：镜像前的 alpha 结构 + 尾尖不贴边 + 拉伸带纯净。"""
    a = np.asarray(img.split()[-1])
    h, w = a.shape
    ys, xs = np.nonzero(a)
    if xs.size == 0:
        raise AssertionError("%s: empty alpha" % tag)
    if side == "self" and xs.max() > w - 2:
        raise AssertionError("%s: tail touches canvas edge (xmax=%d, w=%d)" % (tag, xs.max(), w))
    if side == "other" and xs.min() < 1:
        raise AssertionError("%s: tail touches canvas edge (xmin=%d)" % (tag, xs.min()))
    # 尾巴像素：self 取 x > body_w*scale 的部分；other 取镜像后的左侧
    body_px = int(round(BODY_W * scale))
    tail = xs > body_px if side == "self" else xs < (w - body_px)
    if not tail.any():
        raise AssertionError("%s: no tail pixels" % tag)
    ty = ys[tail]
    insets = cfg["insets_self"] if side == "self" else cfg["insets_other"]
    bottom_px = insets[2] * scale
    if ty.min() < h - bottom_px:
        raise AssertionError("%s: tail enters stretch band (ymin=%d, cap starts %d)"
                             % (tag, ty.min(), h - bottom_px))
    # 纵向拉伸带必须完全不透明
    band_top = insets[0] * scale
    band_bottom = h - bottom_px
    left = insets[1] * scale
    right = w - insets[3] * scale
    band = a[band_top:band_bottom, left:right]
    if band.size and band.min() != 255:
        raise AssertionError("%s: stretch band has holes" % tag)


if __name__ == "__main__":
    main()
