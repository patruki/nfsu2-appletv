/* tvOS host: the UIKit app around the game.
 *
 * The main thread belongs to UIApplicationMain.  The scene makes the view with its CAMetalLayer
 * there, tells metal.m the screen and hands over the layer, then starts the boot thread:
 * tests/boot.c's main() (compiled as nfsu2_boot) runs the game on its own thread and, being the
 * thread that called it, turns into the render loop (metal_run_main_loop). */
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <QuartzCore/CAMetalLayer.h>
#include <pthread.h>

void metal_tv_set_screen(int w, int h, int hz);
void metal_early_init(void);
void metal_tv_attach(CAMetalLayer *layer);
void metal_tv_reapply_drawable(void);
int  nfsu2_boot(int argc, char **argv);
void nfsu2_remote_start(void);
void lifecycle_set_active(int on, const char *why);
void host_cloud_flush(void);

/* the view: a CAMetalLayer that fills the screen; UIKit resets a layer's drawable size when it
 * lays the view out, so the size metal.m chose is put back */
@interface NFSUView : UIView @end
@implementation NFSUView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (void)layoutSubviews { [super layoutSubviews]; metal_tv_reapply_drawable(); }
@end

/* controllerUserInteractionEnabled = NO: a pad's B and Menu button go to the game, not to the
 * Apple TV's home screen */
@interface NFSUController : GCEventViewController @end
@implementation NFSUController
- (void)loadView { self.view = [[NFSUView alloc] initWithFrame:UIScreen.mainScreen.bounds]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.controllerUserInteractionEnabled = NO;
    self.view.backgroundColor = UIColor.blackColor;
}
@end

static void *boot_thread(void *arg){
    (void)arg;
    pthread_setname_np("nfsu2 boot");
    static char *argv[] = { (char *)"NFSU2", NULL };
    int rc = nfsu2_boot(1, argv);
    fprintf(stderr, "app: the game ended (%d)\n", rc);
    exit(rc);
    return NULL;
}

@interface NFSUApp : UIResponder <UIApplicationDelegate> @end
@implementation NFSUApp
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    /* the Apple TV sleeps after a while without input; a game is played with a pad that does not count */
    a.idleTimerDisabled = YES;
    nfsu2_remote_start();                      /* development: keys from the Mac (tvos/tools/keyrelay.py) */
    return YES;
}
@end

@interface NFSUScene : UIResponder <UIWindowSceneDelegate> @property (nonatomic, strong) UIWindow *window; @end
@implementation NFSUScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)opts {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    UIWindowScene *ws = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:ws];
    NFSUController *vc = [NFSUController new];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];

    /* points are used as pixels (scale 1): the drawable has the size of the game's surface (1080p
     * here), the Apple TV scales it to its output */
    CGSize pt = ws.screen.bounds.size;
    metal_tv_set_screen((int)pt.width, (int)pt.height, (int)ws.screen.maximumFramesPerSecond);
    metal_early_init();
    metal_tv_attach((CAMetalLayer *)vc.view.layer);

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pthread_attr_t at; pthread_attr_init(&at);
        pthread_attr_setstacksize(&at, 16u << 20);
        pthread_t th;
        if (pthread_create(&th, &at, boot_thread, NULL) != 0) fprintf(stderr, "app: the boot thread could not be created\n");
        else pthread_detach(th);
    });
}
/* the game pauses when the app is not in front (Home, the screensaver), as a Windows game does */
- (void)sceneDidBecomeActive:(UIScene *)s { lifecycle_set_active(1, "scene became active"); }
- (void)sceneWillResignActive:(UIScene *)s { lifecycle_set_active(0, "scene will resign active"); }
- (void)sceneDidEnterBackground:(UIScene *)s { host_cloud_flush(); }
@end

int nfsu2_tv_run(int argc, char **argv){
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([NFSUApp class])); }
}
