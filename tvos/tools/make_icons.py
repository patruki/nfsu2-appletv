#!/usr/bin/env python3
"""Generates tvos/app/Assets.xcassets: tvOS app icons (layered, as the App Store wants) and the
Top Shelf images.  The front layer is the game's logo (a transparent PNG, tvos/tools/nfsu2-logo.png or the
path given; the artwork is EA's: for personal use, never committed); without the file, the name in plain letters.
    .venv/bin/python tvos/tools/make_icons.py [logo.png]"""
import json
import os
import shutil
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

LOGO = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "nfsu2-logo.png")
ART = Image.open(LOGO).convert("RGBA") if os.path.exists(LOGO) else None

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "app", "Assets.xcassets")
BRAND = os.path.join(ROOT, "App Icon & Top Shelf Image.brandassets")
INFO = {"author": "xcode", "version": 1}
FONTS = ["/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/SFNS.ttf", "/Library/Fonts/Arial.ttf"]


def font(size):
    for f in FONTS:
        try:
            return ImageFont.truetype(f, size)
        except OSError:
            pass
    return ImageFont.load_default()


def back(w, h):
    """a dark night-road gradient"""
    im = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(im)
    for y in range(h):
        t = y / h
        d.line([(0, y), (w, y)], fill=(int(8 + 30 * t), int(10 + 14 * t), int(30 + 70 * t)))
    return im


def middle(w, h):
    """neon road lines converging to the horizon, transparent elsewhere"""
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    hy = int(h * 0.55)
    for i, c in enumerate([(0, 230, 255, 120), (255, 60, 200, 120)]):
        x0 = w * (0.18 if i == 0 else 0.82)
        d.line([(w / 2, hy), (x0, h)], fill=c, width=max(4, w // 70))
    d.line([(0, hy), (w, hy)], fill=(0, 230, 255, 200), width=max(2, w // 200))
    return im


def front(w, h):
    """the game's logo (or the name), centred"""
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if ART is not None:
        # as wide as the canvas allows (a small canvas, 400x240, has little room), smoothly resampled
        k = min(w * 0.78 / ART.width, h * 0.7 / ART.height)
        logo = ART.resize((round(ART.width * k), round(ART.height * k)), Image.LANCZOS)
        x, y = (w - logo.width) // 2, (h - logo.height) // 2
        shadow = Image.new("RGBA", logo.size, (0, 0, 0, 0))
        shadow.putalpha(logo.getchannel("A").point(lambda a: a * 180 // 255))
        shadow = shadow.filter(ImageFilter.GaussianBlur(max(2, h // 100)))
        im.alpha_composite(shadow, (x + max(2, h // 120), y + max(3, h // 100)))
        im.alpha_composite(logo, (x, y))
        return im
    f = font(int(h * 0.34))
    t = "NFSU2"
    b = d.textbbox((0, 0), t, font=f)
    d.text(((w - (b[2] - b[0])) / 2 - b[0], h * 0.18), t, font=f, fill=(255, 255, 255, 255))
    return im


def write(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    json.dump(obj, open(path, "w"), indent=2)


def stack(name, w, h):
    base = os.path.join(BRAND, name + ".imagestack")
    write(os.path.join(base, "Contents.json"), {"info": INFO, "layers": [
        {"filename": "Front.imagestacklayer"}, {"filename": "Middle.imagestacklayer"}, {"filename": "Back.imagestacklayer"}]})
    for layer, make in (("Front", front), ("Middle", middle), ("Back", back)):
        lb = os.path.join(base, layer + ".imagestacklayer")
        write(os.path.join(lb, "Contents.json"), {"info": INFO})
        iset = os.path.join(lb, "Content.imageset")
        os.makedirs(iset, exist_ok=True)
        imgs = []
        for sc in (1, 2):
            fn = "%s@%dx.png" % (layer.lower(), sc)
            make(w * sc, h * sc).save(os.path.join(iset, fn))
            imgs.append({"idiom": "tv", "filename": fn, "scale": "%dx" % sc})
        write(os.path.join(iset, "Contents.json"), {"images": imgs, "info": INFO})


def shelf(name, w, h):
    iset = os.path.join(BRAND, name + ".imageset")
    os.makedirs(iset, exist_ok=True)
    im = back(w, h).convert("RGBA")
    im.alpha_composite(middle(w, h))
    im.alpha_composite(front(w, h))
    imgs = []
    for sc in (1, 2):
        fn = "shelf@%dx.png" % sc
        im.resize((w * sc, h * sc)).convert("RGB").save(os.path.join(iset, fn))
        imgs.append({"idiom": "tv", "filename": fn, "scale": "%dx" % sc})
    write(os.path.join(iset, "Contents.json"), {"images": imgs, "info": INFO})


shutil.rmtree(ROOT, ignore_errors=True)
write(os.path.join(ROOT, "Contents.json"), {"info": INFO})
stack("App Icon - Large", 1280, 768)
stack("App Icon - Small", 400, 240)
shelf("Top Shelf Image", 1920, 720)
shelf("Top Shelf Image Wide", 2320, 720)
write(os.path.join(BRAND, "Contents.json"), {"assets": [
    {"filename": "App Icon - Large.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
    {"filename": "App Icon - Small.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
    {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
    {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"}], "info": INFO})
print("wrote", ROOT)
