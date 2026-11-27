"""Renders docs/images/social-preview.png (1280x640), used as the repository's social preview
and as the Open Graph image of the project page. Run from the repository root:

    swift docs/icon/generate-icon.swift /tmp/cs-icon && python3 docs/make_social.py /tmp/cs-icon/icon-1024.png
"""
import sys
from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 640
FONT = "/System/Library/Fonts/SFNS.ttf"


def font(size, weight):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_name(weight)
    except Exception:
        pass
    return f


def gradient():
    top, bottom = (0x1E, 0x8F, 0xB3), (0x0B, 0x25, 0x45)
    img = Image.new("RGB", (W, H))
    px = img.load()
    for y in range(H):
        for x in range(W):
            t = min(1.0, max(0.0, (0.75 * y / H + 0.25 * x / W)))
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom))
    return img


img = gradient()
icon = Image.open(sys.argv[1]).convert("RGBA").resize((400, 400), Image.LANCZOS)
img.paste(icon, (70, 120), icon)

d = ImageDraw.Draw(img)
x = 500
d.text((x, 150), "ChargeSurf", font=font(92, "Bold"), fill=(255, 255, 255))
d.text((x, 268), "Free battery charge limiter", font=font(44, "Semibold"), fill=(255, 255, 255))
d.text((x, 322), "for MacBooks on macOS 27", font=font(44, "Semibold"), fill=(255, 255, 255))
muted = (200, 228, 238)
for i, line in enumerate(["60-80% range, sailing on adapter power",
                          "Heat protection, menu bar app",
                          "Open source (GPL-2.0)"]):
    d.text((x, 410 + i * 42), line, font=font(30, "Regular"), fill=muted)

out = "docs/images/social-preview.png"
img.save(out, optimize=True)
print("wrote", out)
