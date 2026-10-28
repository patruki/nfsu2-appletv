/* The saves in iCloud.
 *
 * The game writes its saves into the Overlay folder (fileio's save overlay).  That folder is packed
 * into one compressed blob in the iCloud key-value store (1 MB for the whole app; a profile is
 * about 55 KB and the game's padding compresses to almost nothing).  tvOS has no iCloud Drive for
 * apps, so the key-value store is the place for a file this small.
 *
 *   at launch     the cloud copy is newer than the files here (or there are none): it is unpacked
 *                 into the Overlay before the game opens anything.  With nothing here and nothing
 *                 in the cloud yet (a new install) it waits a few seconds for iCloud to deliver.
 *   while playing every few seconds, a changed Overlay that has stopped changing and has no file
 *                 open for writing goes up.  The other way (a change that arrives from another
 *                 Apple TV) is not applied under a running game; the next launch takes it.
 *   leaving       host_cloud_flush() sends what is pending when the app is not in front.
 * The newest file time wins; there is no merge. */
#import <Foundation/Foundation.h>
#include <zlib.h>
#include <sys/stat.h>
#include <sys/time.h>

int fileio_open_writers(void);

#define KEY_DATA  @"saves.v1"
#define KEY_TIME  @"saves.time"
#define MAX_FILE  (512u << 10)          /* a log or a dump is not a save */
#define MAX_BLOB  (900u << 10)          /* the store holds 1 MB in all */

static NSString *g_dir;
static dispatch_queue_t g_q;
static dispatch_source_t g_timer;
static uint64_t g_sig_pushed, g_sig_seen;

typedef struct { double newest; uint64_t sig; unsigned n; } Scan;

/* the files worth sending: relative path, in a stable order */
static NSArray<NSString *> *save_files(void){
    NSMutableArray *out = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *rel in [fm enumeratorAtPath:g_dir]){
        NSDictionary *a = [fm attributesOfItemAtPath:[g_dir stringByAppendingPathComponent:rel] error:nil];
        if (![a.fileType isEqualToString:NSFileTypeRegular] || a.fileSize > MAX_FILE) continue;
        if ([rel.pathExtension.lowercaseString isEqualToString:@"log"]) continue;
        [out addObject:rel];
    }
    return [out sortedArrayUsingSelector:@selector(compare:)];
}

static Scan scan(void){
    Scan s = {0, 1469598103934665603ull, 0};
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *rel in save_files()){
        NSDictionary *a = [fm attributesOfItemAtPath:[g_dir stringByAppendingPathComponent:rel] error:nil];
        double t = a.fileModificationDate.timeIntervalSince1970;
        if (t > s.newest) s.newest = t;
        s.n++;
        const char *p = rel.UTF8String;
        uint64_t v[2] = { (uint64_t)a.fileSize, (uint64_t)(t * 1000.0) };
        for (; *p; p++) s.sig = (s.sig ^ (uint8_t)*p) * 1099511628211ull;
        for (int i = 0; i < 16; i++) s.sig = (s.sig ^ ((uint8_t *)v)[i]) * 1099511628211ull;
    }
    return s;
}

static void put32(NSMutableData *d, uint32_t v){ uint8_t b[4] = { v, v >> 8, v >> 16, v >> 24 }; [d appendBytes:b length:4]; }
static uint32_t get32(const uint8_t *p){ return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

/* "NSV1", count, then per file: path length, path, mtime (s), size, bytes; the lot deflated, with
 * its plain size in front */
static NSData *pack(double *newest){
    NSMutableData *raw = [NSMutableData data];
    NSArray *files = save_files();
    NSFileManager *fm = NSFileManager.defaultManager;
    [raw appendBytes:"NSV1" length:4];
    put32(raw, (uint32_t)files.count);
    double nw = 0;
    for (NSString *rel in files){
        NSString *path = [g_dir stringByAppendingPathComponent:rel];
        NSData *body = [NSData dataWithContentsOfFile:path];
        if (!body) continue;
        double t = [fm attributesOfItemAtPath:path error:nil].fileModificationDate.timeIntervalSince1970;
        if (t > nw) nw = t;
        const char *u = rel.UTF8String;
        put32(raw, (uint32_t)strlen(u)); [raw appendBytes:u length:strlen(u)];
        put32(raw, (uint32_t)t); put32(raw, (uint32_t)body.length); [raw appendData:body];
    }
    uLongf cl = compressBound((uLong)raw.length);
    NSMutableData *out = [NSMutableData dataWithLength:4 + cl];
    if (compress2((Bytef *)out.mutableBytes + 4, &cl, raw.bytes, (uLong)raw.length, 9) != Z_OK) return nil;
    memcpy(out.mutableBytes, (uint32_t[]){ (uint32_t)raw.length }, 4);
    out.length = 4 + cl;
    *newest = nw;
    return out;
}

static int unpack(NSData *blob){
    if (blob.length < 8) return 0;
    const uint8_t *b = blob.bytes;
    uLongf rl = get32(b);
    if (rl < 8 || rl > (64u << 20)) return 0;
    NSMutableData *raw = [NSMutableData dataWithLength:rl];
    if (uncompress(raw.mutableBytes, &rl, b + 4, (uLong)blob.length - 4) != Z_OK) return 0;
    const uint8_t *p = raw.bytes, *end = p + rl;
    if (rl < 8 || memcmp(p, "NSV1", 4)) return 0;
    uint32_t n = get32(p + 4); p += 8;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (uint32_t i = 0; i < n; i++){
        if (end - p < 4) return 0;
        uint32_t pl = get32(p); p += 4;
        if ((size_t)(end - p) < pl + 8) return 0;
        NSString *rel = [[NSString alloc] initWithBytes:p length:pl encoding:NSUTF8StringEncoding]; p += pl;
        uint32_t t = get32(p), sz = get32(p + 4); p += 8;
        if ((size_t)(end - p) < sz || !rel || [rel hasPrefix:@"/"] || [rel containsString:@".."]) return 0;
        NSString *path = [g_dir stringByAppendingPathComponent:rel];
        [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSData dataWithBytes:p length:sz] writeToFile:path atomically:YES];
        [fm setAttributes:@{ NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:t] } ofItemAtPath:path error:nil];
        p += sz;
    }
    return 1;
}

static void push(Scan s){
    NSUbiquitousKeyValueStore *kv = NSUbiquitousKeyValueStore.defaultStore;
    double newest = 0;
    NSData *blob = s.n ? pack(&newest) : nil;
    if (!blob){ g_sig_pushed = s.sig; return; }
    if (blob.length > MAX_BLOB){
        fprintf(stderr, "icloud: the saves are %lu bytes packed, more than the key-value store takes: not sent\n", (unsigned long)blob.length);
        g_sig_pushed = s.sig; return;
    }
    [kv setData:blob forKey:KEY_DATA];
    [kv setDouble:newest forKey:KEY_TIME];
    [kv synchronize];
    g_sig_pushed = s.sig;
    fprintf(stderr, "icloud: sent %u file(s), %lu bytes packed\n", s.n, (unsigned long)blob.length);
}

static void tick(void){
    Scan s = scan();
    /* changed, quiet for a whole tick and nothing being written */
    if (s.sig != g_sig_pushed && s.sig == g_sig_seen && fileio_open_writers() == 0) push(s);
    g_sig_seen = s.sig;
}

void host_cloud_flush(void){
    if (!g_q) return;
    dispatch_sync(g_q, ^{ Scan s = scan(); if (s.sig != g_sig_pushed && fileio_open_writers() == 0) push(s); });
}

/* before the game starts: take the newer of the two copies */
void host_cloud_start(const char *overlay){
    @autoreleasepool {
        /* ubiquityIdentityToken is iCloud Drive's and tvOS has none, so there is no check that the
         * Apple TV is signed in: without an account the store keeps the values here and nothing goes up */
        g_dir = [NSString stringWithUTF8String:overlay];
        NSUbiquitousKeyValueStore *kv = NSUbiquitousKeyValueStore.defaultStore;
        [kv synchronize];
        Scan loc = scan();
        NSData *cloud = [kv dataForKey:KEY_DATA];
        /* a new install: the store fills a moment after the app first asks */
        for (int i = 0; i < 40 && !cloud && !loc.n; i++){
            [NSThread sleepForTimeInterval:0.1];
            [kv synchronize];
            cloud = [kv dataForKey:KEY_DATA];
        }
        double ct = [kv doubleForKey:KEY_TIME];
        if (cloud && ct > loc.newest + 1.0){
            fprintf(stderr, "icloud: the cloud copy is newer (%.0f > %.0f): unpacking %lu bytes\n", ct, loc.newest, (unsigned long)cloud.length);
            if (!unpack(cloud)) fprintf(stderr, "icloud: the cloud copy is not readable: the local files stay\n");
            loc = scan();
        } else fprintf(stderr, "icloud: %s\n", cloud ? "the files here are the newer ones" : "nothing in the cloud yet");
        g_sig_seen = loc.sig;
        g_sig_pushed = (cloud && ct >= loc.newest - 1.0) ? loc.sig : 0;
        g_q = dispatch_queue_create("nfsu2 icloud", DISPATCH_QUEUE_SERIAL);
        g_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, g_q);
        dispatch_source_set_timer(g_timer, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), 3 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(g_timer, ^{ @autoreleasepool { tick(); } });
        dispatch_resume(g_timer);
    }
}
