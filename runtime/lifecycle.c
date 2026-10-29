/* lifecycle.c -- quitting and app activation, delivered the way Windows does.
 *
 * Quit (Cmd-Q, the window's close button, Dock > Quit, logout):
 *   the request becomes a WM_CLOSE in the guest's message queue, like the
 *   close box / Alt-F4 on Windows.  The game's WndProc (0x5CCD60) sets its
 *   quit flag [0x864F4C] -- except while PC_Loading.fng is up (0x4A9330),
 *   so the message is re-posted every second -- its main loop (0x5811C0)
 *   returns and the game shuts down through its own code to ExitProcess.
 *   Only then does the host leave its event loop.  A second request, or
 *   NFSU2_QUIT_GRACE seconds (default 10) without the guest exiting, forces
 *   the exit.  Either way main() then waits for save files the game still
 *   has open for writing (lifecycle_drain_writes) and freezes the guest
 *   threads before the process exits, so no save is cut in half.
 *
 * Activation (Cmd-Tab, clicking another app, hiding the app):
 *   deactivation sends WM_ACTIVATE(WA_INACTIVE), WM_ACTIVATEAPP(FALSE),
 *   WM_KILLFOCUS; activation WM_ACTIVATEAPP(TRUE), WM_ACTIVATE(WA_ACTIVE),
 *   WM_SETFOCUS (the order Windows uses).  WM_ACTIVATE pauses / resumes the
 *   game's own sound (EAXSound [0x82B884]: 0x4810F0 / 0x481210) and
 *   WM_ACTIVATEAPP(FALSE) clears [0x870988], after which the pump (0x5BF1C0)
 *   blocks in GetMessageA until the app is active again: the game freezes in
 *   the background exactly as it does after an alt-tab on Windows.
 *   NFSU2_BACKGROUND=run keeps it running instead (no messages are sent).
 *   During a LAN session the game is not parked (lifecycle_may_park): the
 *   messages still go out, but it keeps running, as the game itself does in
 *   a network race.
 *
 * The host side (AppKit main thread) only flips atomics; everything that
 * touches the guest message queue runs on the guest thread, in
 * PeekMessageA/GetMessageA (lifecycle_pump), so the queue stays
 * single-threaded. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>

void win32_post_message(uint32_t m, uint32_t wp, uint32_t lp);   /* win32_ext.c */
void metal_request_quit(void);                                     /* metal.m */
int  fileio_open_writers(void);                                    /* fileio.c */

#define WM_ACTIVATE    0x0006u
#define WM_SETFOCUS    0x0007u
#define WM_KILLFOCUS   0x0008u
#define WM_CLOSE       0x0010u
#define WM_ACTIVATEAPP 0x001Cu

static double mono_s(void){
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ---- quit ---------------------------------------------------------------- */
static _Atomic int    g_quit_req = 0;        /* requests so far (Cmd-Q, close...) */
static _Atomic int    g_guest_gone = 0;      /* guest called ExitProcess / returned */
static _Atomic int    g_leaving = 0;         /* host loop told to stop */
static _Atomic double g_quit_t0 = 0;         /* time of the first request */
static double         g_close_last = 0;
static int            g_close_sent = 0;

static double quit_grace_s(void){
    const char *e = getenv("NFSU2_QUIT_GRACE");
    double g = (e && *e) ? atof(e) : 10.0;
    return g > 0 ? g : 10.0;
}
static void leave(const char *why){
    if (atomic_exchange(&g_leaving, 1)) return;
    fprintf(stderr, "app: leaving the event loop (%s)\n", why);
    metal_request_quit();
}

/* Host thread: Cmd-Q, window close, Dock > Quit; guest thread: autotest
 * "close".  The time is stored before the request is counted, so
 * lifecycle_tick never sees a request without its start time. */
void lifecycle_request_quit(const char *why){
    double none = 0;
    atomic_compare_exchange_strong(&g_quit_t0, &none, mono_s());
    int n = atomic_fetch_add(&g_quit_req, 1) + 1;
    if (n == 1){
        fprintf(stderr, "app: quit requested (%s) -> WM_CLOSE to the game\n", why);
    } else if (n == 2){
        fprintf(stderr, "app: quit requested again (%s) -> forcing the exit\n", why);
        leave("second quit request");
    }
    if (atomic_load(&g_guest_gone)) leave("guest already exited");
}
int lifecycle_quit_requested(void){ return atomic_load(&g_quit_req) > 0; }

/* boot.c, when the guest's entry point returns or calls ExitProcess. */
void lifecycle_guest_exited(int code){
    atomic_store(&g_guest_gone, 1);
    fprintf(stderr, "app: the game exited (code %d)%s\n", code,
            atomic_load(&g_quit_req) ? " after the quit request" : "");
    if (getenv("WINDOW")) leave("game exited");
}

/* Host event loop, once per iteration: enforces the grace period. */
void lifecycle_tick(void){
    if (!atomic_load(&g_quit_req) || atomic_load(&g_leaving)) return;
    if (mono_s() - atomic_load(&g_quit_t0) > quit_grace_s()){
        fprintf(stderr, "app: the game did not exit within %g s of WM_CLOSE\n", quit_grace_s());
        leave("quit grace period over");
    }
}

/* main(), after the event loop: give the game time to finish writing and
 * close its save files (the guest threads still run).  Returns the number
 * of write handles still open when it gave up. */
int lifecycle_drain_writes(double max_s){
    double t0 = mono_s();
    int n = fileio_open_writers();
    if (n) fprintf(stderr, "app: waiting for %d open save file(s) to be closed\n", n);
    while (n && mono_s() - t0 < max_s){
        usleep(10000);
        n = fileio_open_writers();
    }
    if (n) fprintf(stderr, "app: %d file(s) still open for writing after %.1f s\n", n, max_s);
    return n;
}

/* ---- activation ----------------------------------------------------------- */
static _Atomic int g_want_active = 1;        /* what AppKit says */
static int         g_told_active = 1;        /* what the game was told (guest thread) */
static _Atomic int64_t g_blur_until_ms = 0;  /* autotest "blur": re-activate at this time (monotonic ms:
                                              * 64-bit, the browser clock is epoch-based) */
static int g_bg_mode = -1;                   /* 1 = NFSU2_BACKGROUND=run */

static int background_runs(void){
    if (g_bg_mode < 0){
        const char *e = getenv("NFSU2_BACKGROUND");
        g_bg_mode = (e && (!strcasecmp(e, "run") || !strcasecmp(e, "1") || !strcasecmp(e, "on"))) ? 1 : 0;
    }
    return g_bg_mode;
}
double audio_time(void);                                           /* audio.m */
void discord_lifecycle_changed(void);                              /* discord.c */
void roam_game_parked(int on);                                     /* roam_game.c: friends see "paused" */
static void set_active(int on, const char *why){
    if (atomic_exchange(&g_want_active, on ? 1 : 0) != (on ? 1 : 0))
        fprintf(stderr, "app: %s (%s, audio t=%.3f s)\n", on ? "activated" : "deactivated",
                why, audio_time());
}
/* Host thread: NSApplicationDidBecomeActive / DidResignActive.  Ignored for
 * NOFOCUS test runs: their window is never meant to be the active one. */
void lifecycle_set_active(int on, const char *why){
    const char *nf = getenv("NOFOCUS");
    if (background_runs() || (nf && *nf && *nf != '0')) return;
    set_active(on, why);
}
/* autotest "blur MS": deactivate now, re-activate MS ms later (the guest is
 * frozen meanwhile, so the script cannot do it itself).  With background =
 * run the game is never told, as on the real path above, so a test can tell
 * pause from run. */
void lifecycle_simulate_blur(long ms){
    if (background_runs()){
        fprintf(stderr, "app: autotest blur ignored: background = run keeps the game going\n");
        return;
    }
    atomic_store(&g_blur_until_ms, (int64_t)(mono_s() * 1000.0) + ms);
    set_active(0, "autotest blur");
}

/* win32_ext.c GetMessageA: may the inactive game be parked there?  The game
 * never parks in a network race: its pump (0x5BF1C0) only peeks while
 * World::IsOnline (0x5F00F0: [0x89CF69], [0x8669F4] > 0 or [0x866A14] > 0).
 * In the LAN screens, the lobby and the game room it does, and a parked game
 * stops answering its lobby server's ping (server.cfg PINGWAIT 30 s): the
 * server drops it, and a host's own drop ends every player's session.  Mac
 * players switch apps often, so while a LAN session is open (from the
 * game's WSAStartup on its LAN screens to the last WSACleanup) the game is
 * not parked: the deactivation messages still went out (the game paused its
 * sound and ignores input, [0x870988] = 0), it just keeps running as in a
 * network race, with the output muted as when parked.  Single-player is
 * unchanged. */
int winsock_session_active(void);                                  /* winsock.c */
void audio_set_muted(int on);                                      /* audio.m */
static int g_inactive_gen, g_park_noted = -1, g_session_muted;
int lifecycle_may_park(void){
    if (g_told_active) return 0;
    if (winsock_session_active()){
        if (g_park_noted != g_inactive_gen){
            g_park_noted = g_inactive_gen;
            fprintf(stderr, "app: in the background during a LAN session: the game keeps running (sound paused) "
                    "so the other players do not drop it\n");
            audio_set_muted(1); g_session_muted = 1;
        }
        return 0;
    }
    return 1;
}
/* Parked in the background right now (inactive and outside a LAN session):
 * for code that pauses its own work while the game is parked, the stall
 * watchdog (no report: no frames on purpose) and the Discord status
 * ("Paused").  During a LAN session in the background the game keeps
 * running, so neither treats it as parked. */
int lifecycle_game_parked(void){ return !g_told_active && !winsock_session_active(); }
/* Passes lifecycle_game_parked() on when it changes: the Discord status
 * ("Paused") and free-roam friends (roam_game.c: "paused") follow the
 * parked state, not the activation, so a game kept running in a LAN session
 * in the background is not announced as paused, and a LAN session that ends
 * while the app is in the background parks it (and announces it) then.
 * Guest thread, once per pump. */
static int g_parked_told;
static void parked_pump(void){
    int p = lifecycle_game_parked();
    if (p == g_parked_told) return;
    g_parked_told = p;
    discord_lifecycle_changed();                  /* presence: paused while parked */
    roam_game_parked(p);                          /* free-roam friends: paused while parked */
}

/* Guest thread, from PeekMessageA/GetMessageA once the game window exists:
 * turns pending host events into window messages. */
void lifecycle_pump(void){
    int64_t bu = atomic_load(&g_blur_until_ms);
    if (bu && (int64_t)(mono_s() * 1000.0) >= bu){
        atomic_store(&g_blur_until_ms, 0);
        set_active(1, "autotest blur over");
    }
    int want = atomic_load(&g_want_active);
    if (want != g_told_active){
        g_told_active = want;
        if (want){
            g_session_muted = 0;
            audio_set_muted(0);                            /* also after a park woken by a message (win32_ext.c) */
            win32_post_message(WM_ACTIVATEAPP, 1u, 0u);
            win32_post_message(WM_ACTIVATE, 1u, 0u);       /* WA_ACTIVE */
            win32_post_message(WM_SETFOCUS, 0u, 0u);
        } else {
            g_inactive_gen++;
            win32_post_message(WM_ACTIVATE, 0u, 0u);       /* WA_INACTIVE */
            win32_post_message(WM_ACTIVATEAPP, 0u, 0u);
            win32_post_message(WM_KILLFOCUS, 0u, 0u);
        }
    }
    parked_pump();
    if (atomic_load(&g_quit_req)){
        double t = mono_s();
        if (!g_close_sent || t - g_close_last >= 1.0){
            if (g_close_sent == 1) fprintf(stderr, "app: WM_CLOSE ignored (loading screen?), re-posting every second\n");
            g_close_sent++; g_close_last = t;
            win32_post_message(WM_CLOSE, 0u, 0u);
        }
    }
}
