/* fpscounter.h -- on-screen frame-rate counter, see fpscounter.m */
#ifndef FPSCOUNTER_H
#define FPSCOUNTER_H
int  fpscounter_on(void);                 /* 0 off, 1 on, 2 detailed */
int  fpscounter_in_dumps(void);           /* NFSU2_FPS_COUNTER_DUMP=1: frame dumps show it */
void fpscounter_cycle(void);              /* off -> on -> detailed -> off */
void fpscounter_note_present(void);       /* main thread, per drawable handed to the display */
void fpscounter_note_presented(double t); /* presentedTime of a drawable (any thread; 0 = not shown) */
void fpscounter_note_gpu(double ms);      /* command-buffer completion handler */
#ifdef __OBJC__
#import <Metal/Metal.h>
#import <TargetConditionals.h>
#if TARGET_OS_TV
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#endif
void fpscounter_init(id<MTLDevice> dev);
/* after the game's frame: dst = the drawable, px_per_pt = its pixels per
 * window point, bw x bh = the window's backing pixels (for the scale line) */
void fpscounter_draw(id<MTLCommandBuffer> cb, id<MTLTexture> dst, double px_per_pt,
                     unsigned bw, unsigned bh);
#if !TARGET_OS_TV
void fpscounter_add_menu(NSMenu *m);
#endif
#endif
#endif
