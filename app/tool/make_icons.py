#!/usr/bin/env python3
"""Draws the Nearby Live launcher icon (blue gradient square, white map pin,
cyan radar arcs) and writes every Android mipmap and iOS AppIcon size.

    python3 tool/make_icons.py        # run from app/
"""
import json
import math
import os

from PIL import Image, ImageDraw, ImageFilter

S = 1024  # master size


def master(rounded: bool) -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    # Vertical gradient #55B4FF → #1352E6 (the in-app icon badge).
    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    top, bottom = (0x55, 0xB4, 0xFF), (0x13, 0x52, 0xE6)
    for y in range(S):
        f = y / (S - 1)
        gd.line([(0, y), (S, y)], fill=tuple(int(top[i] + (bottom[i] - top[i]) * f) for i in range(3)) + (255,))
    mask = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(mask)
    if rounded:
        md.rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * .22), fill=255)
    else:
        md.rectangle([0, 0, S, S], fill=255)  # iOS applies its own mask
    img.paste(grad, (0, 0), mask)

    d = ImageDraw.Draw(img)
    cx, cy = S / 2, S * .47
    # Radar arcs (cyan, translucent) behind the pin.
    for i, r in enumerate((S * .30, S * .38)):
        d.arc([cx - r, cy - r * .55 + S * .2, cx + r, cy + r * .55 + S * .2], 200, 340,
              fill=(95, 240, 255, 150 - i * 50), width=int(S * .022))
    # Glow under the pin.
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([cx - S * .2, cy - S * .2, cx + S * .2, cy + S * .2], fill=(255, 255, 255, 90))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(S * .05)))
    # Map pin: circle head + pointed tail.
    r = S * .19
    tip = (cx, cy + S * .30)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(255, 255, 255, 255))
    a = math.radians(38)
    d.polygon([(cx - r * math.cos(a), cy + r * math.sin(a)), tip, (cx + r * math.cos(a), cy + r * math.sin(a))],
              fill=(255, 255, 255, 255))
    hole = r * .42
    d.ellipse([cx - hole, cy - hole, cx + hole, cy + hole], fill=(0x1F, 0x63, 0xEE, 255))
    return img


def main():
    os.makedirs("android/app/src/main/res", exist_ok=True)
    android = master(rounded=True)
    for folder, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
        android.resize((px, px), Image.LANCZOS).save(f"android/app/src/main/res/mipmap-{folder}/ic_launcher.png")

    ios = master(rounded=False).convert("RGB")  # App Store icons must be opaque
    base = "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    with open(f"{base}/Contents.json") as f:
        contents = json.load(f)
    for im in contents["images"]:
        size = float(im["size"].split("x")[0]) * int(im["scale"].rstrip("x"))
        ios.resize((round(size), round(size)), Image.LANCZOS).save(f"{base}/{im['filename']}")
    print("icons written")


if __name__ == "__main__":
    main()
