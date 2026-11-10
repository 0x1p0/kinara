#!/usr/bin/env python3
"""Compose "real macOS desktop" product shots of Kinara for the website.

The UI renders in build/UIRender come from an offscreen SwiftUI renderer,
which cannot draw macOS window materials. This script puts them on a desktop:
a procedural wallpaper, a translucent menu bar, the settings window with its
traffic lights, rounded corners, hairline and shadow, and the menu-bar popover
hanging from Kinara's status item. Behind-window glass is simulated by tinting
the flat background pixels of the sidebar and the popover with the blurred
desktop behind them, leaving text and controls untouched.

Pure Pillow (numpy is optional and not required).

    python3 website-kinara/scripts/desktop-shots.py            # both themes
    python3 website-kinara/scripts/desktop-shots.py --theme dark --debug-dir /tmp/x
    python3 website-kinara/scripts/desktop-shots.py --shot picker   # the audio picker on the desktop
"""
from __future__ import annotations

import argparse
import math
import os
import shutil
import subprocess
import tempfile
from array import array
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont, ImageMath

ROOT = Path(__file__).resolve().parents[2]
RENDERS = ROOT / "build" / "UIRender"
OUT_DIR = ROOT / "website-kinara" / "public" / "media"

W, H = 2560, 1600          # output canvas, a 2x (Retina) 1280x800 pt screen
BAR_H = 48                 # menu bar, 24 pt
SS = 4                     # supersampling for vector shapes
WINDOW_RADIUS = 32         # 16 pt, NSWindow._cornerRadius on macOS 26 and later
PANEL_RADIUS = 22
PANEL_GAP = 8              # popover top below the menu bar
GLASS_BLUR = 50

FONT_PATHS = ["/System/Library/Fonts/SFNS.ttf",
              "/System/Library/Fonts/Helvetica.ttc",
              "/System/Library/Fonts/HelveticaNeue.ttc"]

THEMES = {
    "dark": dict(
        glass_mix=0.27,                     # share of blurred desktop in the glass
        bar_tint=(30, 30, 32), bar_alpha=0.55, ink=(255, 255, 255), ink_alpha=0.92,
        highlight=(255, 255, 255, 0.20),
        hairline=(255, 255, 255, 0.14),
        outline=(0, 0, 0, 0.55),            # macOS dark windows: black edge outside the light hairline
        shadow_alpha=0.55, contact_alpha=0.42,
        panel_shadow_alpha=0.50,
    ),
    "light": dict(
        glass_mix=0.34,
        bar_tint=(246, 246, 248), bar_alpha=0.60, ink=(0, 0, 0), ink_alpha=0.88,
        highlight=(0, 0, 0, 0.10),
        hairline=(0, 0, 0, 0.14),
        outline=None,
        shadow_alpha=0.22, contact_alpha=0.16,
        panel_shadow_alpha=0.20,
    ),
}


# ---------------------------------------------------------------- helpers

def font(size: float, weight: int = 400) -> ImageFont.FreeTypeFont:
    for path in FONT_PATHS:
        if not os.path.exists(path):
            continue
        try:
            f = ImageFont.truetype(path, size=round(size), layout_engine=ImageFont.Layout.RAQM)
        except OSError:
            continue
        try:  # SF is variable: Width, Optical size, GRAD, Weight
            axes = f.get_variation_axes()
            values = []
            for axis in axes:
                name = axis["name"].decode() if isinstance(axis["name"], bytes) else axis["name"]
                if name == "Weight":
                    values.append(weight)
                elif name == "Optical Size":
                    values.append(max(axis["minimum"], min(axis["maximum"], size / 2)))
                else:
                    values.append(axis["default"])
            f.set_variation_by_axes(values)
        except (OSError, AttributeError):
            pass
        return f
    return ImageFont.load_default(size)


def smoothstep(e0: float, e1: float, x: float) -> float:
    t = min(1.0, max(0.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def solid(color, size) -> Image.Image:
    return Image.new("RGB", size, tuple(color[:3]))


def scale_mask(mask: Image.Image, alpha: float) -> Image.Image:
    return mask.point(lambda p: round(p * alpha))


def tint(base: Image.Image, color, mask: Image.Image, alpha: float = 1.0) -> Image.Image:
    """Composite a flat colour over base through mask * alpha."""
    if alpha != 1.0:
        mask = scale_mask(mask, alpha)
    return Image.composite(solid(color, base.size), base, mask)


def rounded_mask(size, radius: float, inset: float = 0) -> Image.Image:
    """Anti-aliased rounded rectangle, drawn supersampled."""
    w, h = size
    m = Image.new("L", (w * SS, h * SS), 0)
    r = max(0.0, radius - inset) * SS
    ImageDraw.Draw(m).rounded_rectangle(
        (inset * SS, inset * SS, (w - inset) * SS - 1, (h - inset) * SS - 1), radius=r, fill=255)
    return m.resize(size, Image.Resampling.BOX)


def ring_mask(size, radius: float, width: float, outward: bool = False) -> Image.Image:
    """Inside (or outside) stroke of the rounded rectangle, anti-aliased."""
    if outward:
        w, h = size
        grown = rounded_mask((w + 2 * 4, h + 2 * 4), radius + 4, inset=4 - width)
        inner = Image.new("L", grown.size, 0)
        inner.paste(rounded_mask(size, radius), (4, 4))
        return ImageChops.subtract(grown, inner)  # caller offsets by -4
    return ImageChops.subtract(rounded_mask(size, radius), rounded_mask(size, radius, inset=width))


def noise_rgb(size, sigma: float) -> Image.Image:
    return Image.merge("RGB", [Image.effect_noise(size, sigma) for _ in range(3)])


def add_noise(img: Image.Image, sigma: float) -> Image.Image:
    """Add zero-centred grain (effect_noise is centred on 127.5)."""
    return ImageChops.add(img, noise_rgb(img.size, sigma), scale=1.0, offset=-128)


def detect_bounds(img: Image.Image) -> tuple[int, int, int, int]:
    """Find the real window inside the renderer's padding.

    The padding is a dithered grey ramp; the window starts where a scanline
    makes a jump larger than the dither. Probes four rows and four columns
    and keeps the outermost edge found (content can only jump later).
    """
    rgb = img.convert("RGB")
    px = rgb.load()
    w, h = rgb.size

    def lum(p):
        return (p[0] * 299 + p[1] * 587 + p[2] * 114) // 1000

    def first_jump(seq):
        prev = lum(seq[0])
        for i, p in enumerate(seq[1:], 1):
            v = lum(p)
            if abs(v - prev) > 6:
                return i
            prev = v
        return None

    lefts, rights, tops, bottoms = [], [], [], []
    for f in (0.3, 0.45, 0.6, 0.75):
        y = int(h * f)
        row = [px[x, y] for x in range(w)]
        lefts.append(first_jump(row))
        r = first_jump(row[::-1])
        rights.append(None if r is None else w - r)
        x = int(w * f)
        col = [px[x, yy] for yy in range(h)]
        tops.append(first_jump(col))
        b = first_jump(col[::-1])
        bottoms.append(None if b is None else h - b)
    pick = lambda vals, fn: fn(v for v in vals if v is not None)
    return pick(lefts, min), pick(tops, min), pick(rights, max), pick(bottoms, max)


def most_common(img: Image.Image) -> tuple[int, int, int]:
    colors = img.convert("RGB").getcolors(img.width * img.height)
    return max(colors, key=lambda c: c[0])[1]


def bg_distance(img: Image.Image, bg) -> Image.Image:
    """Per-pixel max channel distance from the flat background colour."""
    r, g, b = ImageChops.difference(img.convert("RGB"), solid(bg, img.size)).split()
    return ImageChops.lighter(ImageChops.lighter(r, g), b)


def icon_shield(img: Image.Image, bg, boxes) -> Image.Image:
    """Mask of the opaque app icons inside the given search boxes.

    App icons are images, not glass: a dark icon's gradient passes through
    the background grey, and a white icon's body equals a white background.
    Inside each box, flood the background in from the box's edge; whatever
    it cannot reach is the icon (its body enclosed by its edge and shadow).
    """
    shield = Image.new("L", img.size, 0)
    for box in boxes:
        near = bg_distance(img.crop(box), bg).point(lambda d: 255 if d <= 2 else 0)
        w, h = near.size
        for seed in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
            if near.getpixel(seed) == 255:
                ImageDraw.floodfill(near, seed, 128)
        icon = near.point(lambda v: 0 if v == 128 else 255)
        shield.paste(ImageChops.lighter(shield.crop(box), icon), box[:2])
    # Shrink by a pixel so the icon's own anti-aliased rim blends as usual.
    return shield.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.6))


def frost(img: Image.Image, behind: Image.Image, bg, mix: float,
          shield: Image.Image | None = None) -> Image.Image:
    """Turn flat background pixels into frosted glass.

    glass = bg blended with the blurred desktop. Every pixel is shifted by
    (glass - bg) weighted by how close it is to bg: the flat fill becomes the
    glass, the faint fills drawn on it (rows, buttons) pick up the same hue as
    real translucent fills would, and text, symbols and their anti-aliasing,
    being far from bg, stay exactly as rendered. App icons are shielded.
    """
    flat = solid(bg, img.size)
    glass = Image.blend(flat, behind.convert("RGB"), mix)
    glass = add_noise(glass, 1.0)  # material grain, also kills banding
    dist = bg_distance(img, bg)
    near, far = 3, 26
    weight = dist.point(lambda d: 255 if d <= near else 0 if d >= far
                        else round(255 * (far - d) / (far - near)))
    if shield is not None:
        weight = ImageChops.subtract(weight, shield)
    w3 = Image.merge("RGB", (weight, weight, weight))
    up = ImageChops.multiply(ImageChops.subtract(glass, flat), w3)
    down = ImageChops.multiply(ImageChops.subtract(flat, glass), w3)
    out = ImageChops.subtract(ImageChops.add(img.convert("RGB"), up), down)
    return out


# -------------------------------------------------------------- wallpaper

def _mix(a, b, t):
    return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t)


WALLPAPERS = {
    # A sky gradient, then dunes stacked back to front: each is the field
    # below a gentle curve (base y + sine waves), lit at its crest and
    # deepening below, with a faint glow above the crest. Glows are large
    # soft colour fields laid over everything: colour, centre x (0..1.6, the
    # canvas aspect), centre y, spread x, spread y, strength.
    "dark": dict(
        top=(14, 15, 21), bottom=(10, 12, 26), right=(13, 14, 30),
        dunes=[  # base, waves, crest left, crest right, deep, depth, edge, glow
            (0.41, [(0.08, 0.45, 0.10), (0.02, 1.2, 0.5)], (28, 31, 84), (50, 40, 118), (13, 14, 34), 0.30, 0.006, 0.10),
            (0.62, [(-0.10, 0.32, 0.40), (0.02, 1.0, 0.1)], (18, 42, 112), (28, 50, 134), (10, 12, 30), 0.28, 0.006, 0.12),
            (0.85, [(0.07, 0.60, 0.55), (0.015, 1.4, 0.3)], (28, 30, 90), (46, 38, 116), (7, 9, 20), 0.24, 0.006, 0.12),
        ],
        glows=[
            ((70, 48, 158), 1.58, 0.02, 0.50, 0.40, 0.34),
            ((18, 52, 150), 0.00, 1.00, 0.55, 0.40, 0.25),
            ((26, 40, 118), 0.00, 0.30, 0.55, 0.50, 0.32),
        ],
    ),
    "light": dict(
        top=(240, 244, 252), bottom=(248, 246, 250), right=(246, 243, 252),
        dunes=[
            (0.41, [(0.08, 0.45, 0.10), (0.02, 1.2, 0.5)], (232, 236, 253), (240, 230, 252), (204, 212, 244), 0.34, 0.006, 0.30),
            (0.62, [(-0.10, 0.32, 0.40), (0.02, 1.0, 0.1)], (246, 238, 252), (255, 236, 228), (214, 204, 240), 0.30, 0.006, 0.35),
            (0.85, [(0.07, 0.60, 0.55), (0.015, 1.4, 0.3)], (250, 250, 255), (255, 242, 234), (226, 214, 238), 0.26, 0.006, 0.35),
        ],
        glows=[
            ((176, 204, 248), 0.10, 0.28, 0.60, 0.42, 0.55),
            ((210, 192, 246), 1.20, 0.22, 0.55, 0.36, 0.45),
            ((255, 206, 186), 1.45, 1.00, 0.50, 0.36, 0.55),
        ],
    ),
}


def wallpaper(theme: str) -> Image.Image:
    """Evaluated small in float, upscaled smoothly, then dithered with fine
    grain before quantising so the gradients never band."""
    spec = WALLPAPERS[theme]
    lw, lh = 640, 400
    aspect = W / H
    chans = [array("f"), array("f"), array("f")]
    for j in range(lh):
        v = (j + 0.5) / lh
        for i in range(lw):
            u = (i + 0.5) / lw
            x = u * aspect
            col = _mix(spec["top"], spec["bottom"], smoothstep(0, 1, v))
            col = _mix(col, spec["right"], 0.6 * smoothstep(0.2, 1.0, u))
            for base, waves, cl, cr, deep, depth, edge, glow in spec["dunes"]:
                cy = base + sum(a * math.sin(2 * math.pi * (f * u + p)) for a, f, p in waves)
                d = v - cy
                crest = _mix(cl, cr, smoothstep(0, 1, u))
                if d < 0:  # light spilling above the crest
                    col = _mix(col, crest, glow * math.exp(d / 0.045))
                inside = smoothstep(-edge, edge, d)
                if inside > 0:
                    shade = _mix(crest, deep, smoothstep(0, depth, d) ** 0.8)
                    col = _mix(col, shade, inside)
            for gc, gx, gy, sx, sy, k in spec["glows"]:
                g = math.exp(-(((x - gx) / sx) ** 2 + ((v - gy) / sy) ** 2))
                col = _mix(col, gc, g * k)
            for c in range(3):
                chans[c].append(col[c])
    small = [Image.frombytes("F", (lw, lh), ch.tobytes()) for ch in chans]
    out = []
    for ch in small:
        big = ch.resize((W, H), Image.Resampling.BICUBIC)
        grain = Image.effect_noise((W, H), 1.2).convert("F")
        big = ImageMath.lambda_eval(lambda a: a["c"] + a["n"] - 127.0, c=big, n=grain)
        out.append(big.convert("L"))
    return Image.merge("RGB", out)


# ---------------------------------------------------------------- menu bar

def sway_glyph_mask(scale: float) -> Image.Image:
    """SwayGlyph from Sway/AppPresentation.swift: 19x16 pt template image."""
    k = scale * SS
    m = Image.new("L", (round(19 * k), round(16 * k)), 0)
    d = ImageDraw.Draw(m)

    def rect(x, y, w, h, r, **kw):  # AppKit coords are bottom-up
        top = 16 - (y + h)
        d.rounded_rectangle((x * k, top * k, (x + w) * k, (top + h) * k), radius=r * k, **kw)

    lw = 1.4
    rect(1 + lw / 2, 2.25 + lw / 2, 17 - lw, 11.5 - lw, 3.4 - lw / 2, outline=255, width=round(lw * k))
    rect(3.7, 4.5, 2.2, 7, 1.1, fill=round(255 * 0.35))
    rect(12.9, 4.5, 2.4, 7, 1.2, fill=255)
    return m.resize((round(19 * scale), round(16 * scale)), Image.Resampling.BOX)


def battery_mask(scale: float) -> Image.Image:
    k = scale * SS
    w, h = 27.5, 13
    m = Image.new("L", (round(w * k), round(h * k)), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle((0.5 * k, 0.5 * k, 24.5 * k, 12.5 * k), radius=3.8 * k,
                        outline=round(255 * 0.45), width=round(1.0 * k))
    d.rounded_rectangle((2.5 * k, 2.5 * k, (2.5 + 17.5) * k, 10.5 * k), radius=1.9 * k, fill=255)
    d.rounded_rectangle((25.4 * k, 4.4 * k, 27.2 * k, 8.6 * k), radius=0.9 * k, fill=round(255 * 0.45))
    return m.resize((round(w * scale), round(h * scale)), Image.Resampling.BOX)


def wifi_mask(scale: float) -> Image.Image:
    k = scale * SS
    w, h = 17, 13
    m = Image.new("L", (round(w * k), round(h * k)), 0)
    d = ImageDraw.Draw(m)
    cx, cy = 8.5 * k, 12.2 * k
    lw = 1.75 * k
    for r in (10.2, 6.3):
        rk = r * k
        a0, a1 = 225, 315
        d.arc((cx - rk, cy - rk, cx + rk, cy + rk), a0, a1, fill=255, width=round(lw))
        for a in (a0, a1):  # round caps
            mid = rk - lw / 2
            px_, py_ = cx + mid * math.cos(math.radians(a)), cy + mid * math.sin(math.radians(a))
            d.ellipse((px_ - lw / 2, py_ - lw / 2, px_ + lw / 2, py_ + lw / 2), fill=255)
    # The bottom wedge, its corners rounded by blur-and-threshold.
    wedge = Image.new("L", m.size, 0)
    rk = 3.6 * k
    ImageDraw.Draw(wedge).pieslice((cx - rk, cy - rk + 0.2 * k, cx + rk, cy + rk + 0.2 * k), 225, 315, fill=255)
    wedge = wedge.filter(ImageFilter.GaussianBlur(0.5 * k)).point(lambda v: 255 if v > 150 else 0)
    m = ImageChops.lighter(m, wedge)
    return m.resize((round(w * scale), round(h * scale)), Image.Resampling.BOX)


def control_centre_mask(scale: float) -> Image.Image:
    k = scale * SS
    w, h = 16, 14
    m = Image.new("L", (round(w * k), round(h * k)), 0)
    d = ImageDraw.Draw(m)
    lw = round(1.2 * k)
    for top, knob_left in ((0.6, False), (7.6, True)):
        d.rounded_rectangle((0.6 * k, top * k, 15.4 * k, (top + 5.8) * k), radius=2.9 * k, outline=255, width=lw)
        kx = 3.5 if knob_left else 12.5
        d.ellipse(((kx - 2.1) * k, (top + 0.8) * k, (kx + 2.1) * k, (top + 5.0) * k), fill=255)
    return m.resize((round(w * scale), round(h * scale)), Image.Resampling.BOX)


def menu_bar(canvas: Image.Image, blurred: Image.Image, t: dict) -> int:
    """Draws the bar into canvas; returns the Kinara status item's centre x."""
    bar = Image.blend(blurred.crop((0, 0, W, BAR_H)), solid(t["bar_tint"], (W, BAR_H)), t["bar_alpha"])
    ink = Image.new("L", (W, BAR_H), 0)
    d = ImageDraw.Draw(ink)
    baseline = 33
    regular, bold = font(26, 400), font(26, 700)

    def stamp(mask: Image.Image, x: int, y: int) -> None:
        box = (x, y, x + mask.width, y + mask.height)
        ink.paste(ImageChops.lighter(ink.crop(box), mask), box[:2])

    # Left: Kinara's own menus (Sway/SwayApp.swift). The Apple menu is left
    # out on purpose: Apple's marketing guidelines don't allow its logo.
    x = 34
    for i, label in enumerate(["Kinara", "File", "Edit", "Window"]):
        f = bold if i == 0 else regular
        d.text((x, baseline), label, font=f, fill=255, anchor="ls")
        x += f.getlength(label) + 44

    # Right, laid out right to left: clock, Control Centre, Wi-Fi, battery, Kinara.
    right = W - 30
    clock = "Mon 9:41"
    d.text((right, baseline), clock, font=regular, fill=255, anchor="rs")
    x = round(right - regular.getlength(clock) - 34)
    for make in (control_centre_mask, wifi_mask, battery_mask):
        g = make(2.0)
        x -= g.width
        stamp(g, x, (BAR_H - g.height) // 2)
        x -= 34
    glyph = sway_glyph_mask(2.0)
    gx = x - glyph.width - 4
    stamp(glyph, gx, (BAR_H - glyph.height) // 2)

    # The open status item's highlight, a rounded pill behind the glyph.
    pad, hh = 14, 40
    pill = Image.new("L", ((glyph.width + 2 * pad) * SS, hh * SS), 0)
    ImageDraw.Draw(pill).rounded_rectangle((0, 0, pill.width - 1, pill.height - 1), radius=10 * SS, fill=255)
    hl = Image.new("L", (W, BAR_H), 0)
    hl.paste(pill.resize((glyph.width + 2 * pad, hh), Image.Resampling.BOX), (gx - pad, (BAR_H - hh) // 2))
    hc = t["highlight"]
    bar = tint(bar, hc[:3], hl, hc[3])
    bar = tint(bar, t["ink"], ink, t["ink_alpha"])
    canvas.paste(bar, (0, 0))
    return gx + glyph.width // 2


# ---------------------------------------------------------------- windows

def traffic_lights():
    """The three window buttons where AppKit puts them over Kinara's unified
    toolbar (measured from build/UIRender/sway-settings-window-*.png): 14 pt
    circles, 23 pt apart, centred 25.75 pt from the top-left corner.
    Yields (fill mask, edge mask, top-left, fill colour, edge colour)."""
    colors = [((255, 95, 87), (224, 68, 62)), ((254, 188, 46), (222, 161, 35)), ((40, 200, 64), (29, 173, 43))]
    r, c = 14, 32.5
    for i, (fill, edge) in enumerate(colors):
        cx, cy = 51.5 + 46 * i, 51.5
        m = Image.new("L", (64 * SS, 64 * SS), 0)
        e = Image.new("L", m.size, 0)
        box = ((c - r) * SS, (c - r) * SS, (c + r) * SS, (c + r) * SS)
        ImageDraw.Draw(m).ellipse(box, fill=255)
        ImageDraw.Draw(e).ellipse(box, outline=255, width=SS)
        yield (m.resize((64, 64), Image.Resampling.BOX), e.resize((64, 64), Image.Resampling.BOX),
               (round(cx - c), round(cy - c)), fill, edge)


def build_window(theme: str, behind: Image.Image, origin: tuple[int, int], t: dict,
                 sidebar_glass: bool) -> tuple[Image.Image, Image.Image]:
    src = Image.open(RENDERS / f"sway-settings-sound-{theme}.png").convert("RGB")
    box = detect_bounds(src)
    content = src.crop(box)
    cw, ch = content.size

    # The sidebar is everything left of the Divider; the divider is the
    # first column, scanning right, whose colour runs unbroken top to bottom.
    px = content.load()
    sidebar_bg = most_common(content.crop((0, 0, min(400, cw), ch)))
    divider_x = None
    for x in range(200, min(700, cw)):
        c = px[x, ch // 2]
        if c != sidebar_bg and all(px[x, y] == c for y in range(0, ch, 7)):
            divider_x = x
            break

    # The content runs under a transparent title bar (fullSizeContentView), so
    # the render is the whole window and the sidebar already reaches the top.
    win = content.copy()
    if sidebar_glass:
        ox, oy = origin
        region = behind.crop((ox, oy, ox + divider_x, oy + win.height))
        side = win.crop((0, 0, divider_x, win.height))
        # Kinara's app icon beside its switch in the sidebar (content coords, 2x).
        shield = icon_shield(side, sidebar_bg, [(20, 180, 100, 260)])
        win.paste(frost(side, region, sidebar_bg, t["glass_mix"], shield=shield), (0, 0))

    # No title: the window hides it, as System Settings does.
    for m, e, pos, fill, edge in traffic_lights():
        layer = win.crop((pos[0], pos[1], pos[0] + 64, pos[1] + 64))
        layer = tint(layer, fill, m)
        layer = tint(layer, edge, e, 0.9)
        win.paste(layer, pos)

    mask = rounded_mask(win.size, WINDOW_RADIUS)
    hc = t["hairline"]
    win = tint(win, hc[:3], ring_mask(win.size, WINDOW_RADIUS, 2.0), hc[3])
    return win, mask


def build_panel(theme: str) -> tuple[Image.Image, tuple]:
    # The reduced-transparency render is the same popover on a flat
    # background, with the right label colours. The default render is the
    # broken offscreen glass (dark text on dark, white-on-white controls).
    src = Image.open(RENDERS / f"sway-menu-{theme}-reduced-transparency.png").convert("RGB")
    box = detect_bounds(src)
    panel = src.crop(box)
    bg = most_common(panel)
    # The render clips to its own 20 pt corners over the grey padding; square
    # the corners off with the background before our own mask is applied.
    pw, ph = panel.size
    src_r = 40
    px = panel.load()
    for cx, cy, xs, ys in ((src_r, src_r, range(0, src_r), range(0, src_r)),
                           (pw - src_r - 1, src_r, range(pw - src_r, pw), range(0, src_r)),
                           (src_r, ph - src_r - 1, range(0, src_r), range(ph - src_r, ph)),
                           (pw - src_r - 1, ph - src_r - 1, range(pw - src_r, pw), range(ph - src_r, ph))):
        for y in ys:
            for x in xs:
                if math.hypot(x - cx, y - cy) > src_r - 3:
                    px[x, y] = bg
    return panel, bg


# Where the popover's app icons sit (panel coords, 2x): Sway's own icon in
# the header, then the four apps in the mixer list. Boxes hold only the icon.
PANEL_ICON_BOXES = [(20, 20, 110, 110)] + [(22, y, 90, y + 65) for y in (455, 565, 675, 785)]


def drop_shadow(canvas: Image.Image, shape: Image.Image, origin, layers) -> Image.Image:
    """layers: (dx, dy, blur, alpha, spread)."""
    for dx, dy, blur, alpha, spread in layers:
        m = Image.new("L", (W, H), 0)
        s = shape
        if spread:
            s = shape.filter(ImageFilter.MaxFilter(spread * 2 + 1))
        m.paste(s, (origin[0] + dx, origin[1] + dy))
        if blur:
            m = m.filter(ImageFilter.GaussianBlur(blur))
        canvas = tint(canvas, (0, 0, 0), m, alpha)
    return canvas


# ---------------------------------------------------------------- compose

def compose(theme: str, sidebar_glass: bool = True) -> Image.Image:
    t = THEMES[theme]
    wall = wallpaper(theme)
    wall_blur = wall.filter(ImageFilter.GaussianBlur(GLASS_BLUR))
    canvas = wall.copy()

    # Menu bar first, to learn where Kinara's status item sits.
    item_cx = menu_bar(canvas, wall.filter(ImageFilter.GaussianBlur(30)), t)

    panel, panel_bg = build_panel(theme)
    pw, ph = panel.size
    px0 = min(item_cx - pw // 2, W - 40 - pw)   # NSPopover centres on its item
    py0 = BAR_H + PANEL_GAP

    # Settings window: left of centre, vertically centred under the bar,
    # its right edge tucked a little under the popover.
    probe = Image.open(RENDERS / f"sway-settings-sound-{theme}.png")
    b = detect_bounds(probe)
    ww, wh = b[2] - b[0], b[3] - b[1]
    wx0 = px0 + 52 - ww
    wy0 = BAR_H + (H - BAR_H - wh) // 2
    window, wmask = build_window(theme, wall_blur, (wx0, wy0), t, sidebar_glass)

    canvas = drop_shadow(canvas, wmask, (wx0, wy0), [
        (0, 30, 40, t["shadow_alpha"], 0),
        (0, 4, 6, t["contact_alpha"], 0),
    ])
    if t["outline"]:
        oc = t["outline"]
        ring = ring_mask(window.size, WINDOW_RADIUS, 1.5, outward=True)
        m = Image.new("L", (W, H), 0)
        m.paste(ring, (wx0 - 4, wy0 - 4))
        canvas = tint(canvas, oc[:3], m, oc[3])
    canvas.paste(window, (wx0, wy0), wmask)

    # Popover: frosted with whatever is behind it now (desktop and window edge).
    behind = canvas.filter(ImageFilter.GaussianBlur(GLASS_BLUR)).crop((px0, py0, px0 + pw, py0 + ph))
    panel = frost(panel, behind, panel_bg, t["glass_mix"], shield=icon_shield(panel, panel_bg, PANEL_ICON_BOXES))
    pmask = rounded_mask(panel.size, PANEL_RADIUS)
    hc = t["hairline"]
    panel = tint(panel, hc[:3], ring_mask(panel.size, PANEL_RADIUS, 2.0), hc[3])
    canvas = drop_shadow(canvas, pmask, (px0, py0), [
        (0, 22, 30, t["panel_shadow_alpha"], 0),
        (0, 3, 4, t["contact_alpha"], 0),
    ])
    if t["outline"]:
        oc = t["outline"]
        ring = ring_mask(panel.size, PANEL_RADIUS, 1.5, outward=True)
        m = Image.new("L", (W, H), 0)
        m.paste(ring, (px0 - 4, py0 - 4))
        canvas = tint(canvas, oc[:3], m, oc[3])
    canvas.paste(panel, (px0, py0), pmask)
    return canvas


# ------------------------------------------------------------ audio picker

PICKER_RADIUS = 44         # 22 pt, the picker's own corner
PICKER_CROP = (1240, 960)  # the shot: the picker with a little desktop around it


def build_picker(theme: str) -> tuple[Image.Image, tuple]:
    """The reduced-transparency render of the audio picker, cropped to its
    surface: 16 pt of backdrop plus 24 pt of shadow room on every side."""
    src = Image.open(RENDERS / f"sway-audio-picker-{theme}.png").convert("RGB")
    m = 80
    panel = src.crop((m, m, src.width - m, src.height - m))
    return panel, most_common(panel)


def picker_icon_boxes(panel: Image.Image, bg) -> list[tuple[int, int, int, int]]:
    """App icons sit in one column (28 to 54 pt from the left); find each by
    the rows where that column differs clearly from the background."""
    x0, x1 = 50, 114
    column = bg_distance(panel.crop((x0, 0, x1, panel.height)), bg).point(lambda d: 255 if d > 40 else 0)
    rows = [any(column.getpixel((x, y)) for x in range(0, x1 - x0, 2)) for y in range(panel.height)]
    boxes, start = [], None
    for y, on in enumerate(rows + [False]):
        if on and start is None:
            start = y
        elif not on and start is not None:
            if y - start > 30:  # an icon, not a hairline or a glyph
                boxes.append((x0 - 4, max(0, start - 4), x1 + 4, min(panel.height, y + 4)))
            start = None
    return boxes


def compose_picker(theme: str) -> Image.Image:
    t = THEMES[theme]
    canvas = wallpaper(theme)
    panel, bg = build_picker(theme)
    pw, ph = panel.size
    # Where the picker opens: a little above the middle of the screen.
    px0, py0 = (W - pw) // 2 + 160, (H - ph) // 2 - 40
    behind = canvas.filter(ImageFilter.GaussianBlur(GLASS_BLUR)).crop((px0, py0, px0 + pw, py0 + ph))
    panel = frost(panel, behind, bg, t["glass_mix"], shield=icon_shield(panel, bg, picker_icon_boxes(panel, bg)))
    pmask = rounded_mask(panel.size, PICKER_RADIUS)
    hc = t["hairline"]
    panel = tint(panel, hc[:3], ring_mask(panel.size, PICKER_RADIUS, 2.0), hc[3])
    canvas = drop_shadow(canvas, pmask, (px0, py0), [
        (0, 26, 36, t["panel_shadow_alpha"], 0),
        (0, 3, 4, t["contact_alpha"], 0),
    ])
    if t["outline"]:
        oc = t["outline"]
        ring = ring_mask(panel.size, PICKER_RADIUS, 1.5, outward=True)
        m = Image.new("L", (W, H), 0)
        m.paste(ring, (px0 - 4, py0 - 4))
        canvas = tint(canvas, oc[:3], m, oc[3])
    canvas.paste(panel, (px0, py0), pmask)
    cw, ch = PICKER_CROP
    cx0, cy0 = px0 + pw // 2 - cw // 2, py0 + ph // 2 - ch // 2
    return canvas.crop((cx0, cy0, cx0 + cw, cy0 + ch))


def encode(img: Image.Image, stem: str, out_dir: Path, quality: int = 88) -> list[Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    webp = out_dir / f"{stem}.webp"
    jpg = out_dir / f"{stem}.jpg"
    cwebp = shutil.which("cwebp") or ("/opt/homebrew/bin/cwebp" if os.path.exists("/opt/homebrew/bin/cwebp") else None)
    if cwebp:
        with tempfile.TemporaryDirectory() as tmp:
            png = Path(tmp) / "in.png"
            img.save(png, compress_level=1)
            subprocess.run([cwebp, "-quiet", "-q", str(quality), "-m", "6", "-sharp_yuv",
                            "-metadata", "none", str(png), "-o", str(webp)], check=True)
    else:
        img.save(webp, "WEBP", quality=quality, method=6)
    img.save(jpg, "JPEG", quality=quality, optimize=True, progressive=True)
    return [webp, jpg]


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--theme", choices=["dark", "light", "both"], default="both")
    ap.add_argument("--opaque-sidebar", action="store_true",
                    help="keep the sidebar opaque, as the shipping app draws it")
    ap.add_argument("--out-dir", type=Path, default=OUT_DIR, help="where the .webp and .jpg go")
    ap.add_argument("--debug-dir", type=Path, help="also write lossless PNGs here")
    ap.add_argument("--shot", choices=["desktop", "picker"], default="desktop",
                    help="the settings and menu desktop, or the audio picker")
    args = ap.parse_args()
    themes = ["dark", "light"] if args.theme == "both" else [args.theme]
    for theme in themes:
        if args.shot == "picker":
            img = compose_picker(theme)
            if args.debug_dir:
                args.debug_dir.mkdir(parents=True, exist_ok=True)
                img.save(args.debug_dir / f"audio-picker-{theme}.png", compress_level=1)
            for p in encode(img, f"audio-picker-{theme}", args.out_dir):
                print(f"{p}  {p.stat().st_size / 1024:.0f} KB")
            continue
        img = compose(theme, sidebar_glass=not args.opaque_sidebar)
        if args.debug_dir:
            args.debug_dir.mkdir(parents=True, exist_ok=True)
            img.save(args.debug_dir / f"desktop-{theme}.png", compress_level=1)
        for p in encode(img, f"desktop-{theme}", args.out_dir):
            print(f"{p}  {p.stat().st_size / 1024:.0f} KB")


if __name__ == "__main__":
    main()
