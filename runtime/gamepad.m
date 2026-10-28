/* gamepad.m -- GameController.framework input for the virtual game pad.
 *
 * The first connected controller with an extended gamepad profile drives
 * the pad; when it goes away the next connected one takes over (hot-plug).
 * runtime/dinput_pad.c presents the pad to the game as a DirectInput8
 * gamepad, so the keyboard keeps working next to it: the game ANDs all its
 * input channels together.
 *
 * Threading: connect/disconnect notifications arrive on the main thread
 * (metal.m pumps its run loop).  Value changes run on a private serial
 * queue (controller.handlerQueue) and copy the controller state into g_real
 * under g_lk.  gamepad_read() is called from the guest thread.  Without a
 * main run loop (headless runs) no real controller is ever seen; the
 * script's synthetic pad works either way.
 *
 *   NFSU2_PAD=0 (or off)        no game pad at all (keyboard and mouse only)
 *   NFSU2_PAD_DEADZONE=<f>      radial stick dead zone, fraction of full
 *                               deflection (default 0.08); the rest of the
 *                               travel is rescaled to stay proportional
 *   NFSU2_PAD_TRIGGER_DEADZONE=<f>  trigger dead zone (default 0.02)
 *   NFSU2_PAD_BACKGROUND=1      keep reading the controller while the game
 *                               window is not frontmost
 *   NFSU2_PAD_LOG=1             log controllers connecting and disconnecting */
#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#include <os/lock.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "gamepad.h"

static os_unfair_lock g_lk = OS_UNFAIR_LOCK_INIT;
static PadState g_real;              /* active controller, raw values */
static PadState g_syn;               /* the input script's controller */
static int      g_log = 0;

static GCController   *g_active;     /* main thread only */
static unsigned        g_gen;        /* bumped under g_lk when g_active changes */
static NSMutableArray *g_order;      /* connected controllers, oldest first */
static dispatch_queue_t g_q;

static float envf(const char *nm, float dflt, float lo, float hi){
    const char *e = getenv(nm);
    if (!e || !*e) return dflt;
    float v = (float)atof(e);
    return v < lo ? lo : (v > hi ? hi : v);
}
int gamepad_env_flag(const char *nm, int dflt){
    const char *e = getenv(nm);
    if (!e || !*e) return dflt;
    if ((*e >= '0' && *e <= '9') || *e == '-' || *e == '+') return atoi(e) != 0;
    return strcasecmp(e, "off") && strcasecmp(e, "no") && strcasecmp(e, "false");
}

/* ---- controller state ------------------------------------------------ */
static void snap(GCExtendedGamepad *g, unsigned gen){
    uint32_t b = 0;
#define BT(e_, bit_) do { GCControllerButtonInput *_e = (e_); if (_e && _e.pressed) b |= 1u << (bit_); } while (0)
    BT(g.buttonA, PAD_A);            BT(g.buttonB, PAD_B);
    BT(g.buttonX, PAD_X);            BT(g.buttonY, PAD_Y);
    BT(g.leftShoulder, PAD_LB);      BT(g.rightShoulder, PAD_RB);
    BT(g.buttonOptions, PAD_BACK);   BT(g.buttonMenu, PAD_START);
    BT(g.leftThumbstickButton, PAD_LS); BT(g.rightThumbstickButton, PAD_RS);
    BT(g.buttonHome, PAD_HOME);
    BT(g.dpad.up, PAD_DUP);          BT(g.dpad.down, PAD_DDOWN);
    BT(g.dpad.left, PAD_DLEFT);      BT(g.dpad.right, PAD_DRIGHT);
#undef BT
    /* GameController's y axes point up; DirectInput's point down */
    float ax[PAD_NAXES] = {
        g.leftThumbstick.xAxis.value,  -g.leftThumbstick.yAxis.value,
        g.rightThumbstick.xAxis.value, -g.rightThumbstick.yAxis.value,
        g.leftTrigger.value,           g.rightTrigger.value };
    os_unfair_lock_lock(&g_lk);
    /* a change still queued for a controller that is no longer the active
     * one (it went away, or another took over) must not land in g_real */
    if (gen == g_gen){
        g_real.buttons = b;
        memcpy(g_real.axis, ax, sizeof ax);
    }
    os_unfair_lock_unlock(&g_lk);
}

#if TARGET_OS_TV
/* The Siri Remote as a minimal pad until a real one is paired (an extended pad always takes over):
 * the touch surface is the D-pad and the left stick, a click is A, Play/Pause is Start, Menu is B. */
static void snap_micro(GCMicroGamepad *g, unsigned gen){
    float x = g.dpad.xAxis.value, y = g.dpad.yAxis.value;
    uint32_t b = 0;
    if (g.buttonA.pressed)    b |= 1u << PAD_A;
    if (g.buttonX.pressed)    b |= 1u << PAD_START;
    if (g.buttonMenu.pressed) b |= 1u << PAD_B;
    if (y >  0.5f) b |= 1u << PAD_DUP;
    if (y < -0.5f) b |= 1u << PAD_DDOWN;
    if (x < -0.5f) b |= 1u << PAD_DLEFT;
    if (x >  0.5f) b |= 1u << PAD_DRIGHT;
    float ax[PAD_NAXES] = { x, -y, 0, 0, 0, 0 };      /* GameController's y points up, DirectInput's down */
    os_unfair_lock_lock(&g_lk);
    if (gen == g_gen){
        g_real.buttons = b;
        memcpy(g_real.axis, ax, sizeof ax);
    }
    os_unfair_lock_unlock(&g_lk);
}
#endif

static int family_of(GCController *k){
    NSString *cat = k.productCategory ?: @"";
    if ([cat containsString:@"Xbox"]) return PADF_XBOX;
    if ([cat containsString:@"DualShock"] || [cat containsString:@"DualSense"]) return PADF_PLAYSTATION;
    if ([cat containsString:@"Switch"] || [cat containsString:@"Joy-Con"]) return PADF_NINTENDO;
    return PADF_GENERIC;
}

/* ---- connect / disconnect (main thread) ---------------------------------- */
static void pick_active(void){
    GCController *best = nil;
    for (GCController *k in g_order) if (k.extendedGamepad){ best = k; break; }
#if TARGET_OS_TV
    BOOL micro = NO;
    if (!best) for (GCController *k in g_order) if (k.microGamepad){ best = k; micro = YES; break; }
#endif
    if (best == g_active) return;
    if (g_active){
        g_active.extendedGamepad.valueChangedHandler = nil;
#if TARGET_OS_TV
        g_active.microGamepad.valueChangedHandler = nil;
#endif
    }
    g_active = best;
    os_unfair_lock_lock(&g_lk);
    unsigned gen = ++g_gen;
    memset(&g_real, 0, sizeof g_real);
    if (best){
        g_real.connected = 1;
        g_real.family = family_of(best);
        snprintf(g_real.name, sizeof g_real.name, "%s",
                 best.vendorName.length ? best.vendorName.UTF8String : "Game Controller");
    }
    os_unfair_lock_unlock(&g_lk);
#if TARGET_OS_TV
    if (best && micro){
        best.handlerQueue = g_q;
        GCMicroGamepad *mp = best.microGamepad;
        mp.reportsAbsoluteDpadValues = NO;
        mp.valueChangedHandler = ^(GCMicroGamepad *p, GCControllerElement *el){ (void)el; snap_micro(p, gen); };
        dispatch_async(g_q, ^{ snap_micro(mp, gen); });
    } else
#endif
    if (best){
        best.handlerQueue = g_q;
        GCExtendedGamepad *gp = best.extendedGamepad;
        gp.valueChangedHandler = ^(GCExtendedGamepad *p, GCControllerElement *el){ (void)el; snap(p, gen); };
        dispatch_async(g_q, ^{ snap(gp, gen); });
    }
    fprintf(stderr, "[pad] player 1 controller: %s (%s)\n", best ? g_real.name : "none",
            best ? (best.productCategory.UTF8String ?: "?") : "-");
}

static void setup(void){
    g_order = [NSMutableArray array];
    g_q = dispatch_queue_create("nfsu2.gamepad", DISPATCH_QUEUE_SERIAL);
    if (@available(macOS 11.3, *)){
        if (gamepad_env_flag("NFSU2_PAD_BACKGROUND", 0)) GCController.shouldMonitorBackgroundEvents = YES;
    }
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:GCControllerDidConnectNotification object:nil
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){
            GCController *k = n.object;
            if (g_log) fprintf(stderr, "[pad] connected: %s (%s)\n", k.vendorName.UTF8String ?: "?",
                               k.productCategory.UTF8String ?: "?");
            if (![g_order containsObject:k]) [g_order addObject:k];
            pick_active();
        }];
    [nc addObserverForName:GCControllerDidDisconnectNotification object:nil
        queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n){
            GCController *k = n.object;
            if (g_log) fprintf(stderr, "[pad] disconnected: %s\n", k.vendorName.UTF8String ?: "?");
            [g_order removeObject:k];
            pick_active();
        }];
    for (GCController *k in [GCController controllers])
        if (![g_order containsObject:k]) [g_order addObject:k];
    fprintf(stderr, "[pad] GameController: %lu controller(s) connected at start-up\n",
            (unsigned long)g_order.count);
    pick_active();
}

void gamepad_init(void){
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_log = gamepad_env_flag("NFSU2_PAD_LOG", 0);
        if ([NSThread isMainThread]) setup();
        else dispatch_async(dispatch_get_main_queue(), ^{ setup(); });
    });
}

/* ---- reading ----------------------------------------------------------- */
/* Radial dead zone with the remaining travel rescaled, so half a stick
 * still reads (about) half. */
static void stick_dz(float *x, float *y, float dz){
    float r = sqrtf(*x * *x + *y * *y);
    if (r <= dz || r <= 0.f){ *x = *y = 0.f; return; }
    float k = (r >= 1.f ? 1.f : (r - dz) / (1.f - dz)) / r;
    *x *= k; *y *= k;
    if (*x > 1.f) *x = 1.f; if (*x < -1.f) *x = -1.f;
    if (*y > 1.f) *y = 1.f; if (*y < -1.f) *y = -1.f;
}
static float trig_dz(float v, float dz){
    if (v <= dz) return 0.f;
    return v >= 1.f ? 1.f : (v - dz) / (1.f - dz);
}

int gamepad_read(PadState *s){
    static float dz = -1.f, tdz = -1.f;
    if (dz < 0.f){ dz = envf("NFSU2_PAD_DEADZONE", 0.08f, 0.f, 0.9f);
                   tdz = envf("NFSU2_PAD_TRIGGER_DEADZONE", 0.02f, 0.f, 0.9f); }
    os_unfair_lock_lock(&g_lk);
    *s = g_syn.connected ? g_syn : g_real;      /* the script's pad wins while connected */
    os_unfair_lock_unlock(&g_lk);
    if (!s->wheel) stick_dz(&s->axis[PAD_AXIS_LX], &s->axis[PAD_AXIS_LY], dz);   /* a (script's) wheel: none */
    stick_dz(&s->axis[PAD_AXIS_RX], &s->axis[PAD_AXIS_RY], dz);
    s->axis[PAD_AXIS_LT] = trig_dz(s->axis[PAD_AXIS_LT], tdz);
    s->axis[PAD_AXIS_RT] = trig_dz(s->axis[PAD_AXIS_RT], tdz);
    return s->connected;
}

/* ---- synthetic controller (autotest) --------------------------------------- */
void gamepad_synth_connect(int on){
    os_unfair_lock_lock(&g_lk);
    if ((on != 0) != g_syn.connected || (on == 2) != g_syn.wheel){   /* 2: a steering wheel */
        memset(&g_syn, 0, sizeof g_syn);
        g_syn.connected = on ? 1 : 0;
        g_syn.synthetic = 1;
        g_syn.wheel = on == 2;
        g_syn.family = PADF_XBOX;
        snprintf(g_syn.name, sizeof g_syn.name, "Virtual Controller (autotest)");
    }
    os_unfair_lock_unlock(&g_lk);
}
void gamepad_synth_button(int b, int down){
    if (b < 0 || b >= PAD_NBUTTONS) return;
    if (!g_syn.connected) gamepad_synth_connect(1);
    os_unfair_lock_lock(&g_lk);
    if (down) g_syn.buttons |= 1u << b; else g_syn.buttons &= ~(1u << b);
    os_unfair_lock_unlock(&g_lk);
}
void gamepad_synth_axis(int a, float v){
    if (a < 0 || a >= PAD_NAXES) return;
    if (!g_syn.connected) gamepad_synth_connect(1);
    float lo = a >= PAD_AXIS_LT ? 0.f : -1.f;
    os_unfair_lock_lock(&g_lk);
    g_syn.axis[a] = v < lo ? lo : (v > 1.f ? 1.f : v);
    os_unfair_lock_unlock(&g_lk);
}

int gamepad_button_by_name(const char *nm){
    static const struct { const char *nm; int b; } T[] = {
        {"A",PAD_A},{"CROSS",PAD_A},{"B",PAD_B},{"CIRCLE",PAD_B},{"X",PAD_X},{"SQUARE",PAD_X},
        {"Y",PAD_Y},{"TRIANGLE",PAD_Y},{"LB",PAD_LB},{"L1",PAD_LB},{"RB",PAD_RB},{"R1",PAD_RB},
        {"BACK",PAD_BACK},{"VIEW",PAD_BACK},{"SELECT",PAD_BACK},{"SHARE",PAD_BACK},{"CREATE",PAD_BACK},
        {"START",PAD_START},{"MENU",PAD_START},{"OPTIONS",PAD_START},
        {"LS",PAD_LS},{"L3",PAD_LS},{"RS",PAD_RS},{"R3",PAD_RS},{"HOME",PAD_HOME},{"GUIDE",PAD_HOME},
        {"DUP",PAD_DUP},{"DDOWN",PAD_DDOWN},{"DLEFT",PAD_DLEFT},{"DRIGHT",PAD_DRIGHT},
    };
    for (unsigned i = 0; i < sizeof T / sizeof *T; i++) if (!strcasecmp(nm, T[i].nm)) return T[i].b;
    return -1;
}
int gamepad_axis_by_name(const char *nm){
    static const char *const T[PAD_NAXES] = {"LX","LY","RX","RY","LT","RT"};
    for (int i = 0; i < PAD_NAXES; i++) if (!strcasecmp(nm, T[i])) return i;
    if (!strcasecmp(nm, "L2")) return PAD_AXIS_LT;
    if (!strcasecmp(nm, "R2")) return PAD_AXIS_RT;
    return -1;
}
