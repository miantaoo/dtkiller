#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build assets/preview_review.png: labelled comparison sheet for the bubble skin pack.

Reads the shipped PNGs (never writes into the bundle) and rasterises CJK text through
GDI32, so no third-party imaging library is required.
"""
import ctypes as C
import json
import os
import sys
import time
from ctypes import wintypes as W

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import audit_bubbles as A

BUNDLE = A.BUNDLE
ASSETS = os.path.dirname(BUNDLE)
OUT = os.path.join(ASSETS, "preview_review.png")
MANIFEST = json.load(open(os.path.join(BUNDLE, "manifest.json"), "r", encoding="utf-8"))

# ---------------------------------------------------------------- GDI text masks
gdi = C.WinDLL("gdi32", use_last_error=True)


class BITMAPINFOHEADER(C.Structure):
    _fields_ = [("biSize", W.DWORD), ("biWidth", W.LONG), ("biHeight", W.LONG),
                ("biPlanes", W.WORD), ("biBitCount", W.WORD),
                ("biCompression", W.DWORD), ("biSizeImage", W.DWORD),
                ("biXPelsPerMeter", W.LONG), ("biYPelsPerMeter", W.LONG),
                ("biClrUsed", W.DWORD), ("biClrImportant", W.DWORD)]


class BITMAPINFO(C.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", W.DWORD * 3)]


gdi.CreateCompatibleDC.restype = W.HDC
gdi.CreateCompatibleDC.argtypes = [W.HDC]
gdi.CreateDIBSection.restype = W.HBITMAP
gdi.CreateDIBSection.argtypes = [W.HDC, C.POINTER(BITMAPINFO), W.UINT,
                                 C.POINTER(C.c_void_p), W.HANDLE, W.DWORD]
gdi.SelectObject.restype = W.HGDIOBJ
gdi.SelectObject.argtypes = [W.HDC, W.HGDIOBJ]
gdi.CreateFontW.restype = W.HFONT
gdi.CreateFontW.argtypes = [C.c_int] * 5 + [W.DWORD] * 8 + [W.LPCWSTR]
gdi.SetBkMode.argtypes = [W.HDC, C.c_int]
gdi.SetTextColor.argtypes = [W.HDC, W.COLORREF]
gdi.TextOutW.argtypes = [W.HDC, C.c_int, C.c_int, W.LPCWSTR, C.c_int]
gdi.GetTextExtentPoint32W.argtypes = [W.HDC, W.LPCWSTR, C.c_int, C.POINTER(W.SIZE)]
gdi.DeleteObject.argtypes = [W.HGDIOBJ]
gdi.DeleteDC.argtypes = [W.HDC]
gdi.GdiFlush.argtypes = []

MW, MH = 1500, 110
_bmi = BITMAPINFO()
_hdr = _bmi.bmiHeader
_hdr.biSize = C.sizeof(BITMAPINFOHEADER)
_hdr.biWidth = MW
_hdr.biHeight = -MH
_hdr.biPlanes = 1
_hdr.biBitCount = 32
_hdr.biCompression = 0
_bits = C.c_void_p()
_memdc = gdi.CreateCompatibleDC(None)
_hbmp = gdi.CreateDIBSection(_memdc, C.byref(_bmi), 0, C.byref(_bits), None, 0)
gdi.SelectObject(_memdc, _hbmp)
gdi.SetBkMode(_memdc, 1)
_fonts = {}


def _font(size_px, bold):
    key = (size_px, bold)
    if key not in _fonts:
        _fonts[key] = gdi.CreateFontW(-size_px, 0, 0, 0, 700 if bold else 400,
                                      0, 0, 0, 1, 0, 0, 4, 0, "Microsoft YaHei")
    return _fonts[key]


_cache = {}


def text_mask(text, size_px, bold=False):
    """Rasterise one run; returns (w, h, stride, coverage-mask)."""
    key = (text, size_px, bold)
    if key in _cache:
        return _cache[key]
    f = _font(size_px, bold)
    gdi.SelectObject(_memdc, f)
    gdi.SetTextColor(_memdc, 0x00FFFFFF)
    n = len(text)
    sz = W.SIZE()
    gdi.GetTextExtentPoint32W(_memdc, text, n, C.byref(sz))
    w, h = min(max(1, sz.cx), MW), min(max(1, sz.cy), MH)
    C.memset(_bits, 0, MW * MH * 4)
    gdi.TextOutW(_memdc, 0, 0, text, n)
    gdi.GdiFlush()
    raw = C.string_at(_bits, MW * MH * 4)
    cov = bytearray(w * h)
    for y in range(h):
        ro = y * MW * 4
        for x in range(w):
            o = ro + x * 4
            cov[y * w + x] = max(raw[o], raw[o + 1], raw[o + 2])
    _cache[key] = (w, h, w, cov)
    return _cache[key]


# ---------------------------------------------------------------- canvas helpers
def checker(dst, dw, dh, a=(255, 255, 255), b=(228, 228, 230), cell=14):
    for y in range(dh):
        row = (y // cell) & 1
        for x in range(dw):
            c = b if ((x // cell) & 1) ^ row else a
            o = (y * dw + x) * 4
            dst[o] = c[0]; dst[o + 1] = c[1]; dst[o + 2] = c[2]; dst[o + 3] = 255


def fill_rect(dst, dw, dh, x0, y0, w, h, color):
    for y in range(max(0, y0), min(dh, y0 + h)):
        for x in range(max(0, x0), min(dw, x0 + w)):
            o = (y * dw + x) * 4
            dst[o] = color[0]; dst[o + 1] = color[1]; dst[o + 2] = color[2]; dst[o + 3] = 255


def draw_text(dst, dw, dh, text, x, y, size_px, color, bold=False):
    w, h, stride, cov = text_mask(text, size_px, bold)
    for yy in range(h):
        ty = y + yy
        if not (0 <= ty < dh):
            continue
        ro = yy * stride
        for xx in range(w):
            a = cov[ro + xx]
            if not a:
                continue
            tx = x + xx
            if not (0 <= tx < dw):
                continue
            o = (ty * dw + tx) * 4
            k = a / 255.0
            for i in range(3):
                dst[o + i] = int(dst[o + i] * (1 - k) + color[i] * k)
            dst[o + 3] = 255


# ---------------------------------------------------------------- layout
APPEARANCES = [("light", "明色 light"), ("dark", "深色 dark"),
               ("highlight", "高亮 highlight"), ("highlight_dark", "高亮·深 high-dark")]
ROWS = [("wx8", "self", "wx8 · 发送 self"), ("wx8", "other", "wx8 · 接收 other"),
        ("qq9", "self", "qq9 · 发送 self"), ("qq9", "other", "qq9 · 接收 other")]

PAD, LBL_W, CELL_W, CELL_H = 18, 200, 322, 200
HEAD_H, TITLE_H, FOOT_H = 48, 78, 104
W_PX = PAD * 2 + LBL_W + CELL_W * 4
H_PX = TITLE_H + HEAD_H + CELL_H * 4 + FOOT_H

canvas = bytearray(W_PX * H_PX * 4)
checker(canvas, W_PX, H_PX)

INK, MUT = (24, 24, 27), (108, 108, 116)
OKC, NGC = (10, 128, 56), (196, 34, 34)
WHITE, BLACK = (255, 255, 255), (0, 0, 0)

draw_text(canvas, W_PX, H_PX, "DTKillerBubbles 气泡皮肤 · 审核对照图", PAD, 14, 26, INK, True)
draw_text(canvas, W_PX, H_PX,
          "每格：交付的 @2x PNG 按 manifest capInsets 九宫格拉伸到 150×56pt（300×112px）贴入，"
          "棋盘格＝透明区域；气泡内两行示例文字为白字/黑字，用于目测可读性。",
          PAD, 46, 14, MUT)

col_x = PAD + LBL_W
for i, (_, label) in enumerate(APPEARANCES):
    draw_text(canvas, W_PX, H_PX, label, col_x + i * CELL_W + 8, TITLE_H + 14, 16, INK, True)
    fill_rect(canvas, W_PX, H_PX, col_x + i * CELL_W, TITLE_H + HEAD_H - 8, CELL_W - 8, 2, (198, 198, 203))

BODY_PT_W, BODY_PT_H = 150, 56
for r, (skin, side, rowlabel) in enumerate(ROWS):
    y0 = TITLE_H + HEAD_H + r * CELL_H
    man = MANIFEST["skins"][skin]["variants"][side]
    ins = man["capInsets"]
    draw_text(canvas, W_PX, H_PX, rowlabel, PAD, y0 + 6, 17, INK, True)
    draw_text(canvas, W_PX, H_PX, "capInsets %d,%d,%d,%d" % tuple(ins), PAD, y0 + 32, 13, MUT)
    draw_text(canvas, W_PX, H_PX, "resizingMode %s" % man.get("resizingMode", "-"), PAD, y0 + 52, 13, MUT)
    for c, (app, _) in enumerate(APPEARANCES):
        x0 = col_x + c * CELL_W
        rel2 = "%s/bubble_%s_%s@2x.png" % (skin, side, app)
        img = A.decode(os.path.join(BUNDLE, rel2.replace("/", os.sep)))
        cell = A.stretch9(img, BODY_PT_W * 2, BODY_PT_H * 2, ins, 2)
        ox, oy = x0 + 8, y0 + 6
        A.blit(canvas, W_PX, H_PX, cell, ox, oy)
        rel1 = "%s/bubble_%s_%s.png" % (skin, side, app)
        base = A.decode(os.path.join(BUNDLE, rel1.replace("/", os.sep)))
        rgb = A.rgb_at(base, 35, 28)[:3]
        cw, cb = A.contrast(rgb, WHITE), A.contrast(rgb, BLACK)
        tx = ox + ins[1] * 2 - 8
        draw_text(canvas, W_PX, H_PX, "白字 sample 123", tx, oy + 28, 20, WHITE)
        draw_text(canvas, W_PX, H_PX, "黑字 sample 123", tx, oy + 58, 20, BLACK)
        draw_text(canvas, W_PX, H_PX, "填充 #%02X%02X%02X" % rgb, x0 + 8, oy + 124, 14, MUT)
        draw_text(canvas, W_PX, H_PX, "白 %.2f:1   黑 %.2f:1" % (cw, cb), x0 + 8, oy + 146, 14, MUT)
        best = max(cw, cb)
        draw_text(canvas, W_PX, H_PX,
                  ("白字可读" if cw >= 4.5 else "白字低于4.5:1") + " / " +
                  ("黑字可读" if cb >= 4.5 else "黑字低于4.5:1"),
                  x0 + 8, oy + 168, 13, OKC if best >= 4.5 else NGC)

fy = H_PX - FOOT_H + 10
draw_text(canvas, W_PX, H_PX,
          "来源 assets/DTKillerBubbles.bundle（54 PNG + manifest.json + Info.plist + README/LICENSE）｜"
          "本图由 .tmp/skin_audit/make_preview_review.py 生成，未改动包内任何文件", PAD, fy, 14, MUT)
draw_text(canvas, W_PX, H_PX,
          "对照要点：接收 other 每格左侧可见约 6pt 透明留白且没有尾巴；发送 self 的尾巴贴住画布外缘（tail tip 被裁平）。",
          PAD, fy + 26, 14, NGC)
draw_text(canvas, W_PX, H_PX,
          "生成时间 %s   对比度按 WCAG 相对亮度计算，阈值 4.5:1" % time.strftime("%Y-%m-%d %H:%M:%S"),
          PAD, fy + 52, 13, MUT)

A.save_png(OUT, canvas, W_PX, H_PX)
print("wrote", OUT, W_PX, "x", H_PX, os.path.getsize(OUT), "bytes")
