/* tvOS counterpart of runtime/bundle.m: where the game, its settings and its saves live, and the
 * defaults run.sh gives a terminal run.
 *   the game folder   a folder reference in the app (read only)
 *   everything else   Library/Caches/NFSU2: registry.txt, Overlay (the saves), the log.  tvOS may
 *                     delete the caches when it needs the space, so the saves also live in iCloud
 *                     (host_cloud.m copies the Overlay both ways). */
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

void host_cloud_start(const char *overlay);
void host_profile_adopt(const char *overlay);

static char g_support[1024], g_game[1024];

int app_is_bundled(void){ return 1; }
void app_local_network_notice(void){ }

const char *app_save_dir(void){
    const char *env = getenv("NFSU2_SAVEDIR");
    return (env && *env) ? env : NULL;
}

static void mkdirs(const char *p){
    char t[1200]; snprintf(t, sizeof t, "%s", p);
    for (char *s = t + 1; *s; s++) if (*s == '/'){ *s = 0; mkdir(t, 0755); *s = '/'; }
    mkdir(t, 0755);
}
static void setdef(const char *k, const char *v){ if (!getenv(k)) setenv(k, v, 1); }

static int copy_small(const char *a, const char *b){
    FILE *fa = fopen(a, "rb"); if (!fa) return 0;
    FILE *fb = fopen(b, "wb"); if (!fb){ fclose(fa); return 0; }
    char buf[8192]; size_t k;
    while ((k = fread(buf, 1, sizeof buf, fa)) > 0) fwrite(buf, 1, k, fb);
    fclose(fa);
    return fclose(fb) == 0;
}

void app_setup(void){
    @autoreleasepool {
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        snprintf(g_support, sizeof g_support, "%s/NFSU2", caches ? [caches UTF8String] : "/tmp");
        mkdirs(g_support);
        /* the log: into a file only when asked (NFSU2_LOG_FILE=1), so Xcode's console shows it otherwise */
        const char *lf = getenv("NFSU2_LOG_FILE");
        if (lf && *lf && *lf != '0'){
            char pth[1200], prev[1200];
            snprintf(pth, sizeof pth, "%s/nfsu2.log", g_support);
            snprintf(prev, sizeof prev, "%s/nfsu2.previous.log", g_support);
            rename(pth, prev);
            int fd = open(pth, O_WRONLY | O_CREAT | O_TRUNC, 0644);
            if (fd >= 0){ dup2(fd, 1); dup2(fd, 2); close(fd); }
        }
        setvbuf(stdout, NULL, _IOLBF, 0); setvbuf(stderr, NULL, _IOLBF, 0);
        fprintf(stderr, "=== NFSU2 tvOS ===\napp: support dir %s\n", g_support);

        /* what run.sh exports for a terminal run (bundle.m's app_set_defaults).  ALARM is 0: boot.c's
         * 20 s diagnostic timeout would take the game away from the player. */
        setdef("WINDOW", "1");
        setdef("ALARM", "0");
        setdef("FIXMAT", "0");
        setdef("FIXMAT_MODE", "3");
        setdef("NOMOVIES", "0");
        setdef("SNDSYNC", "1");
        setdef("GPUVS", "1");
        setdef("NFSU2_READONLY_DATA", "1");     /* the bundle is read only anyway */

        char p[1200];
        snprintf(p, sizeof p, "%s/registry.txt", g_support);
        setenv("NFSU2_REGFILE", p, 0);
        struct stat st;
        if (stat(getenv("NFSU2_REGFILE"), &st) != 0){
            NSString *src = [[NSBundle mainBundle] pathForResource:@"registry-defaults" ofType:@"txt"];
            if (src && copy_small([src UTF8String], getenv("NFSU2_REGFILE")))
                fprintf(stderr, "app: first launch, registry seeded from %s\n", [src UTF8String]);
            else fprintf(stderr, "app: no registry yet and no seed: the game will run its first-run check\n");
        }
        snprintf(p, sizeof p, "%s/Overlay", g_support);
        mkdirs(p);
        setenv("NFSU2_SAVEDIR", p, 0);
        host_cloud_start(getenv("NFSU2_SAVEDIR"));       /* a newer cloud copy lands in the Overlay before the game reads it */
        host_profile_adopt(getenv("NFSU2_SAVEDIR"));     /* a profile still called NAME takes the Game Center name */
        if (chdir(g_support) != 0) fprintf(stderr, "app: chdir %s: %s\n", g_support, strerror(errno));
    }
}

/* the game folder is a folder reference in the app, under the name of the folder it was made from
 * ("Game", "NFS Underground 2"...): the first folder of the app's resources that holds SPEED2.EXE */
const char *app_find_game(const char *arg, int remember){
    (void)arg; (void)remember;
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *res = [[NSBundle mainBundle] resourcePath];
        for (NSString *name in [fm contentsOfDirectoryAtPath:res error:nil]){
            NSString *exe = [[res stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"SPEED2.EXE"];
            if ([fm fileExistsAtPath:exe]){
                snprintf(g_game, sizeof g_game, "%s", [exe UTF8String]);
                return g_game;
            }
        }
        return NULL;
    }
}

void app_no_game(void){
    fprintf(stderr, "app: no SPEED2.EXE in the app: add the game folder to the app target as a folder reference\n");
}
