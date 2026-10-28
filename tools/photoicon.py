#!/usr/bin/env python3
"""The pause menu's Photo Mode icon (runtime/photo.c): a still camera (tools/photo_icon.svg, white in alpha levels
like the game's own INGAME_ICON_* textures, tinted by the menu), shown in place of INGAME_ICON_VOIP_ON, which nothing
in the PC game draws.  Writes runtime/web/photo_icon.h: that texture's key as texrep_web.c sees its level 0 (CRC-32,
Adler-32, size, D3DFORMAT) and the drawing's alpha at 512 x 256 (the SVG is the game's 128 x 64, four times over),
run-length coded.

    .venv/bin/python3 tools/photoicon.py [game folder] [--png out.png]      (needs cairosvg)
"""
import io, os, sys, zlib
import cairosvg
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import texpacks as T

GAME = os.path.expanduser('~/nfsu2-data/Need for Speed - Underground 2')
NAME = 'INGAME_ICON_VOIP_ON'
W, H = 512, 256
SVG = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'photo_icon.svg')


def draw():
    png = cairosvg.svg2png(url=SVG, output_width=W, output_height=H)
    return Image.open(io.BytesIO(png)).convert('RGBA').getchannel('A')


def rle(b):
    out, i = bytearray(), 0
    while i < len(b):
        j = i
        while j < len(b) and j - i < 255 and b[j] == b[i]: j += 1
        out += bytes((j - i, b[i])); i = j
    return bytes(out)


def main():
    a = [x for i, x in enumerate(sys.argv[1:], 1) if not x.startswith('--') and sys.argv[i - 1] != '--png']
    game = a[0] if a else GAME
    d = open(os.path.join(game, 'GLOBAL', 'InGameCommon.bun'), 'rb').read()
    want = T.bstring_hash(NAME)
    key = next(((w, h, fmt, lv) for nh, w, h, fmt, lv in T.textures(d) if nh == want and lv), None)
    if not key: sys.exit(f'{NAME}: not in InGameCommon.bun')
    w, h, fmt, lv = key
    alpha = draw()
    if '--png' in sys.argv:
        out = sys.argv[sys.argv.index('--png') + 1]
        Image.merge('LA', (Image.new('L', alpha.size, 255), alpha)).save(out)
    runs = rle(alpha.tobytes())
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    with open(os.path.join(root, 'runtime', 'web', 'photo_icon.h'), 'w', newline='\n') as f:
        f.write('/* photo_icon.h -- made by tools/photoicon.py: the pause menu\'s Photo Mode icon (texrep_web.c) */\n')
        f.write(f'#define PHOTO_ICON_KEY_CRC   0x{zlib.crc32(lv):08x}u   /* {NAME}\'s level 0 */\n')
        f.write(f'#define PHOTO_ICON_KEY_ADLER 0x{zlib.adler32(lv):08x}u\n')
        f.write(f'#define PHOTO_ICON_KEY_W     {w}u\n#define PHOTO_ICON_KEY_H     {h}u\n')
        f.write(f'#define PHOTO_ICON_KEY_FMT   0x{fmt:08x}u\n')
        f.write(f'#define PHOTO_ICON_W         {W}u\n#define PHOTO_ICON_H         {H}u\n')
        f.write(f'/* (count, alpha) pairs, row by row */\nstatic const unsigned char photo_icon_rle[{len(runs)}] = {{\n')
        for i in range(0, len(runs), 24):
            f.write('    ' + ','.join(str(x) for x in runs[i:i + 24]) + ',\n')
        f.write('};\n')
    print(f'runtime/web/photo_icon.h: {NAME} {w}x{h} crc {zlib.crc32(lv):08x}, {W}x{H} icon in {len(runs)} bytes')


if __name__ == '__main__':
    main()
