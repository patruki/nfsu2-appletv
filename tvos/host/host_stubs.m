/* What the Mac build gets from keyboard_mac.m and fpscounter.m, which are AppKit: on tvOS the
 * keyboard layout names fall back to the US ones (dikeys.c), the autotest key synthesis finds no
 * key, and the frame-rate counter is off. */
#import <Metal/Metal.h>
#include <stdint.h>
#include "kbd.h"
#include "fpscounter.h"

const char *kbdmac_layout_name(unsigned dik){ (void)dik; return 0; }
int  kbdmac_synth_key(int type, const char *key){ (void)type; (void)key; return 0; }
int  kbdmac_synth_char(int type, uint32_t unicode){ (void)type; (void)unicode; return 0; }
void kbdmac_synth_simple(int type, double a, double b){ (void)type; (void)a; (void)b; }

int  fpscounter_on(void){ return 0; }
int  fpscounter_in_dumps(void){ return 0; }
void fpscounter_cycle(void){ }
void fpscounter_note_present(void){ }
void fpscounter_note_presented(double t){ (void)t; }
void fpscounter_note_gpu(double ms){ (void)ms; }
void fpscounter_init(id<MTLDevice> dev){ (void)dev; }
void fpscounter_draw(id<MTLCommandBuffer> cb, id<MTLTexture> dst, double px_per_pt, unsigned bw, unsigned bh){
    (void)cb; (void)dst; (void)px_per_pt; (void)bw; (void)bh; }
