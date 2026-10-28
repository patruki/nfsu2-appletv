/* regional.c -- the European game's own cars, the Vauxhall Corsa and the
 * Peugeot 106, in this North American game.
 *
 * The game folder has both when it was made from the European release (CARS\CORSA, CARS\PEUGOT106;
 * regional_install does nothing without them) and CarTypeInfo lists them (types 7 and 6, among the 31
 * player cars, with their names in every language's text), but the North
 * American exe keeps them off its lists by the game's region ([0x864f24],
 * 0x570a30; 0 in this exe):
 *  - 0x5022c0, whether the region sells a car type, for the car lot
 *    (UICareerCarLot::BuildCarList, 0x4df9c0, at 0x4dfa83) and every other
 *    car select (UIQRCarSelect::BuildCarList, 0x4e22e0, at 0x4e2374: Quick
 *    Race, Customize, LAN, and Online's UI_OLCarSelect.fng, whose screen is
 *    made by the same 0x4fc190): no for a type in the region's table, region
 *    0's {7, 6} at 0x7f7c48, the others' {5, 18} (the Civic and the RSX) at
 *    0x7f7c50;
 *  - 0x4feaf0, the AI racers' cars: a random one rated near the player's car
 *    from the region's 26 types (region 0's at 0x7f6da4, the others' at
 *    0x7f6dc0 with 7 and 6 in place of 5 and 18; 3 SUVs at 0x7f6ddc when
 *    the player drives an SUV).
 * Here region 0's table holds no type (-1), and its AI list is 28 long, the
 * two in the padding after it (read by nothing else; HOOK_SITE 0x4febad,
 * where both lists' paths meet).  The same as NFSU2 Extra Options'
 * UnlockRegionalCars (ExOptsTeam/NFSU2ExOpts, ExtraOptionsStuff.h).  The
 * page's save check (web/src/app/profile.ts) has always counted both among
 * the game's cars. */
#include "cpu.h"
#include "widescreen.h"           /* HOOK_SITE */
#include <stdio.h>

int fileio_resolve_game(const char *win, char *out, size_t outsz);     /* fileio.c */

#define LOCKED_NA       0x007f7c48u   /* 2 car types region 0 does not sell */
#define AI_CARS_NA      0x007f6da4u   /* region 0's AI car types, a byte each */
#define AI_CARS_NA_N    26u
#define T_PEUGOT106     6u
#define T_CORSA         7u

static int g_on;

/* a game folder made from the North American release has neither car: offering them then leaves the
 * loading screen waiting for CARS\CORSA\GEOMETRY.BIN for ever */
static int have_car(const char *dir){
    char win[64], host[1024];
    snprintf(win, sizeof win, "CARS\\%s\\GEOMETRY.BIN", dir);
    return fileio_resolve_game(win, host, sizeof host);
}

void regional_install(void){
    if (!have_car("CORSA") || !have_car("PEUGOT106")){
        fprintf(stderr, "[cars] the game folder has no CARS\\CORSA or CARS\\PEUGOT106: no Corsa or 106\n");
        return;
    }
    /* only on the data of the exe this port is made for */
    if (MR32(LOCKED_NA) != T_CORSA || MR32(LOCKED_NA + 4u) != T_PEUGOT106
        || MR8(AI_CARS_NA + AI_CARS_NA_N - 2u) != 5u || MR8(AI_CARS_NA + AI_CARS_NA_N - 1u) != 18u
        || MR16(AI_CARS_NA + AI_CARS_NA_N) != 0u){
        fprintf(stderr, "[cars] the exe's region tables are not the ones expected: no Corsa or 106\n");
        return;
    }
    MR32(LOCKED_NA) = MR32(LOCKED_NA + 4u) = 0xffffffffu;
    MR8(AI_CARS_NA + AI_CARS_NA_N) = T_CORSA;
    MR8(AI_CARS_NA + AI_CARS_NA_N + 1u) = T_PEUGOT106;
    g_on = 1;
}

int regional_hook(CPU *c, uint32_t ip){
    if (ip != HOOK_SITE(0x004febad)) return 0;    /* mov eax, [esp+0x34]: esi the list, ebp its length */
    if (g_on && c->esi == AI_CARS_NA && c->ebp == AI_CARS_NA_N) c->ebp = AI_CARS_NA_N + 2u;
    return 1;
}
