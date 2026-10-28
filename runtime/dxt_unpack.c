/* DXT1/3/5 (BC1/2/3) unpacked to BGRA8 on the CPU, for a GPU without BC texture compression (Apple's
 * A-series: the Apple TV).  The blocks decode as Metal's own BC formats define them (the D3D10 rules):
 * DXT3 and DXT5 colour blocks always have four colours; a DXT1 block with c0 <= c1 has three and a
 * transparent black.  Unpacked, a texture takes 8x (DXT1) or 4x (DXT3/5) of its size.
 * Port of web/src/gpu/dxt.ts (unpackDxt). */
#include "dxt_unpack.h"

static uint8_t C5[32], C6[64];
static void tables(void){
    static int done;
    if (done) return;
    for (int i = 0; i < 32; i++) C5[i] = (uint8_t)((i << 3) | (i >> 2));
    for (int i = 0; i < 64; i++) C6[i] = (uint8_t)((i << 2) | (i >> 4));
    done = 1;
}

void dxt_unpack(int fmt, const uint8_t *src, size_t pitch, unsigned w, unsigned h, uint32_t *out){
    tables();
    int dxt1 = fmt == DXT_FMT_1, dxt5 = fmt == DXT_FMT_5;
    unsigned bsz = dxt1 ? 8u : 16u, co = dxt1 ? 0u : 8u;
    unsigned bw = (w + 3) >> 2, bh = (h + 3) >> 2;
    uint32_t pal[4]; uint8_t alpha[16], at[8];
    for (unsigned by = 0; by < bh; by++){
        for (unsigned bx = 0; bx < bw; bx++){
            const uint8_t *b = src + (size_t)by * pitch + (size_t)bx * bsz;
            if (dxt5){
                /* two alpha endpoints, then 16 3-bit codes: 8 levels, or 6 levels plus 0 and 255 */
                unsigned a0 = b[0], a1 = b[1];
                at[0] = (uint8_t)a0; at[1] = (uint8_t)a1;
                if (a0 > a1) for (unsigned i = 1; i < 7; i++) at[i + 1] = (uint8_t)(((7 - i) * a0 + i * a1) / 7);
                else { for (unsigned i = 1; i < 5; i++) at[i + 1] = (uint8_t)(((5 - i) * a0 + i * a1) / 5); at[6] = 0; at[7] = 255; }
                uint32_t lo = b[2] | b[3] << 8 | b[4] << 16, hi = b[5] | b[6] << 8 | b[7] << 16;
                for (unsigned i = 0; i < 8; i++){ alpha[i] = at[(lo >> (3 * i)) & 7]; alpha[i + 8] = at[(hi >> (3 * i)) & 7]; }
            } else if (!dxt1){
                /* 16 explicit 4-bit alphas */
                for (unsigned i = 0; i < 8; i++){ unsigned v = b[i]; alpha[2 * i] = (uint8_t)((v & 15) * 17); alpha[2 * i + 1] = (uint8_t)((v >> 4) * 17); }
            }
            unsigned c0 = b[co] | b[co + 1] << 8, c1 = b[co + 2] | b[co + 3] << 8;
            unsigned r0 = C5[c0 >> 11], g0 = C6[(c0 >> 5) & 63], b0 = C5[c0 & 31];
            unsigned r1 = C5[c1 >> 11], g1 = C6[(c1 >> 5) & 63], b1 = C5[c1 & 31];
            pal[0] = b0 | g0 << 8 | r0 << 16 | 0xFF000000u;
            pal[1] = b1 | g1 << 8 | r1 << 16 | 0xFF000000u;
            if (!dxt1 || c0 > c1){
                pal[2] = (2 * b0 + b1) / 3 | ((2 * g0 + g1) / 3) << 8 | ((2 * r0 + r1) / 3) << 16 | 0xFF000000u;
                pal[3] = (b0 + 2 * b1) / 3 | ((g0 + 2 * g1) / 3) << 8 | ((r0 + 2 * r1) / 3) << 16 | 0xFF000000u;
            } else {
                pal[2] = ((b0 + b1) >> 1) | ((g0 + g1) >> 1) << 8 | ((r0 + r1) >> 1) << 16 | 0xFF000000u;
                pal[3] = 0;
            }
            uint32_t idx = (uint32_t)b[co + 4] | (uint32_t)b[co + 5] << 8 | (uint32_t)b[co + 6] << 16 | (uint32_t)b[co + 7] << 24;
            /* an edge block, or a level smaller than a block (2x2, 1x1): only the texels inside */
            unsigned ph = h - by * 4 < 4 ? h - by * 4 : 4, pw = w - bx * 4 < 4 ? w - bx * 4 : 4;
            for (unsigned py = 0; py < ph; py++){
                uint32_t *row = out + (size_t)(by * 4 + py) * w + bx * 4;
                for (unsigned px = 0; px < pw; px++){
                    unsigned i = py * 4 + px; uint32_t c = pal[(idx >> (2 * i)) & 3];
                    row[px] = dxt1 ? c : ((c & 0xFFFFFFu) | (uint32_t)alpha[i] << 24);
                }
            }
        }
    }
}
