/* DXT unpacking on the CPU (dxt_unpack.c) */
#ifndef DXT_UNPACK_H
#define DXT_UNPACK_H
#include <stddef.h>
#include <stdint.h>
enum { DXT_FMT_1 = 1, DXT_FMT_3 = 3, DXT_FMT_5 = 5 };
/* One mip level of w x h texels as BGRA8, w * 4 bytes per row, into out (w * h uint32_t).  src: the
 * level's blocks, pitch = bytes per row of 4x4 blocks. */
void dxt_unpack(int fmt, const uint8_t *src, size_t pitch, unsigned w, unsigned h, uint32_t *out);
#endif
