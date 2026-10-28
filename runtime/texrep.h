/* texrep.h -- optional texture replacement packs ("textures = upscaled"),
 * runtime/texrep.m; packs are built by tools/texpack.
 *
 * Off by default.  With NFSU2_TEXTURES unset (or "original") and no
 * NFSU2_TEXDUMP, every guest-side hook returns at its first line and the
 * draw encoder never binds anything but the game's own textures. */
#ifndef TEXREP_H
#define TEXREP_H
#include <stdint.h>

#define TEXREP_MAXTEX 16384u      /* = metal.m MAXTEX */

/* ---- guest thread (com.c) -------------------------------------------- */
/* CreateTexture: mid = Metal texture id, levels = Metal level count */
void texrep_created(unsigned mid, unsigned w, unsigned h, unsigned levels,
                    unsigned d3dfmt, unsigned usage, unsigned pool);
/* UnlockRect of a 2D texture level (after metal_upload_texture) */
void texrep_uploaded(unsigned mid, unsigned level, const uint8_t *data,
                     unsigned pitch, unsigned rows);
/* a level was written through one of the texture's surfaces (the car skin
 * composite): the content is dynamic from now on */
void texrep_surface_written(unsigned mid);
/* the Metal texture id is being freed (feat/heap's metal_free_texture) */
void texrep_released(unsigned mid);
/* once per Present, before metal_present */
void texrep_frame(void);
/* exit report (com.c) */
void texrep_report(void);

/* ---- any thread --------------------------------------------------------- */
int  texrep_wanted(void);         /* textures = upscaled (menu item; shown once a pack is in use) */
void texrep_set_shown(int on);    /* -1 = toggle; A/B and the menu item */
int  texrep_shown(void);

#ifdef __OBJC__
#import <Metal/Metal.h>
#import <TargetConditionals.h>
#if TARGET_OS_TV
#import <UIKit/UIKit.h>
#else
#import <Cocoa/Cocoa.h>
#endif
/* ---- main thread (metal.m draw encoder) --------------------------------- */
extern int g_texrep_frame_on;                     /* bind replacements this frame */
extern __strong id<MTLTexture> g_texrep_tex[TEXREP_MAXTEX];
extern uint8_t g_texrep_k[TEXREP_MAXTEX];         /* log2(scale): pack levels above the original */
/* start of every frame's encode: applies what the guest thread published
 * (and copies the game's own levels under the new ones, on q) */
void texrep_main_frame(id<MTLCommandQueue> q);
#if !TARGET_OS_TV
void texrep_add_menu(NSMenu *m);
#endif                  /* app menu: "Upscaled Textures" */
unsigned texrep_skey_slow(unsigned sk, unsigned k);
/* texture bound for sampling at a stage: the replacement if there is one */
static inline id<MTLTexture> texrep_pick(unsigned id_, id<MTLTexture> orig){
    if (__builtin_expect(g_texrep_frame_on, 0) && id_ < TEXREP_MAXTEX && g_texrep_tex[id_])
        return g_texrep_tex[id_];
    return orig;
}
/* sampler key for a stage whose texture is id_ (see texrep_skey_slow) */
static inline unsigned texrep_skey(unsigned id_, unsigned sk){
    if (__builtin_expect(g_texrep_frame_on, 0) && id_ && id_ < TEXREP_MAXTEX && g_texrep_tex[id_])
        return texrep_skey_slow(sk, g_texrep_k[id_]);
    return sk;
}
#endif
#endif
