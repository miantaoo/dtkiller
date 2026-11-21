#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成 assets/review-1.0.1/preview_review.png。

内容：
  1) 2x 原始切片（棋盘格透明底）+ capInsets / 实际尺寸
  2) 九宫格拉伸模拟（短 / 中 / 长换行三档），看尾巴是否被拉长
  3) 文字颜色契约对比（契约色 / 纯黑 / 纯白 三档实测对比度）

只读 assets/review-1.0.1/DTKillerBubbles.bundle。
"""

import json
import os

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
CAND = os.path.dirname(HERE)
BUNDLE = os.path.join(CAND, "DTKillerBubbles.bundle")
OUT = os.path.join(CAND, "preview_review.png")

MANIFEST = json.load(open(os.path.join(BUNDLE, "manifest.json"), encoding="utf-8"))
SKINS = ["wx8", "qq9"]
SIDES = ["self", "other"]
APPEARANCES = ["light", "dark", "highlight", "highlight_dark"]

W = 1640
PAD = 28
BG = (250, 250, 252)
INK = (24, 24, 27)
MUTED = (108, 110, 120)
ACCENT = (198, 40, 40)
BAND = (26, 108, 220)
GRID_A = (255, 255, 255)
GRID_B = (226, 231, 238)

FONT = "C:/Windows/Fonts/msyh.ttc"
FONT_B = "C:/Windows/Fonts/msyhbd.ttc"


def font(size, bold=False):
    try:
        return ImageFont.truetype(FONT_B if bold else FONT, size)
    except Exception:
        return ImageFont.truetype(FONT, size)


def checker(size, step=12):
    w, h = size
    img = Image.new("RGB", (w, h), GRID_A)
    d = ImageDraw.Draw(img)
    for y in range(0, h, step):
        for x in range(0, w, step):
            if ((x // step) + (y // step)) % 2:
                d.rectangle([x, y, x + step - 1, y + step - 1], fill=GRID_B)
    return img


def load(skin, side, appearance, scale=2):
    name = MANIFEST["skins"][skin]["variants"][side]["images"][appearance]["%dx" % scale]
    return Image.open(os.path.join(BUNDLE, skin, name)).convert("RGBA")


def caps_pt(skin, side):
    return MANIFEST["skins"][skin]["variants"][side]["capInsets"]


def text_color(skin, side, appearance):
    h = MANIFEST["skins"][skin]["variants"][side]["textColor"][appearance]["color"].lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def nine_slice(img, w_px, h_px, caps, scale):
    t, l, b, r = [int(round(v * scale)) for v in caps]
    sw, sh = img.size
    xs = [0, l, sw - r, sw]
    ys = [0, t, sh - b, sh]
    xd = [0, l, w_px - r, w_px]
    yd = [0, t, h_px - b, h_px]
    out = Image.new("RGBA", (w_px, h_px), (0, 0, 0, 0))
    for i in range(3):
        for j in range(3):
            patch = img.crop((xs[i], ys[j], xs[i + 1], ys[j + 1]))
            tw, th = xd[i + 1] - xd[i], yd[j + 1] - yd[j]
            if tw <= 0 or th <= 0:
                continue
            if patch.size != (tw, th):
                patch = patch.resize((tw, th), Image.BILINEAR)
            out.paste(patch, (xd[i], yd[j]))
    return out


def wrap(text, fnt, max_w):
    lines, cur = [], ""
    for ch in text:
        if ch == "\n":
            lines.append(cur)
            cur = ""
            continue
        if cur and fnt.getlength(cur + ch) > max_w:
            lines.append(cur)
            cur = ch
        else:
            cur += ch
    lines.append(cur)
    return lines


def contrast(a, b):
    def lin(c):
        c = c / 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    la = 0.2126 * lin(a[0]) + 0.7152 * lin(a[1]) + 0.0722 * lin(a[2])
    lb = 0.2126 * lin(b[0]) + 0.7152 * lin(b[1]) + 0.0722 * lin(b[2])
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


class Page(object):
    def __init__(self):
        self.img = Image.new("RGBA", (W, 5200), BG + (255,))
        self.overlay = Image.new("RGBA", (W, 5200), (0, 0, 0, 0))
        self.d = ImageDraw.Draw(self.img)
        self.od = ImageDraw.Draw(self.overlay)

    def text(self, xy, s, size=17, fill=INK, bold=False):
        self.d.text(xy, s, font=font(size, bold), fill=fill)

    def bubble(self, rgba, xy, box=True):
        tile = checker(rgba.size)
        tile.paste(rgba, (0, 0), rgba)
        self.img.paste(tile, xy)
        if box:
            self.d.rectangle([xy[0], xy[1], xy[0] + rgba.width - 1, xy[1] + rgba.height - 1],
                             outline=(186, 191, 200))

    def dashed(self, box, color, dash=6, gap=4, width=2):
        x0, y0, x1, y1 = box
        for x in range(x0, x1, dash + gap):
            self.od.line([(x, y0), (min(x + dash, x1), y0)], fill=color, width=width)
            self.od.line([(x, y1), (min(x + dash, x1), y1)], fill=color, width=width)
        for y in range(y0, y1, dash + gap):
            self.od.line([(x0, y), (x0, min(y + dash, y1))], fill=color, width=width)
            self.od.line([(x1, y), (x1, min(y + dash, y1))], fill=color, width=width)

    def finish(self, path, height):
        out = Image.alpha_composite(self.img, self.overlay).convert("RGB")
        out = out.crop((0, 0, W, height))
        out.save(path, "PNG", optimize=True)
        return out.size


def section_title(p, y, num, text, note=""):
    p.text((PAD, y), num, size=26, fill=ACCENT, bold=True)
    p.text((PAD + 48, y - 2), text, size=26, bold=True)
    if note:
        p.text((PAD + 48, y + 34), note, size=17, fill=MUTED)
        return y + 76
    return y + 46


def build():
    p = Page()
    y = PAD
    p.text((PAD, y), "DTKillerBubbles 1.0.1 · 候选皮肤审查图", size=38, bold=True)
    y += 54
    geo = MANIFEST["geometry"]
    p.text((PAD, y),
           "画布 %d×%d pt · 主体 %.0f×%d pt · 尾巴 y %.1f–%.1f（尖 %s）· 尾巴整体位于底部固定 cap 内"
           % (geo["canvas"][0], geo["canvas"][1], geo["body"][0], geo["body"][1],
              geo["tail"]["rangeY"][0], geo["tail"]["rangeY"][1], geo["tail"]["tip"]),
           size=19, fill=MUTED)
    y += 30
    p.text((PAD, y),
           "气泡图为 2x 像素源（按原尺寸显示）· 棋盘格 = 透明像素 · 红色虚线内 = 可拉伸区 · 蓝色半透明 = 纵向/横向拉伸带",
           size=17, fill=MUTED)
    y += 48

    # ---------- 1) 原始切片 ----------
    y = section_title(p, y, "1", "原始切片与 capInsets（2x，未拉伸）",
                      "左右两侧都必须有尾巴；尾巴必须完全落在红色虚线之外（即底部固定 cap 内）")
    cell_w = (W - PAD * 2) // 4
    row_h = 196
    for appearance in APPEARANCES:
        for idx, side in enumerate(SIDES):
            for si, skin in enumerate(SKINS):
                col = si * 2 + idx
                x = PAD + col * cell_w
                img = load(skin, side, appearance, 2)
                ox = x + (cell_w - img.width) // 2
                p.bubble(img, (ox, y))
                caps = caps_pt(skin, side)
                band = MANIFEST["skins"][skin]["variants"][side]["stretchArea"]
                bx0, by0 = ox + band[0] * 2, y + band[1] * 2
                bx1, by1 = bx0 + band[2] * 2, by0 + band[3] * 2
                p.od.rectangle([bx0, by0, bx1, by1], fill=BAND + (46,),
                               outline=BAND + (200,), width=1)
                p.dashed([ox + caps[1] * 2, y + caps[0] * 2,
                          ox + img.width - caps[3] * 2 - 1,
                          y + img.height - caps[2] * 2 - 1], ACCENT + (255,))
                lab = "%s / %s / %s · %d×%d px" % (skin, side, appearance, img.width, img.height)
                lx = min(ox, W - PAD - font(15, True).getlength(lab))
                p.text((lx, y + img.height + 8), lab, size=15, bold=True)
                lab2 = "cap L%d T%d R%d B%d · 可拉伸 %d×%d pt" % (
                    caps[1], caps[0], caps[3], caps[2], band[2], band[3])
                p.text((min(ox, W - PAD - font(14).getlength(lab2)), y + img.height + 30),
                       lab2, size=14, fill=MUTED)
        y += row_h

    # ---------- 2) 拉伸模拟 ----------
    y += 10
    y = section_title(p, y, "2", "九宫格拉伸模拟（2x 像素，按 capInsets 拉伸）",
                      "同一张图拉伸成短/中/长+换行三档；尾巴应保持原形状，只有中段变长")
    samples = [
        ("wx8", "self", "light", "在吗？", "在吗？晚上有空吗", "今晚八点老地方见，别又迟到，我已经订好位置了。"),
        ("wx8", "other", "dark", "收到", "收到，马上到楼下", "文件我发你邮箱了，注意查收，两个版本都在附件里。"),
        ("qq9", "self", "highlight", "好", "好的，我看一下", "刚看到，抱歉！我这边网络断了，现在处理，十分钟内给你结果。"),
        ("qq9", "other", "highlight_dark", "OK", "OK，我确认过了", "图纸我改完了，第三版的尺寸标注麻烦你再确认一下。"),
    ]
    col_w = 480
    gap = 14
    for skin, side, appearance, short, mid, long in samples:
        s = 2.0
        caps = caps_pt(skin, side)
        src = load(skin, side, appearance, 2)
        col = text_color(skin, side, appearance)
        p.text((PAD, y), "%s / %s / %s · 文字色 %s" % (
            skin, side, appearance,
            MANIFEST["skins"][skin]["variants"][side]["textColor"][appearance]["color"]),
            size=17, bold=True)
        y += 34
        variants = [(150, 56, short), (240, 56, mid), (300, 92, long)]
        row_h = 0
        for vi, (wpt, hpt, txt) in enumerate(variants):
            w_px, h_px = int(wpt * s), int(hpt * s)
            out = nine_slice(src, w_px, h_px, caps, 2)
            lay = Image.new("RGBA", (w_px, h_px), (0, 0, 0, 0))
            lay.alpha_composite(out, (0, 0))
            ld = ImageDraw.Draw(lay)
            inner_w = w_px - int((caps[1] + caps[3]) * s)
            inner_h = h_px - int((caps[0] + caps[2]) * s)
            fnt = font(28)
            lines = wrap(txt, fnt, max(20, inner_w - 8))
            while 34 * len(lines) > inner_h and fnt.size > 18:
                fnt = font(fnt.size - 2)
                lines = wrap(txt, fnt, max(20, inner_w - 8))
            step = int(fnt.size * 1.24)
            th = step * len(lines)
            ty = int(caps[0] * s) + max(0, (inner_h - th) // 2)
            for ln in lines:
                tw = fnt.getlength(ln)
                ld.text((int(caps[1] * s) + max(0, int((inner_w - tw) / 2)), ty),
                        ln, font=fnt, fill=col + (255,))
                ty += step
            x = PAD + vi * (col_w + gap)
            p.bubble(lay, (x, y))
            p.text((x, y + h_px + 8), "%d×%d pt（%d×%d px）" % (wpt, hpt, w_px, h_px),
                   size=15, fill=MUTED)
            row_h = max(row_h, h_px + 34)
        y += row_h + 14

    # ---------- 3) 文字颜色契约 ----------
    y += 6
    y = section_title(p, y, "3", "文字颜色契约（WCAG 2.1 对比度，正文需 ≥ 4.5:1）",
                      "契约色取自 manifest；纯黑/纯白是“硬编码白字/黑字”的对照，用来暴露亮色皮肤白字不可读")
    sw_w, sw_h = 168, 58
    for skin in SKINS:
        for side in SIDES:
            for appearance in APPEARANCES:
                entry = MANIFEST["skins"][skin]["variants"][side]["textColor"][appearance]
                img = load(skin, side, appearance, 2)
                px = img.getpixel((int(img.width * 0.55), int(img.height * 0.28)))
                bg = (px[0], px[1], px[2])
                p.text((PAD, y + 18), "%s / %s / %s" % (skin, side, appearance), size=17, bold=True)
                p.text((PAD, y + 40), "契约 %s" % entry["color"], size=14, fill=MUTED)
                cand = [("契约色", text_color(skin, side, appearance), entry["minContrast"]),
                        ("纯黑", (0, 0, 0), None),
                        ("纯白", (255, 255, 255), None)]
                xx = PAD + 250
                for label, colr, ratio in cand:
                    p.d.rectangle([xx, y, xx + sw_w, y + sw_h], fill=bg, outline=(160, 165, 175))
                    p.d.text((xx + 14, y + 14), "气泡 Aa 文字", font=font(20, True), fill=colr)
                    r = ratio if ratio is not None else contrast(colr, bg)
                    tag = "AAA" if r >= 7 else ("AA" if r >= 4.5 else "不达标")
                    colour = (18, 122, 62) if r >= 4.5 else ACCENT
                    p.text((xx, y + sw_h + 5), "%s %.2f:1 · %s" % (label, r, tag),
                           size=14, fill=colour)
                    xx += sw_w + 34
                y += 96

    y += 8
    p.d.line([(PAD, y), (W - PAD, y)], fill=(210, 214, 220))
    y += 14
    p.text((PAD, y), "仍需人工确认：微信/QQ 真机上的尾巴朝向与圆角观感；本图为离线渲染，不含真机截图。",
           size=17, fill=MUTED)
    y += 34
    return p.finish(OUT, y + PAD)


if __name__ == "__main__":
    size = build()
    print("preview:", OUT, size, os.path.getsize(OUT), "bytes")
