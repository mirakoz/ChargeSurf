#!/usr/bin/env python3
"""Builds the README images in docs/images from app renders (see docs/make-images.sh).

usage: python3 docs/make_images.py <shots dir> <out dir>
Needs Pillow. Fonts: San Francisco from /System/Library/Fonts (macOS).
"""
import math
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

SHOTS, OUT = Path(sys.argv[1]), Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)
SF = "/System/Library/Fonts/SFNS.ttf"


def font(size, weight="Regular"):
    f = ImageFont.truetype(SF, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def shot(name):
    return Image.open(SHOTS / f"{name}.png").convert("RGBA")


def rounded(im, r):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.width - 1, im.height - 1], r, fill=255)
    out = im.copy()
    out.putalpha(ImageChops.multiply(out.getchannel("A"), mask))
    return out


def paste_with_shadow(canvas, im, xy, radius=22, blur=28, offset=(0, 14), alpha=110):
    x, y = xy
    sh = Image.new("RGBA", (im.width + blur * 4, im.height + blur * 4), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle(
        [blur * 2, blur * 2, blur * 2 + im.width, blur * 2 + im.height], radius, fill=(0, 0, 0, alpha))
    sh = sh.filter(ImageFilter.GaussianBlur(blur))
    canvas.alpha_composite(sh, (x - blur * 2 + offset[0], y - blur * 2 + offset[1]))
    canvas.alpha_composite(rounded(im, radius), (x, y))


def vgradient(size, top, bottom):
    w, h = size
    g = Image.new("RGBA", (1, h))
    for i in range(h):
        t = i / (h - 1)
        g.putpixel((0, i), tuple(int(top[k] + (bottom[k] - top[k]) * t) for k in range(3)) + (255,))
    return g.resize((w, h))


def waves(canvas, y0, color, count=4, amp=14, gap=26, alpha=40, width=3):
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    W = canvas.width
    for k in range(count):
        pts = [(x, y0 + k * gap + amp * math.sin(x / 140 + k * 0.9)) for x in range(0, W + 8, 8)]
        d.line(pts, fill=color + (alpha - k * 6,), width=width)
    canvas.alpha_composite(layer)


# ---------------------------------------------------------------- hero

def hero():
    W, H = 1760, 900
    c = vgradient((W, H), (9, 30, 66), (17, 104, 128))
    waves(c, 760, (255, 255, 255), count=5, alpha=46)
    ov = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    o = ImageDraw.Draw(ov)   # translucent shapes, composited before the text
    d = ImageDraw.Draw(c)

    # macOS-style menu bar
    d.rectangle([0, 0, W, 48], fill=(238, 240, 244))
    label = shot("menubar-sailing-light")
    lx = W - 34 - 140 - label.width
    d.rounded_rectangle([lx - 8, 6, lx + label.width + 8, 42], 9, fill=(214, 217, 223))

    # panel under the menu bar item
    panel = shot("main-sailing-light")
    s = 0.72
    panel = panel.resize((int(panel.width * s), int(panel.height * s)), Image.LANCZOS)
    px = min(lx + label.width // 2 - panel.width // 2, W - panel.width - 40)

    # title block
    x = 110
    d.text((x, 250), "ChargeSurf", font=font(104, "Bold"), fill=(255, 255, 255))
    d.text((x, 385), "Battery charge surfing and heat protection", font=font(40, "Medium"), fill=(220, 236, 245))
    d.text((x, 437), "for Apple Silicon MacBooks on macOS 27", font=font(40, "Medium"), fill=(220, 236, 245))
    chip_pos = []
    chips = ["60–80% surfing", "Sails on adapter power", "Heat cutoff", "Menu bar app"]
    cx, cy = x, 530
    f = font(27, "Semibold")
    for t in chips:
        w = d.textlength(t, font=f)
        if cx + w + 40 > px - 50:
            cx, cy = x, cy + 62
        o.rounded_rectangle([cx, cy, cx + w + 36, cy + 48], 24, fill=(255, 255, 255, 34), outline=(255, 255, 255, 80), width=2)
        chip_pos.append((cx + 18, cy + 24, t))
        cx += w + 52
    c.alpha_composite(ov)
    d = ImageDraw.Draw(c)
    c.alpha_composite(label, (lx, 24 - label.height // 2))
    paste_with_shadow(c, panel, (px, 62), radius=20)
    d.text((W - 34, 24), "Thu 18:30", font=font(25, "Medium"), fill=(25, 25, 25), anchor="rm")
    for tx, ty, t in chip_pos:
        d.text((tx, ty), t, font=f, fill=(255, 255, 255), anchor="lm")
    d.text((x, cy + 100), "Open source · GPL-2.0 · experimental", font=font(26), fill=(170, 205, 220))
    c.convert("RGB").save(OUT / "hero.png", optimize=True)


# ---------------------------------------------------------------- states grid

def states(theme):
    names = [("sailing", "Sailing on adapter power"), ("battery", "On battery, time left"),
             ("charging", "Charging to the upper limit"), ("heat", "Heat protection")]
    dark = theme == "dark"
    bg = (13, 17, 23, 255) if dark else (255, 255, 255, 255)
    fg = (230, 237, 243) if dark else (31, 35, 40)
    sub = (139, 148, 158) if dark else (101, 109, 118)
    panels = [shot(f"main-{n}-{theme}") for n, _ in names]
    labels = [shot(f"menubar-{n}-{theme}") for n, _ in names]
    s = 0.8
    panels = [p.resize((int(p.width * s), int(p.height * s)), Image.LANCZOS) for p in panels]
    pw = max(p.width for p in panels)
    ph = max(p.height for p in panels)
    gap, top = 56, 150
    W = gap + len(panels) * (pw + gap)
    H = top + ph + 70
    c = Image.new("RGBA", (W, H), bg)
    d = ImageDraw.Draw(c)
    for i, ((n, title), p, lab) in enumerate(zip(names, panels, labels)):
        x = gap + i * (pw + gap)
        d.text((x + pw // 2, 34), title, font=font(30, "Semibold"), fill=fg, anchor="mt")
        bar = (44, 48, 54) if dark else (236, 236, 239)
        d.rounded_rectangle([x, 86, x + pw, 132], 12, fill=bar)
        c.alpha_composite(lab, (x + pw // 2 - lab.width // 2, 109 - lab.height // 2))
        paste_with_shadow(c, p, (x, top), radius=18, blur=16, offset=(0, 6), alpha=60 if not dark else 140)
    d.text((W // 2, H - 30), "Rendered from the app with sample values", font=font(22), fill=sub, anchor="mb")
    c.convert("RGB").save(OUT / f"states-{theme}.png", optimize=True)


def settings_onboarding(theme):
    dark = theme == "dark"
    bg = (13, 17, 23, 255) if dark else (255, 255, 255, 255)
    fg = (230, 237, 243) if dark else (31, 35, 40)
    st, ob = shot(f"settings-{theme}"), shot(f"onboarding-{theme}")
    gap, top = 56, 96
    W = gap * 3 + st.width + ob.width
    H = top + max(st.height, ob.height) + gap
    c = Image.new("RGBA", (W, H), bg)
    d = ImageDraw.Draw(c)
    d.text((gap + st.width // 2, 36), "Settings: what the menu bar shows", font=font(30, "Semibold"), fill=fg, anchor="mt")
    d.text((gap * 2 + st.width + ob.width // 2, 36), "Setup guide on first launch", font=font(30, "Semibold"), fill=fg, anchor="mt")
    a = 60 if not dark else 140
    paste_with_shadow(c, st, (gap, top), radius=18, blur=16, offset=(0, 6), alpha=a)
    paste_with_shadow(c, ob, (gap * 2 + st.width, top), radius=18, blur=16, offset=(0, 6), alpha=a)
    c.convert("RGB").save(OUT / f"settings-guide-{theme}.png", optimize=True)


def power(theme, name="power", title="The Power tab", notes=None):
    dark = theme == "dark"
    bg = (13, 17, 23, 255) if dark else (255, 255, 255, 255)
    fg = (230, 237, 243) if dark else (31, 35, 40)
    sub = (139, 148, 158) if dark else (101, 109, 118)
    accent = (10, 132, 255)
    p = shot(f"{name}-{theme}")
    gap, top, tw = 64, 120, 600
    W = gap * 3 + p.width + tw
    H = top + p.height + gap
    c = Image.new("RGBA", (W, H), bg)
    d = ImageDraw.Draw(c)
    d.text((W // 2, 40), title, font=font(34, "Semibold"), fill=fg, anchor="mt")
    paste_with_shadow(c, p, (gap, top), radius=18, blur=16, offset=(0, 6), alpha=60 if not dark else 140)
    # (y on the 2x panel render, title, text)
    notes = notes or [
        (150, "Right now", ["What the Mac uses, and whether it comes", "from the adapter or the battery."]),
        (330, "Average use", ["Last hour and last 12 hours, from macOS's", "own energy counters, with a 12-hour chart."]),
        (900, "Charger checks", ["USB-PD voltage, headroom for your peak use,", "voltage steadiness and brand information.",
                                  "They cannot test safety or build quality."]),
    ]
    x0 = gap * 2 + p.width
    for y, title, lines in notes:
        y += top
        d.line([(gap + p.width + 10, y), (x0 - 18, y)], fill=accent + (255,), width=3)
        d.ellipse([x0 - 24, y - 6, x0 - 12, y + 6], fill=accent + (255,))
        d.text((x0, y), title, font=font(30, "Semibold"), fill=fg, anchor="lm")
        for i, line in enumerate(lines):
            d.text((x0, y + 30 + i * 32), line, font=font(24), fill=sub, anchor="lt")
    d.text((x0, H - gap), "Rendered from the app with sample values", font=font(22), fill=sub, anchor="ls")
    c.convert("RGB").save(OUT / f"{name}-{theme}.png", optimize=True)


def devices(theme):
    power(theme, "devices", "The Devices tab", [
        (150, "Power out", ["What the Mac gives out over USB-C,", "port by port, every minute."]),
        (310, "iPhone and iPad", ["Charge level, time to full, power into", "the battery, battery health and cycles.",
                                  "Needs Trust This Computer on the device."]),
        (500, "Accessories", ["Adapters and hubs are shown,", "but not counted as charging."]),
        (690, "AirPods", ["Case, left and right levels while the", "AirPods are connected to this Mac."]),
    ])


# ---------------------------------------------------------------- surfing animation

MODES = {
    "sail": ("Sailing", (10, 132, 255)),
    "batt": ("On battery", (142, 142, 147)),
    "charge": ("Charging", (48, 179, 87)),
    "heat": ("Heat protection", (255, 140, 0)),
}
# (duration in hours, end percent, mode, plugged in, caption)
STORY = [
    (1.0, 92, "sail", True, "After a top-up: plugged in above 80%, the battery is held, not drained"),
    (2.0, 71, "batt", False, "Unplugged: the Mac uses the battery as usual"),
    (1.5, 71, "sail", True, "Plugged in at 71%: sailing, the Mac runs from the adapter, no charging"),
    (1.4, 57, "batt", False, "Unplugged again, down to 57%"),
    (0.8, 66, "charge", True, "Below the 60% lower limit: charging starts, up to 80%"),
    (0.6, 66, "heat", True, "Battery reaches 35 °C: charging pauses until it cools to 32 °C"),
    (0.9, 80, "charge", True, "Cool again: charging continues to 80%"),
    (1.8, 80, "sail", True, "At 80%: sailing again until the battery drops below 60%"),
]


def surfing_gif():
    S = 2  # draw at 2x, downsample for smooth lines
    W, H = 960, 470
    L, R, T, B = 86, 40, 112, 58  # chart margins (1x)
    ymin, ymax = 50, 100
    total = sum(s[0] for s in STORY)
    start = 92

    def X(t): return (L + (W - L - R) * t / total) * S
    def Y(p): return (T + (H - T - B) * (ymax - p) / (ymax - ymin)) * S

    # sample the path: list of (t, pct, mode, plugged, caption)
    pts = []
    t, p = 0.0, start
    for dur, end, mode, plug, cap in STORY:
        n = max(int(dur * 14), 6)
        for i in range(1, n + 1):
            pts.append((t + dur * i / n, p + (end - p) * i / n, mode, plug, cap))
        t, p = t + dur, end
    first = (0.0, start, STORY[0][2], STORY[0][3], STORY[0][4])

    frames = []
    steps = list(range(0, len(pts) + 1, 2))
    if steps[-1] != len(pts):
        steps.append(len(pts))
    for k in steps:
        c = Image.new("RGB", (W * S, H * S), (255, 255, 255))
        d = ImageDraw.Draw(c, "RGBA")
        # band and limits
        d.rectangle([X(0), Y(80), X(total), Y(60)], fill=(10, 132, 255, 22))
        for lvl, txt in ((80, "upper 80%"), (60, "lower 60%")):
            for xx in range(int(X(0)), int(X(total)), 16 * S):
                d.line([xx, Y(lvl), xx + 8 * S, Y(lvl)], fill=(120, 130, 140), width=S)
            d.text((X(0) + 8 * S, Y(lvl) - 5 * S), txt, font=font(14 * S, "Medium"), fill=(110, 118, 128), anchor="lb")
        for lvl in (50, 60, 70, 80, 90, 100):
            d.text((X(0) - 12 * S, Y(lvl)), f"{lvl}%", font=font(14 * S), fill=(140, 146, 152), anchor="rm")
        d.line([X(0), Y(ymin), X(total), Y(ymin)], fill=(210, 214, 218), width=S)
        # path so far, coloured by mode
        seq = [first] + pts[:k]
        for a, b in zip(seq, seq[1:]):
            d.line([X(a[0]), Y(a[1]), X(b[0]), Y(b[1])], fill=MODES[b[2]][1], width=5 * S)
        cur = seq[-1]
        mode, plug, cap = cur[2], cur[3], cur[4]
        name, col = MODES[mode]
        r = 9 * S
        d.ellipse([X(cur[0]) - r, Y(cur[1]) - r, X(cur[0]) + r, Y(cur[1]) + r], fill=(255, 255, 255), outline=col, width=4 * S)
        # header: percent, mode pill, plug state, caption
        d.text((L * S, 22 * S), f"{round(cur[1])}%", font=font(42 * S, "Bold"), fill=(29, 29, 31), anchor="lt")
        hx = L * S + 118 * S
        pf = font(16 * S, "Semibold")
        pw = d.textlength(name, font=pf)
        d.rounded_rectangle([hx, 26 * S, hx + pw + 26 * S, 54 * S], 14 * S, fill=col + (38,))
        d.text((hx + 13 * S, 40 * S), name, font=pf, fill=tuple(int(v * 0.72) for v in col), anchor="lm")
        d.text((hx + pw + 40 * S, 40 * S), "Plugged in" if plug else "On battery", font=font(16 * S, "Medium"),
               fill=(90, 96, 104), anchor="lm")
        d.text((hx, 66 * S), cap, font=font(16 * S), fill=(60, 66, 74), anchor="lt")
        d.text(((W - R) * S, 30 * S), "ChargeSurf · 60–80% surfing", font=font(15 * S, "Medium"),
               fill=(150, 156, 162), anchor="rt")
        # legend
        lx = L * S
        for key in ("sail", "charge", "heat", "batt"):
            nm, cl = MODES[key]
            d.rounded_rectangle([lx, (H - 28) * S, lx + 18 * S, (H - 22) * S], 3 * S, fill=cl)
            d.text((lx + 24 * S, (H - 25) * S), nm, font=font(13 * S, "Medium"), fill=(110, 116, 124), anchor="lm")
            lx += d.textlength(nm, font=font(13 * S, "Medium")) + 52 * S
        d.text(((W - R) * S, (H - 25) * S), "time →", font=font(13 * S), fill=(150, 156, 162), anchor="rm")
        frames.append(c.resize((W, H), Image.LANCZOS))

    durations = [70] * len(frames)
    # pause at the end of each story step so the caption can be read
    t_edges, acc = [], 0.0
    for s_ in STORY:
        acc += s_[0]
        t_edges.append(acc)
    for i, k in enumerate(steps):
        if k and any(abs(pts[k - 1][0] - e) < 1e-6 for e in t_edges):
            durations[i] = 1600
    durations[-1] = 3500
    # one shared palette (from the last, complete frame) keeps colours stable across frames
    ref = frames[-1].quantize(colors=128, dither=Image.Dither.NONE)
    pal = [f.quantize(palette=ref, dither=Image.Dither.NONE) for f in frames]
    pal[0].save(OUT / "surfing.gif", save_all=True, append_images=pal[1:], duration=durations, loop=0,
                optimize=True, disposal=1)


if __name__ == "__main__":
    hero()
    for th in ("light", "dark"):
        states(th)
        settings_onboarding(th)
        power(th)
        devices(th)
    surfing_gif()
    for p in sorted(OUT.iterdir()):
        print(p.name, p.stat().st_size // 1024, "KB")
