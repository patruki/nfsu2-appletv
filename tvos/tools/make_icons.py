#!/usr/bin/env python3
"""Generates tvos/app/Assets.xcassets: tvOS app icons (layered, as the App Store wants) and the
Top Shelf images.  With the game's exe the front layer is the game's own icon (its 32x32 logo,
enlarged in whole steps so it stays crisp; the artwork is EA's: for personal use); without it,
the name in plain letters.
    .venv/bin/python tvos/tools/make_icons.py ["<game folder>/SPEED2.EXE"]"""
import json
import os
import shutil
import sys
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
ART = None
if len(sys.argv) > 1:
    import exeicon
    w_, h_, bpp_, raw_ = max(exeicon.exe_icons(sys.argv[1]), key=lambda t: (t[0] * t[1], t[2]))
    ART = exeicon.decode(w_, h_, bpp_, raw_)

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
        k = max(1, int(h * 0.62) // ART.height)
        logo = ART.resize((ART.width * k, ART.height * k), Image.NEAREST)
        mask = Image.new("L", logo.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, logo.width - 1, logo.height - 1], radius=logo.width // 9, fill=255)
        logo.putalpha(Image.composite(logo.getchannel("A"), Image.new("L", logo.size, 0), mask))
        im.alpha_composite(logo, ((w - logo.width) // 2, int(h * 0.08)))
        f = font(int(h * 0.11))
        t = "UNDERGROUND 2"
        b = d.textbbox((0, 0), t, font=f)
        x, y = (w - (b[2] - b[0])) / 2 - b[0], h * 0.80
        d.text((x + max(2, h // 150), y + max(2, h // 150)), t, font=f, fill=(0, 0, 0, 200))
        d.text((x, y), t, font=f, fill=(255, 255, 255, 255))
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
