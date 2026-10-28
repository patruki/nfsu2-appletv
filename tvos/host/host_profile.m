/* The profile's name from Game Center.
 *
 * The game's name field starts on "NAME" and a profile whose player just pressed Return keeps it.
 * Before the game starts, a profile still called NAME is renamed to the player's Game Center name,
 * made into what the game's field takes: letters and digits, 7 at most (web/src/app/profile.ts,
 * which this follows: a profile is <name>/<name> in the save folder, with the name inside, 32
 * bytes, and three checksums over the file).  A profile with any other name was named by its
 * player and stays.  Apple gives an app the Game Center name, not the iCloud account's.
 *
 * Sign-in is not asked for here: an Apple TV that has a Game Center account answers at once, one
 * that has none gets no rename, and the game starts after 5 s at the latest. */
#import <UIKit/UIKit.h>
#import <GameKit/GameKit.h>

#define PROFILES_DIR  @"NFS Underground 2"
#define DEFAULT_NAME  @"NAME"
#define PROFILE_SIZE  54966u
#define PAYLOAD       54930u
#define VERSION       0x10Du
#define B             36u                       /* the payload's start in the file */
#define NAME_AT       (B + 53761u)
#define NAME_MAX      7

static uint32_t g_crc[256];

static uint32_t checksum(const uint8_t *d, size_t n){
    if (n < 4) return 0;
    if (!g_crc[1]) for (uint32_t i = 0; i < 256; i++){
        uint32_t r = i << 24;
        for (int k = 0; k < 8; k++) r = r & 0x80000000u ? (r << 1) ^ 0x04C11DB7u : r << 1;
        g_crc[i] = r;
    }
    uint32_t r = ~((uint32_t)d[0] << 24 | d[1] << 16 | d[2] << 8 | d[3]);
    for (size_t i = 4; i < n; i++) r = ((r << 8) | d[i]) ^ g_crc[r >> 24];
    return ~r;
}
static uint32_t rd32(const uint8_t *p){ return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static void wr32(uint8_t *p, uint32_t v){ p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

/* a file the game saved: its container, block sizes and version (the checksums may be stale: the
 * game loads such a file all the same) */
static int is_profile(const uint8_t *f, size_t n){
    return n == PROFILE_SIZE && !memcmp(f, "20CM", 4) && rd32(f + 4) == n && rd32(f + 8) == 8
        && rd32(f + 12) == PAYLOAD && rd32(f + 28) == VERSION && rd32(f + 32) == PAYLOAD;
}

/* the name the game's field takes out of a Game Center name: ASCII letters and digits, 7 */
NSString *host_profile_name_from(NSString *alias){
    NSString *a = [alias stringByApplyingTransform:@"Any-Latin; Latin-ASCII" reverse:NO] ?: alias;
    NSMutableString *o = [NSMutableString string];
    for (NSUInteger i = 0; i < a.length && o.length < NAME_MAX; i++){
        unichar c = [a characterAtIndex:i];
        if ((c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) [o appendFormat:@"%C", c];
    }
    return o.length ? o : nil;
}

static BOOL same(NSString *a, NSString *b){ return [a caseInsensitiveCompare:b] == NSOrderedSame; }

/* "NAME" renamed to "to" as if the game had made the profile under that name; 1 when it was */
static int rename_profile(NSString *root, NSString *from, NSString *to){
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *oldDir = [root stringByAppendingPathComponent:from], *newDir = [root stringByAppendingPathComponent:to];
    NSArray *all = [fm contentsOfDirectoryAtPath:root error:nil];
    for (NSString *f in all) if (same(f, to) || same([f componentsSeparatedByString:@" "].firstObject, to)){
        fprintf(stderr, "profile: %s exists already: no rename\n", f.UTF8String);
        return 0;
    }
    NSString *main = nil;
    for (NSString *f in [fm contentsOfDirectoryAtPath:oldDir error:nil]) if (same(f, from)) main = f;
    NSData *file = main ? [NSData dataWithContentsOfFile:[oldDir stringByAppendingPathComponent:main]] : nil;
    if (!file || !is_profile(file.bytes, file.length)){ fprintf(stderr, "profile: %s is not a profile file the game saved: left alone\n", from.UTF8String); return 0; }

    NSMutableData *nf = [file mutableCopy];
    uint8_t *p = nf.mutableBytes;
    memset(p + NAME_AT, 0, 32);
    memcpy(p + NAME_AT, to.UTF8String, to.length);
    wr32(p + 16, checksum(p + 28, B - 28));
    wr32(p + 20, checksum(p + B, nf.length - B));
    wr32(p + 24, checksum(p, 24));

    /* the new folders in full before the old ones go: a rename that stops halfway leaves the old profile */
    NSMutableArray<NSArray *> *moves = [NSMutableArray arrayWithObject:@[from, to]];
    for (NSString *f in all){
        NSArray *w = [f componentsSeparatedByString:@" "];
        if (w.count == 3 && same(w[0], from) && ([w[1] isEqual:@"DVD"] || [w[1] isEqual:@"Magazine"]))
            [moves addObject:@[f, [NSString stringWithFormat:@"%@ %@ %@", to, w[1], w[2]]]];
    }
    NSMutableArray *made = [NSMutableArray array];
    BOOL ok = YES;
    for (NSArray *m in moves){
        NSString *src = [root stringByAppendingPathComponent:m[0]], *dst = [root stringByAppendingPathComponent:m[1]];
        ok = ok && [fm copyItemAtPath:src toPath:dst error:nil];
        if (ok) [made addObject:dst];
    }
    if (ok){
        /* the copy still holds the old file under the old name: the new one replaces it */
        [fm removeItemAtPath:[newDir stringByAppendingPathComponent:main] error:nil];
        ok = [nf writeToFile:[newDir stringByAppendingPathComponent:to] atomically:YES];
    }
    if (!ok){
        for (NSString *d in made) [fm removeItemAtPath:d error:nil];
        fprintf(stderr, "profile: the rename of %s did not work: left as it was\n", from.UTF8String);
        return 0;
    }
    for (NSArray *m in moves) [fm removeItemAtPath:[root stringByAppendingPathComponent:m[0]] error:nil];
    fprintf(stderr, "profile: %s is now %s (%lu folder%s)\n", from.UTF8String, to.UTF8String, (unsigned long)moves.count, moves.count == 1 ? "" : "s");
    return 1;
}

/* the Game Center name of this Apple TV, or nil (not signed in, or no answer in time) */
static NSString *game_center_alias(double seconds){
    __block NSString *alias = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        GKLocalPlayer *lp = GKLocalPlayer.local;
        lp.authenticateHandler = ^(UIViewController *vc, NSError *err){
            if (lp.isAuthenticated) alias = lp.alias;
            else fprintf(stderr, "profile: Game Center: %s\n", vc ? "not signed in (no sign-in screen over the game)" : err.localizedDescription.UTF8String ?: "no answer");
            dispatch_semaphore_signal(sem);
        };
    });
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC))) != 0)
        fprintf(stderr, "profile: Game Center did not answer in %.0f s\n", seconds);
    return alias;
}

/* before the game starts */
void host_profile_adopt(const char *overlay){
    @autoreleasepool {
        NSString *root = [[NSString stringWithUTF8String:overlay] stringByAppendingPathComponent:PROFILES_DIR];
        NSFileManager *fm = NSFileManager.defaultManager;
        BOOL hasDefault = NO;
        for (NSString *f in [fm contentsOfDirectoryAtPath:root error:nil]) if (same(f, DEFAULT_NAME)) hasDefault = YES;
        if (!hasDefault) return;                         /* nothing called NAME: nothing to do, nothing to wait for */
        NSString *alias = game_center_alias(5.0);
        NSString *name = alias ? host_profile_name_from(alias) : nil;
        fprintf(stderr, "profile: Game Center name \"%s\" -> %s\n", alias.UTF8String ?: "-", name.UTF8String ?: "no name the game takes");
        if (name && !same(name, DEFAULT_NAME)) rename_profile(root, DEFAULT_NAME, name);
    }
}
