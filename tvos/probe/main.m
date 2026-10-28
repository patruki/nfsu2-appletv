/* tvOS probe: answers the open questions of the Apple TV port on the device
 * itself, before any game code is built for it.
 *   1. how much address space the app may reserve (the Mac build reserves 4 GB
 *      in runtime/mem.c; the browser build fits in 640 MB, GUEST_END in cpu.h)
 *   2. whether the 1 GB stack of the guest thread (tests/boot.c) can be made
 *   3. whether the GPU takes the BC/DXT textures the game uploads
 *      (runtime/metal.m, the DXT cases), and its Metal family
 *   4. memory the system lets us use (os_proc_available_memory)
 *   5. which controllers connect, and their buttons
 * The result is shown on screen and written to the log (NSLog). */
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <GameController/GameController.h>
#import <QuartzCore/CAMetalLayer.h>
#include <os/proc.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/sysctl.h>

static NSMutableString *g_out;
static void say(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void say(NSString *fmt, ...){
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"probe: %@", s);
    [g_out appendFormat:@"%@\n", s];
}

/* 1. Reserve PROT_NONE like mem_init(), then make a part of it usable like
 * mem_commit() and touch every page. */
static void probe_reserve(void){
    static const uint64_t mb[] = { 4096, 3072, 2048, 1024, 640 };
    for (size_t i = 0; i < sizeof mb / sizeof *mb; i++){
        uint64_t sz = mb[i] << 20;
        void *p = mmap(0, sz, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
        if (p == MAP_FAILED){ say(@"reserve %llu MB: FAILED (%s)", mb[i], strerror(errno)); continue; }
        say(@"reserve %llu MB PROT_NONE: ok", mb[i]);
        uint64_t use = 256ull << 20;
        if (use > sz) use = sz;
        if (mprotect(p, use, PROT_READ | PROT_WRITE) != 0){
            say(@"  make %llu MB usable: FAILED (%s)", use >> 20, strerror(errno));
        } else {
            for (uint64_t o = 0; o < use; o += 0x4000) ((volatile uint8_t *)p)[o] = 1;
            say(@"  make %llu MB usable and touch it: ok", use >> 20);
        }
        say(@"  vm page size %d bytes", (int)vm_page_size);
        munmap(p, sz);
        break;     /* the largest that works is what the port can ask for */
    }
}

/* 2. A thread with a 1 GB stack, deep recursion into it. */
static void *deep(void *arg){
    volatile char buf[64 * 1024];
    size_t n = (size_t)arg;
    buf[0] = (char)n;
    return n ? deep((void *)(n - 1)) : (void *)(uintptr_t)buf[0];
}
static void probe_stack(void){
    pthread_attr_t at; pthread_attr_init(&at);
    int r = pthread_attr_setstacksize(&at, 1024ull << 20);
    pthread_t th = 0;
    r = r ?: pthread_create(&th, &at, deep, (void *)(size_t)4096);   /* 4096 x 64 KB = 256 MB used */
    if (r){ say(@"1 GB stack thread: FAILED (%s)", strerror(r)); return; }
    pthread_join(th, 0);
    say(@"1 GB stack thread, 256 MB of it used: ok");
}

/* 3. The GPU. */
static id<MTLDevice> probe_gpu(void){
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    if (!d){ say(@"Metal: no device"); return nil; }
    say(@"GPU: %@", d.name);
    struct { MTLGPUFamily f; const char *n; } fam[] = {
        { MTLGPUFamilyApple4, "Apple4" }, { MTLGPUFamilyApple5, "Apple5" },
        { MTLGPUFamilyApple6, "Apple6" }, { MTLGPUFamilyApple7, "Apple7" },
        { MTLGPUFamilyApple8, "Apple8" } };
    for (size_t i = 0; i < sizeof fam / sizeof *fam; i++)
        if ([d supportsFamily:fam[i].f]) say(@"  family %s: yes", fam[i].n);
    BOOL bc = NO;
    if (@available(tvOS 16.4, *)) bc = d.supportsBCTextureCompression;
    say(@"BC/DXT textures: %@", bc ? @"supported" : @"NOT supported (DXT must be converted: web/src/gpu/astc.ts)");
    if (bc){
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBC1_RGBA
                                                                                       width:256 height:256 mipmapped:YES];
        say(@"  BC1 texture created: %@", [d newTextureWithDescriptor:td] ? @"ok" : @"FAILED");
    }
    say(@"max buffer %llu MB, working set %llu MB", (unsigned long long)d.maxBufferLength >> 20, (unsigned long long)d.recommendedMaxWorkingSetSize >> 20);
    return d;
}

/* The pad. */
static UILabel *g_label;
static void show(void){
    NSMutableString *s = [g_out mutableCopy];
    [s appendFormat:@"\navailable memory now: %llu MB\n", (unsigned long long)os_proc_available_memory() >> 20];
    NSArray<GCController *> *cs = [GCController controllers];
    [s appendFormat:@"controllers: %lu\n", (unsigned long)cs.count];
    for (GCController *c in cs){
        GCExtendedGamepad *g = c.extendedGamepad;
        [s appendFormat:@"  %@ [%@] player %ld haptics:%@\n", c.vendorName, c.productCategory,
            (long)c.playerIndex, c.haptics ? @"yes" : @"no"];
        if (g) [s appendFormat:@"    L(%.2f %.2f) R(%.2f %.2f) LT %.2f RT %.2f  A%d B%d X%d Y%d  LB%d RB%d  menu%d\n",
            g.leftThumbstick.xAxis.value, g.leftThumbstick.yAxis.value,
            g.rightThumbstick.xAxis.value, g.rightThumbstick.yAxis.value,
            g.leftTrigger.value, g.rightTrigger.value,
            g.buttonA.pressed, g.buttonB.pressed, g.buttonX.pressed, g.buttonY.pressed,
            g.leftShoulder.pressed, g.rightShoulder.pressed, g.buttonMenu.pressed];
    }
    g_label.text = s;
}

/* GCEventViewController with controller user interaction off: the pad's B and
 * Menu do not take the app to the Apple TV home screen (they would in a game). */
@interface ProbeVC : GCEventViewController @end
@implementation ProbeVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.controllerUserInteractionEnabled = NO;
    self.view.backgroundColor = UIColor.blackColor;
    g_label = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 80, 60)];
    g_label.numberOfLines = 0;
    g_label.font = [UIFont monospacedSystemFontOfSize:26 weight:UIFontWeightRegular];
    g_label.textColor = UIColor.whiteColor;
    g_label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:g_label];
    /* a CAMetalLayer on screen, the way the game's view will be */
    CAMetalLayer *ml = [CAMetalLayer layer];
    ml.device = MTLCreateSystemDefaultDevice();
    ml.pixelFormat = MTLPixelFormatBGRA8Unorm;
    ml.frame = CGRectMake(self.view.bounds.size.width - 360, 40, 320, 180);
    [self.view.layer addSublayer:ml];
    say(@"screen %.0fx%.0f pt, scale %.0f, max %ld Hz",
        UIScreen.mainScreen.bounds.size.width, UIScreen.mainScreen.bounds.size.height,
        UIScreen.mainScreen.scale, (long)UIScreen.mainScreen.maximumFramesPerSecond);
    CADisplayLink *l = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [l addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)tick:(CADisplayLink *)l { show(); }
@end

/* The SDK requires the UIScene life cycle (the app fails to launch without it):
 * the window belongs to a scene, which Info.plist names (UIApplicationSceneManifest). */
@interface ProbeApp : UIResponder <UIApplicationDelegate> @end
@implementation ProbeApp
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    g_out = [NSMutableString string];
    probe_reserve(); probe_stack(); probe_gpu();
    say(@"os says %llu MB available at launch", (unsigned long long)os_proc_available_memory() >> 20);
    return YES;
}
@end

@interface ProbeScene : UIResponder <UIWindowSceneDelegate> @property (nonatomic, strong) UIWindow *window; @end
@implementation ProbeScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)opts {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [ProbeVC new];
    [self.window makeKeyAndVisible];
}
@end

int main(int argc, char **argv){
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([ProbeApp class])); }
}
