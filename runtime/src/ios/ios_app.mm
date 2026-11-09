// iOS shell: the app, its views and the game's start.
//
// The renderer (runtime/src/gfx, the macOS Metal backend) draws into two CAMetalLayers made here:
// the TV picture full screen and the GamePad picture as an inset, full screen or hidden (the touch
// controls' ≡ menu). Touches on the GamePad picture are the GamePad's touch panel.
// Touch controls (ios_touch.mm) sit on top and hide while a game controller is connected.
//
// Files (the app's Documents folder, visible in the Files app and Finder):
//   game/      the extracted game (code/, content/, meta/), when it isn't inside the app
//   save/      save data          states/  save states         captures/  crash logs
//   log.txt    this run's log (log-prev.txt: the run before)
//   env.txt    optional KEY=VALUE lines, set as environment variables before the game starts
//              (the WWHD_* debug and tuning switches); an env.txt inside the app is read first
#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include <sys/stat.h>
#include <unistd.h>

#include <string>
#include <thread>

#include "gx2/gx2.h"
#include "ios_shell.h"
#include "metal.h"
#include "platform.h"
#include "runtime.h"

using gfx::R;

namespace {
gfx::Screen* g_tv_screen = nullptr;
gfx::Screen* g_drc_screen = nullptr;
std::atomic<int> g_drc_mode{0};  // 0 inset, 1 full screen, 2 hidden
std::string g_missing_game;      // why the game can't start (shown instead of it)

bool file_exists(const std::string& p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0;
}

void load_env_file(const std::string& path) {
    FILE* f = fopen(path.c_str(), "r");
    if (!f) return;
    char line[1024];
    while (fgets(line, sizeof line, f)) {
        std::string s(line);
        while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' ')) s.pop_back();
        if (s.empty() || s[0] == '#') continue;
        size_t eq = s.find('=');
        if (eq == std::string::npos || eq == 0) continue;
        setenv(s.substr(0, eq).c_str(), s.substr(eq + 1).c_str(), 1);
    }
    fclose(f);
}
}  // namespace

// ---------------------------------------------------------------- Metal views
@interface WWMetalView : UIView
@property(nonatomic, assign) gfx::Screen* screen;
@end
@implementation WWMetalView
+ (Class)layerClass { return [CAMetalLayer class]; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = UIColor.blackColor;
        CAMetalLayer* l = (CAMetalLayer*)self.layer;
        l.pixelFormat = MTLPixelFormatBGRA8Unorm;
        l.framebufferOnly = YES;
        l.maximumDrawableCount = 3;
        l.opaque = YES;
    }
    return self;
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window) self.contentScaleFactor = self.window.screen.nativeScale;
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer* l = (CAMetalLayer*)self.layer;
    CGFloat s = self.contentScaleFactor;
    CGSize sz = self.bounds.size;
    if (sz.width > 0 && sz.height > 0) l.drawableSize = CGSizeMake(sz.width * s, sz.height * s);
}
@end

// GamePad screen: touches are the GamePad's touch panel
@interface WWDrcView : WWMetalView
@end
@implementation WWDrcView
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = NO;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.35].CGColor;
        self.layer.borderWidth = 1;
    }
    return self;
}
- (void)touch:(UITouch*)t down:(bool)down {
    CGPoint p = [t locationInView:self];
    CGSize sz = self.bounds.size;
    // the image is letterboxed to 16:9 inside the view (present() in metal_main.mm)
    float a = 854.0f / 480.0f, w = sz.width, h = sz.height, x0 = 0, y0 = 0;
    if (w / h > a) { x0 = (w - h * a) / 2; w = h * a; } else { y0 = (h - w / a) / 2; h = w / a; }
    float x = (p.x - x0) / w, y = (p.y - y0) / h;
    input::set_touch(down, std::clamp(x, 0.0f, 1.0f), std::clamp(y, 0.0f, 1.0f));
}
- (void)touchesBegan:(NSSet<UITouch*>*)ts withEvent:(UIEvent*)e { [self touch:ts.anyObject down:true]; }
- (void)touchesMoved:(NSSet<UITouch*>*)ts withEvent:(UIEvent*)e { [self touch:ts.anyObject down:true]; }
- (void)touchesEnded:(NSSet<UITouch*>*)ts withEvent:(UIEvent*)e { [self touch:ts.anyObject down:false]; }
- (void)touchesCancelled:(NSSet<UITouch*>*)ts withEvent:(UIEvent*)e { [self touch:ts.anyObject down:false]; }
@end

// ---------------------------------------------------------------- view controller
@interface WWViewController : UIViewController
@property(nonatomic, strong) WWMetalView* tv;
@property(nonatomic, strong) WWDrcView* drc;
@property(nonatomic, strong) UIView* controls;
@end

@implementation WWViewController
- (void)loadView {
    UIView* root = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    root.backgroundColor = UIColor.blackColor;
    self.view = root;
    if (!g_missing_game.empty()) {
        UILabel* l = [UILabel new];
        l.text = [NSString stringWithUTF8String:g_missing_game.c_str()];
        l.textColor = UIColor.whiteColor;
        l.numberOfLines = 0;
        l.textAlignment = NSTextAlignmentCenter;
        l.font = [UIFont systemFontOfSize:15];
        l.frame = CGRectInset(root.bounds, 40, 40);
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [root addSubview:l];
        return;
    }
    self.tv = [[WWMetalView alloc] initWithFrame:root.bounds];
    [root addSubview:self.tv];
    if (@available(iOS 16.0, *))
        if ([NSUserDefaults.standardUserDefaults boolForKey:@"metalHud"])
            ((CAMetalLayer*)self.tv.layer).developerHUDProperties = @{@"mode": @"default", @"logging": @"default"};
    self.drc = [[WWDrcView alloc] initWithFrame:CGRectZero];
    [root addSubview:self.drc];
    self.controls = ios::make_touch_controls(root.bounds);
    [root addSubview:self.controls];

    // GamePad layout of the last run
    g_drc_mode = (int)[NSUserDefaults.standardUserDefaults integerForKey:@"drcMode"] % 3;
}

- (void)setDrcMode:(int)m {
    g_drc_mode = m % 3;
    [NSUserDefaults.standardUserDefaults setInteger:m % 3 forKey:@"drcMode"];
    [UIView animateWithDuration:0.15 animations:^{ [self layoutGame]; }];
}

- (void)layoutGame {
    if (!self.tv) return;
    CGRect b = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    self.tv.frame = b;
    self.controls.frame = b;
    // test aid: WWHD_IOS_PREVIEW_ASPECT=2.22 lays the controls out in a box of that width:height
    // ratio (a 20:9 phone in a squarer Simulator)
    if (const char* pa = getenv("WWHD_IOS_PREVIEW_ASPECT"); pa && atof(pa) > 0) {
        CGFloat h = std::min(b.size.height, b.size.width / atof(pa));
        self.controls.frame = CGRectMake(0, std::round((b.size.height - h) / 2), b.size.width, h);
        self.controls.layer.borderColor = UIColor.darkGrayColor.CGColor;
        self.controls.layer.borderWidth = 1;
    }
    int m = g_drc_mode.load();
    CGRect drc = CGRectZero;
    if (m == 0) {
        // top centre, a quarter of the width: clear of the shoulder buttons in the corners
        CGFloat w = std::round(b.size.width * 0.26), h = std::round(w * 480.0 / 854.0);
        drc = CGRectMake(std::round((b.size.width - w) / 2), std::max<CGFloat>(safe.top, 4), w, h);
    } else if (m == 1) {
        drc = b;
    }
    self.drc.hidden = m == 2;
    if (m != 2) self.drc.frame = drc;
    if (g_drc_screen) g_drc_screen->visible = m != 2;
    ios::set_touch_controls_drc_rect(self.controls, m == 2 ? CGRectZero : drc, m == 1);
    [self.view bringSubviewToFront:self.controls];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutGame];
}
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
// a controller's Home/Options buttons belong to the game
- (BOOL)prefersPointerLocked { return YES; }
@end

// ---------------------------------------------------------------- app and scene delegates
static WWViewController* g_vc = nil;

@interface WWAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation WWAppDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)opts {
    AVAudioSession* s = AVAudioSession.sharedInstance;
    [s setCategory:AVAudioSessionCategoryAmbient error:nil];  // respects the silent switch, mixes with other audio
    if (getenv("WWHD_AUDIO_PLAYBACK")) [s setCategory:AVAudioSessionCategoryPlayback error:nil];
    [s setPreferredSampleRate:48000 error:nil];
    [s setPreferredIOBufferDuration:0.01 error:nil];
    [s setActive:YES error:nil];
    app.idleTimerDisabled = YES;
    return YES;
}
- (UISceneConfiguration*)application:(UIApplication*)app configurationForConnectingSceneSession:(UISceneSession*)session
                             options:(UISceneConnectionOptions*)options {
    UISceneConfiguration* c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    c.delegateClass = NSClassFromString(@"WWSceneDelegate");
    return c;
}
@end

// one window scene: the game
@interface WWSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow* window;
@end
@implementation WWSceneDelegate
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options {
    static bool started = false;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    if (!g_vc) g_vc = [WWViewController new];
    self.window.rootViewController = g_vc;
    [self.window makeKeyAndVisible];
    if (g_missing_game.empty() && !started && !getenv("WWHD_IOS_UI_PREVIEW")) {
        started = true;
        std::thread([] {
            platform::set_thread_name("boot");
            boot_runtime();
            ios::set_game_live();
            gfx::init();  // calls ios_create_layers
            start_game_thread();
        }).detach();
    }
}
- (void)sceneWillResignActive:(UIScene*)scene {
    platform::set_game_paused(true);
    input::release_keys();
}
- (void)sceneDidEnterBackground:(UIScene*)scene {
    // no drawables in the background: nextDrawable would wait for them
    if (g_tv_screen) g_tv_screen->visible = false;
    if (g_drc_screen) g_drc_screen->visible = false;
}
- (void)sceneWillEnterForeground:(UIScene*)scene {
    if (g_tv_screen) g_tv_screen->visible = true;
    if (g_drc_screen) g_drc_screen->visible = g_drc_mode.load() != 2;
}
- (void)sceneDidBecomeActive:(UIScene*)scene { platform::set_game_paused(false); }
@end

// ---------------------------------------------------------------- renderer hooks (metal_main.mm)
namespace gfx {
void ios_create_layers(Screen& tv, Screen& drc) {
    void (^make)(void) = ^{
        WWViewController* vc = g_vc;
        g_tv_screen = &tv;
        g_drc_screen = &drc;
        tv.layer = (CAMetalLayer*)vc.tv.layer;
        drc.layer = (CAMetalLayer*)vc.drc.layer;
        tv.layer.device = R.device;
        drc.layer.device = R.device;
        [vc.view setNeedsLayout];
        [vc.view layoutIfNeeded];
        drc.visible = g_drc_mode.load() != 2;
    };
    if (NSThread.isMainThread) make();
    else dispatch_sync(dispatch_get_main_queue(), make);
}
void ios_run_main_loop() {}  // UIApplicationMain runs the main thread
bool ios_drc_shown() { return g_drc_mode.load() != 2; }
void ios_show_drc(bool on) {
    dispatch_async(dispatch_get_main_queue(), ^{
        int m = on ? (g_drc_mode.load() == 2 ? 0 : g_drc_mode.load()) : 2;
        g_drc_mode = m;
        [g_vc layoutGame];
    });
}
}  // namespace gfx

namespace ios {
UIViewController* root_view_controller() {
    return g_vc;
}
int drc_mode() { return g_drc_mode.load(); }
bool metal_hud() { return [NSUserDefaults.standardUserDefaults boolForKey:@"metalHud"]; }
// on the TV picture's layer (iOS 16+: CAMetalLayer.developerHUDProperties)
static void apply_metal_hud() {
    if (!g_vc.tv) return;
    if (@available(iOS 16.0, *)) {
        CAMetalLayer* l = (CAMetalLayer*)g_vc.tv.layer;
        l.developerHUDProperties = metal_hud() ? @{@"mode": @"default", @"logging": @"default"} : nil;
    }
}
void set_metal_hud(bool on) {
    [NSUserDefaults.standardUserDefaults setBool:on forKey:@"metalHud"];
    apply_metal_hud();
    LOG("[ios] Metal HUD %s", on ? "on" : "off");
}

void set_drc_mode(int m) { [g_vc setDrcMode:m]; }
}  // namespace ios

// ---------------------------------------------------------------- main
int main(int argc, char** argv) {
    @autoreleasepool {
        NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        std::string d = docs.UTF8String;
        // relative paths of the runtime (captures/, the log) land in Documents
        chdir(d.c_str());
        // this run's log in the Files app, the previous run's kept
        rename("log.txt", "log-prev.txt");
        freopen("log.txt", "w", stderr);
        setvbuf(stderr, nullptr, _IOLBF, 0);

        std::string bundle = NSBundle.mainBundle.resourcePath.UTF8String;
        load_env_file(bundle + "/env.txt");
        load_env_file(d + "/env.txt");

        // the game: Documents/game first (replaceable without reinstalling), then the copy in the app
        if (file_exists(d + "/game/code/cking.rpx")) config::game_dir = d + "/game";
        else if (file_exists(bundle + "/game/code/cking.rpx")) config::game_dir = bundle + "/game";
        else
            g_missing_game =
                "The game files were not found.\n\n"
                "Copy the extracted game folder (with code/, content/ and meta/ inside) to this app's "
                "folder as \"game\" (Files app: On My iPhone > Wind Waker HD, or Finder on a Mac), "
                "then open the app again.\n\nThe game code in this app was built from one game "
                "version: the files must come from the same disc.";
        // WWHD_IOS_UI_PREVIEW=1 (env.txt): the controls and GamePad inset over a black screen, no game
        static bool preview = getenv("WWHD_IOS_UI_PREVIEW") != nullptr;
        if (preview) g_missing_game.clear();
        config::save_dir = d + "/save";
        mkdir(config::save_dir.c_str(), 0755);
        mkdir("captures", 0755);
        if (!g_missing_game.empty()) fprintf(stderr, "[ios] no game files in %s/game or the app\n", d.c_str());
        else fprintf(stderr, "[ios] game: %s, saves: %s\n", config::game_dir.c_str(), config::save_dir.c_str());
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([WWAppDelegate class]));
    }
}
