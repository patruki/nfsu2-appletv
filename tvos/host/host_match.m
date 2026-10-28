/* Free roam with other players over the internet, without a server of ours: Game Center's peer-to-peer matches.
 *
 * The free-roam mesh (runtime/roam_core.c) talks in small UDP datagrams to peers it knows by IPv4 address and port.
 * Players who are not on one network have no such address for each other, so each Game Center player gets a made-up
 * one here, in 169.254.0.0/16 (a range the core takes as private, and the one a real network uses least): a hash of
 * the player's team player ID, which is the same on every Apple TV, so the addresses the peers pass on to each other
 * (the core gossips them) mean the same thing everywhere.  roam_bsd.c hands every datagram for such an address to
 * host_match_send, and the datagrams that arrive come back through roam_gk_deliver.  Nothing else of the mesh knows.
 *
 * The app asks Game Center for a match of 2 to 4 players as soon as free roam starts, and again whenever the match
 * is gone.  Until someone else is found, nothing happens: the player has free roam to themselves.  Game Center must be
 * signed in on the Apple TV, and only players of this app (the TestFlight testers) are matched.  A datagram goes
 * unreliably, or reliably when it is too big for that (the car look records are up to 2 KB, in pieces). */
#import <UIKit/UIKit.h>
#import <GameKit/GameKit.h>
#include <stdint.h>

void roam_gk_deliver(uint32_t ip, const uint8_t *buf, int len);     /* runtime/roam_bsd.c */
void roam_gk_peer(uint32_t ip);

#define MIN_PLAYERS     2
#define MAX_PLAYERS     4                 /* what a peer-to-peer match takes, as far as I know */
#define PLAYER_GROUP    47210             /* only players with the same group are matched: the mesh's port */
#define MAX_UNRELIABLE  900               /* above this a datagram goes reliably */
#define LINK_LOCAL(ip)  (((ip) >> 16) == 0xA9FEu)

static dispatch_queue_t g_q;              /* sends, searching, housekeeping */
static NSObject *g_lock;                  /* the match and the two address tables */
static GKMatch *g_match;
static GKMatchRequest *g_req;
static NSMutableDictionary<NSNumber *, GKPlayer *> *g_by_ip;
static NSMutableDictionary<NSString *, NSNumber *> *g_ip_of;
static BOOL g_on, g_searching, g_filling, g_told_auth;
static CFAbsoluteTime g_fill_at;
static uint32_t g_tx, g_rx, g_err;

static NSString *player_key(GKPlayer *p){ return p.teamPlayerID.length ? p.teamPlayerID : p.gamePlayerID; }

static uint32_t hash_ip(NSString *k){
    uint32_t h = 2166136261u;                                  /* FNV-1a */
    for (const char *c = k.UTF8String; *c; c++) h = (h ^ (uint8_t)*c) * 16777619u;
    uint32_t lo = (h ^ (h >> 16)) & 0xFFFFu;
    if (lo == 0 || lo == 0xFFFFu) lo = 0x4E32u;
    return 0xA9FE0000u | lo;
}
/* the player's address (g_lock held); a clash with another player here takes the next free one, which the others
 * would not agree with: 4 players in 65,000 addresses make that a chance of a few in a hundred thousand */
static uint32_t map_player(GKPlayer *p){
    NSString *k = player_key(p);
    NSNumber *have = g_ip_of[k];
    if (have){ g_by_ip[have] = p; return have.unsignedIntValue; }
    uint32_t ip = hash_ip(k);
    while (g_by_ip[@(ip)]) ip = 0xA9FE0000u | ((ip + 1) & 0xFFFFu);
    g_ip_of[k] = @(ip); g_by_ip[@(ip)] = p;
    return ip;
}
static void unmap_player(GKPlayer *p){
    @synchronized (g_lock){
        NSString *k = player_key(p);
        NSNumber *n = g_ip_of[k];
        if (n) [g_by_ip removeObjectForKey:n];
        [g_ip_of removeObjectForKey:k];
    }
}
static NSArray<NSNumber *> *mapped_ips(void){
    @synchronized (g_lock){ return g_by_ip.allKeys; }
}

static void search(double after);

/* the match is over (everyone left, or it failed): search again */
static void leave(GKMatch *m){
    @synchronized (g_lock){
        if (g_match != m) return;
        g_match = nil;
        [g_by_ip removeAllObjects]; [g_ip_of removeAllObjects];
    }
    g_filling = NO;
    m.delegate = nil;
    [m disconnect];
    fprintf(stderr, "[match] no one else in the match: searching again\n");
    search(3);
}

@interface MatchHost : NSObject <GKMatchDelegate>
@end
@implementation MatchHost
- (void)match:(GKMatch *)m didReceiveData:(NSData *)d fromRemotePlayer:(GKPlayer *)p {
    uint32_t ip;
    @synchronized (g_lock){ if (m != g_match) return; ip = map_player(p); }
    __atomic_add_fetch(&g_rx, 1, __ATOMIC_RELAXED);
    roam_gk_deliver(ip, d.bytes, (int)d.length);
}
- (void)match:(GKMatch *)m player:(GKPlayer *)p didChangeConnectionState:(GKPlayerConnectionState)s {
    if (s == GKPlayerStateConnected){
        uint32_t ip;
        @synchronized (g_lock){ if (m != g_match) return; ip = map_player(p); }
        fprintf(stderr, "[match] %s joined (%u.%u.%u.%u)\n", p.alias.UTF8String ?: "a player", ip >> 24, ip >> 16 & 255, ip >> 8 & 255, ip & 255);
        roam_gk_peer(ip);
    } else if (s == GKPlayerStateDisconnected){
        fprintf(stderr, "[match] %s left\n", p.alias.UTF8String ?: "a player");
        unmap_player(p);
        dispatch_async(g_q, ^{
            BOOL alone;
            @synchronized (g_lock){ alone = g_match == m && g_by_ip.count == 0; }
            if (alone) leave(m);
        });
    }
}
- (void)match:(GKMatch *)m didFailWithError:(NSError *)e {
    fprintf(stderr, "[match] the match failed: %s\n", e.localizedDescription.UTF8String ?: "-");
    dispatch_async(g_q, ^{ leave(m); });
}
@end
static MatchHost *g_delegate;

static void search(double after){
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * NSEC_PER_SEC)), g_q, ^{
        if (!g_on || g_searching) return;
        @synchronized (g_lock){ if (g_match) return; }
        if (!GKLocalPlayer.local.isAuthenticated){
            if (!g_told_auth){ g_told_auth = YES; fprintf(stderr, "[match] waiting for Game Center: sign in on the Apple TV to play with others\n"); }
            search(5);
            return;
        }
        g_told_auth = NO;
        g_searching = YES;
        GKMatchRequest *r = [GKMatchRequest new];
        r.minPlayers = MIN_PLAYERS; r.maxPlayers = MAX_PLAYERS; r.playerGroup = PLAYER_GROUP;
        g_req = r;
        fprintf(stderr, "[match] searching for %d to %d players as %s\n", MIN_PLAYERS, MAX_PLAYERS, GKLocalPlayer.local.alias.UTF8String ?: "-");
        [GKMatchmaker.sharedMatchmaker findMatchForRequest:r withCompletionHandler:^(GKMatch *m, NSError *e){
            dispatch_async(g_q, ^{
                g_searching = NO;
                if (!g_on){ [m disconnect]; return; }
                if (e || !m){
                    fprintf(stderr, "[match] no match: %s\n", e.localizedDescription.UTF8String ?: "-");
                    search(10);
                    return;
                }
                m.delegate = g_delegate;
                NSMutableArray<NSNumber *> *ips = [NSMutableArray array];
                @synchronized (g_lock){
                    g_match = m;
                    for (GKPlayer *p in m.players) [ips addObject:@(map_player(p))];
                }
                fprintf(stderr, "[match] a match of %lu players (%u still to come)\n", (unsigned long)m.players.count + 1, (unsigned)m.expectedPlayerCount);
                for (NSNumber *n in ips) roam_gk_peer(n.unsignedIntValue);
            });
        }];
    });
}

/* every 2 s: the peers are introduced again until they answer (their first HELLOs may have gone before their end was
 * ready), and a match with room left looks for more players */
static void housekeeping(void){
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), g_q, ^{
        if (!g_on) return;
        GKMatch *m;
        @synchronized (g_lock){ m = g_match; }
        if (m){
            for (NSNumber *n in mapped_ips()) roam_gk_peer(n.unsignedIntValue);
            if (!g_filling && (NSUInteger)(MAX_PLAYERS - 1) > m.players.count + m.expectedPlayerCount && CFAbsoluteTimeGetCurrent() - g_fill_at > 15){
                g_filling = YES; g_fill_at = CFAbsoluteTimeGetCurrent();
                [GKMatchmaker.sharedMatchmaker addPlayersToMatch:m matchRequest:g_req completionHandler:^(NSError *e){
                    dispatch_async(g_q, ^{
                        g_filling = NO;
                        if (e) fprintf(stderr, "[match] looking for more players: %s\n", e.localizedDescription.UTF8String ?: "-");
                    });
                }];
            }
        }
        housekeeping();
    });
}

/* roam_bsd.c, for a datagram to ip:port; 1: it is ours (a Game Center player's address) and is dealt with, sent or dropped,
 * so it never reaches the real network */
int host_match_send(uint32_t ip, const uint8_t *buf, int len){
    if (!LINK_LOCAL(ip)) return 0;
    GKMatch *m; GKPlayer *p;
    @synchronized (g_lock){ m = g_match; p = g_by_ip[@(ip)]; }
    if (!m || !p || len <= 0) return 1;
    NSData *d = [NSData dataWithBytes:buf length:(NSUInteger)len];
    dispatch_async(g_q, ^{
        NSError *e = nil;
        GKMatchSendDataMode mode = len > MAX_UNRELIABLE ? GKMatchSendDataReliable : GKMatchSendDataUnreliable;
        if ([m sendData:d toPlayers:@[p] dataMode:mode error:&e]) { g_tx++; return; }
        if (++g_err <= 5 || g_err % 1000 == 0)
            fprintf(stderr, "[match] send of %d bytes failed (%u so far): %s\n", len, g_err, e.localizedDescription.UTF8String ?: "-");
    });
    return 1;
}

void host_match_start(void){
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_q = dispatch_queue_create("nfsu2.match", DISPATCH_QUEUE_SERIAL);
        g_lock = [NSObject new];
        g_by_ip = [NSMutableDictionary dictionary]; g_ip_of = [NSMutableDictionary dictionary];
        g_delegate = [MatchHost new];
    });
    if (g_on) return;
    g_on = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        GKLocalPlayer.local.authenticateHandler = ^(UIViewController *vc, NSError *err){
            if (GKLocalPlayer.local.isAuthenticated) search(0);
            else fprintf(stderr, "[match] Game Center: %s\n", vc ? "not signed in (no sign-in screen over the game)" : err.localizedDescription.UTF8String ?: "no answer");
        };
    });
    search(1);
    housekeeping();
}

void host_match_stop(void){
    if (!g_on) return;
    g_on = NO;
    GKMatch *m;
    @synchronized (g_lock){ m = g_match; g_match = nil; [g_by_ip removeAllObjects]; [g_ip_of removeAllObjects]; }
    [GKMatchmaker.sharedMatchmaker cancel];
    m.delegate = nil;
    [m disconnect];
    fprintf(stderr, "[match] stopped: %u datagrams sent, %u received, %u failed\n", g_tx, g_rx, g_err);
}
