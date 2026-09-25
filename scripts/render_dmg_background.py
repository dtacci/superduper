#!/usr/bin/env python3
"""Renders the DMG window background (assets/images/dmg-background*.png).

create-dmg places the app icon centered at (200, 185) and the Applications link
at (600, 185) in an 800x400 window, so the art stays out of those spots. Run
from the repo root: python3 scripts/render_dmg_background.py
"""
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
FONTS = ROOT / "SuperduperDictation" / "Resources" / "Fonts"
OUT = ROOT / "assets" / "images"

GROUND = (246, 244, 238)   # Library theme ground #F6F4EE
PAGE = (252, 251, 247)     # #FCFBF7
ACCENT = (31, 109, 83)     # #1F6D53
MINT = (111, 220, 175)     # #6FDCAF
INK_SOFT = (122, 116, 104)


def render(scale: int) -> Image.Image:
    width, height = 800 * scale, 400 * scale
    image = Image.new("RGB", (width, height), GROUND)

    # Soft paper gradient, lighter toward the center.
    glow = Image.new("L", (width, height), 0)
    ImageDraw.Draw(glow).ellipse(
        (int(-0.1 * width), int(-0.4 * height), int(1.1 * width), int(1.3 * height)), fill=255
    )
    glow = glow.filter(ImageFilter.GaussianBlur(120 * scale))
    image = Image.composite(Image.new("RGB", (width, height), PAGE), image, glow)

    # Faint mint halo behind the Applications drop target.
    halo = Image.new("L", (width, height), 0)
    r = 95 * scale
    ImageDraw.Draw(halo).ellipse((600 * scale - r, 185 * scale - r, 600 * scale + r, 185 * scale + r), fill=90)
    halo = halo.filter(ImageFilter.GaussianBlur(40 * scale))
    image = Image.composite(Image.new("RGB", (width, height), MINT), image, halo)

    draw = ImageDraw.Draw(image)

    # Dotted arc from the app icon to Applications, with an arrowhead.
    points = []
    steps = 22
    for i in range(steps + 1):
        t = i / steps
        x = (275 + (525 - 275) * t) * scale
        y = (185 - 34 * 4 * t * (1 - t)) * scale
        points.append((x, y))
    for i, (x, y) in enumerate(points[:-2]):
        dot = (2.6 if i % 2 == 0 else 2.0) * scale
        draw.ellipse((x - dot, y - dot, x + dot, y + dot), fill=ACCENT)
    tip_x, tip_y = points[-1]
    draw.polygon(
        [(tip_x, tip_y), (tip_x - 13 * scale, tip_y - 8 * scale), (tip_x - 11 * scale, tip_y + 7 * scale)],
        fill=ACCENT,
    )

    # Wordmark and instruction.
    wordmark = ImageFont.truetype(str(FONTS / "Newsreader-SemiBold.ttf"), 30 * scale)
    caption = ImageFont.truetype(str(FONTS / "Inter-Medium.ttf"), 15 * scale)
    small = ImageFont.truetype(str(FONTS / "Inter-Regular.ttf"), 12 * scale)

    def centered(text, font, y, fill):
        box = draw.textbbox((0, 0), text, font=font)
        draw.text(((width - (box[2] - box[0])) / 2, y), text, font=font, fill=fill)

    centered("Superduper Dictation", wordmark, 34 * scale, ACCENT)
    centered("Drag to Applications to install", caption, 300 * scale, ACCENT)
    centered("Local dictation for your Mac", small, 326 * scale, INK_SOFT)
    return image


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    render(1).save(OUT / "dmg-background.png")
    render(2).save(OUT / "dmg-background@2x.png")
    # One TIFF holding both sizes, so Finder shows the sharp one on Retina screens.
    subprocess.run(
        ["tiffutil", "-cathidpicheck", str(OUT / "dmg-background.png"), str(OUT / "dmg-background@2x.png"),
         "-out", str(OUT / "dmg-background.tiff")],
        check=True,
    )
    print("Wrote", OUT / "dmg-background.tiff")
