// iOS input: game controllers (GameController framework, through the controls mapping of
// input_map.h) and the touch controls (ios_touch.mm), merged into one GamePad state.
#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <mutex>

#include "input.h"
#include "input_map.h"
#include "ios_shell.h"
#include "runtime.h"

namespace mods { void filter_pad(input::PadState& s); }  // mods/camera.cpp

namespace input {

static std::mutex g_mu;
static PadState g_pad;                  // controller part, refreshed on the main thread
static float g_values[input_map::kPadCount];
static bool g_touch;
static float g_tx, g_ty;
static std::atomic<uint32_t> g_auto{0};

void set_touch(bool down, float x, float y) {
    std::lock_guard<std::mutex> lk(g_mu);
    g_touch = down;
    g_tx = x;
    g_ty = y;
}

void set_auto_buttons(uint32_t bits) { g_auto = bits; }

// every mappable controller input, 0..1, the strongest over all connected controllers
void controller_values(float* v) {
    using namespace input_map;
    for (int i = 0; i < kPadCount; i++) v[i] = 0;
    auto put = [&](int p, float x) { if (x > v[p]) v[p] = x; };
    for (GCController* c in [GCController controllers]) {
        GCExtendedGamepad* g = c.extendedGamepad;
        if (!g) continue;
        auto b = [&](GCControllerButtonInput* in, int p) {
            if (in) put(p, in.isPressed ? std::max(in.value, 0.51f) : std::min(in.value, 0.5f));
        };
        b(g.buttonA, kPadA); b(g.buttonB, kPadB); b(g.buttonX, kPadX); b(g.buttonY, kPadY);
        b(g.leftShoulder, kPadLB); b(g.rightShoulder, kPadRB);
        b(g.leftTrigger, kPadLT); b(g.rightTrigger, kPadRT);
        b(g.buttonMenu, kPadMenu); b(g.buttonOptions, kPadOptions); b(g.buttonHome, kPadHome);
        b(g.leftThumbstickButton, kPadL3); b(g.rightThumbstickButton, kPadR3);
        b(g.dpad.up, kPadDUp); b(g.dpad.down, kPadDDown); b(g.dpad.left, kPadDLeft); b(g.dpad.right, kPadDRight);
        auto stick = [&](GCControllerDirectionPad* d, int up, int down, int left, int right) {
            float x = d.xAxis.value, y = d.yAxis.value;
            put(right, std::max(x, 0.f)); put(left, std::max(-x, 0.f));
            put(up, std::max(y, 0.f)); put(down, std::max(-y, 0.f));
        };
        stick(g.leftThumbstick, kPadLSUp, kPadLSDown, kPadLSLeft, kPadLSRight);
        stick(g.rightThumbstick, kPadRSUp, kPadRSDown, kPadRSLeft, kPadRSRight);
    }
}

void host_controller_values(float* v) {
    std::lock_guard<std::mutex> lk(g_mu);
    for (int i = 0; i < input_map::kPadCount; i++) v[i] = g_values[i];
}

void held_keys(bool* keys) { for (int i = 0; i < 256; i++) keys[i] = false; }
void release_keys() {}

static void update_controller_ui() {
    bool any = false;
    for (GCController* c in [GCController controllers])
        if (c.extendedGamepad) any = true;
    static const bool always_touch = getenv("WWHD_TOUCH_ALWAYS") != nullptr;
    ios::set_touch_controls_hidden(any && !always_touch);
    for (GCController* c in [GCController controllers]) {
        // the Home / PS button belongs to the game (input_map's kPadHome), not the system
        if (@available(iOS 14.0, *)) {
            if (c.extendedGamepad.buttonHome) c.extendedGamepad.buttonHome.preferredSystemGestureState = GCSystemGestureStateDisabled;
            if (c.extendedGamepad.buttonMenu) c.extendedGamepad.buttonMenu.preferredSystemGestureState = GCSystemGestureStateDisabled;
            if (c.extendedGamepad.buttonOptions) c.extendedGamepad.buttonOptions.preferredSystemGestureState = GCSystemGestureStateDisabled;
        }
    }
}

void init() {
    input_map::load_startup();
    dispatch_async(dispatch_get_main_queue(), ^{
        GCController.shouldMonitorBackgroundEvents = NO;
        for (NSNotificationName n in @[ GCControllerDidConnectNotification, GCControllerDidDisconnectNotification ])
            [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:nil
                                                          usingBlock:^(NSNotification* note) {
                GCController* c = note.object;
                LOG("[input] controller %s: %s", n == GCControllerDidConnectNotification ? "connected" : "disconnected",
                    c.vendorName.UTF8String ?: "?");
                update_controller_ui();
            }];
        update_controller_ui();
        // GameController values are polled on the main thread
        [NSTimer scheduledTimerWithTimeInterval:1.0 / 240 repeats:YES block:^(NSTimer*) {
            float v[input_map::kPadCount];
            controller_values(v);
            PadState s = input_map::controller_state(input_map::current(), v);
            std::lock_guard<std::mutex> lk(g_mu);
            g_pad = s;
            for (int i = 0; i < input_map::kPadCount; i++) g_values[i] = v[i];
        }];
    });
}

static std::atomic<bool> g_pro{getenv("WWHD_PRO_CONTROLLER") != nullptr};
bool pro_controller() { return g_pro.load(std::memory_order_relaxed); }
void set_pro_controller(bool on) { g_pro = on; LOG("[input] controllers act as %s", on ? "Pro Controller" : "GamePad"); }

PadState read(bool) {
    ios::TouchPad t = ios::touch_pad();
    PadState s;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        s = g_pad;
        s.touch = g_touch;
        s.tx = g_tx;
        s.ty = g_ty;
    }
    s.buttons |= t.buttons | g_auto.load(std::memory_order_relaxed);
    if (t.lx || t.ly) { s.lx = t.lx; s.ly = t.ly; }
    if (t.rx || t.ry) { s.rx = t.rx; s.ry = t.ry; }
    mods::filter_pad(s);
    return s;
}

// GamePad rumble: a short haptic tap per pattern (the phone has one motor and no level control)
void rumble(const uint8_t* pattern, int bits) {
    if (bits <= 0 || !pattern) return;
    bool on = false;
    for (int i = 0; i < (bits + 7) / 8 && !on; i++) on = pattern[i] != 0;
    if (!on) return;
    static std::atomic<int64_t> last{0};
    int64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
    if (now - last.load() < 120) return;
    last = now;
    dispatch_async(dispatch_get_main_queue(), ^{
        static UIImpactFeedbackGenerator* g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [g impactOccurred];
    });
}
void rumble_hold(bool) {}

// software keyboard (naming the save file, Tingle Tuner messages...)
void prompt_text(const std::u16string& initial, int max_len, std::function<void(bool ok, std::u16string text)> done) {
    NSString* init = [NSString stringWithCharacters:(const unichar*)initial.data() length:initial.size()];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController* a = [UIAlertController alertControllerWithTitle:@"Enter text"
                                                                   message:[NSString stringWithFormat:@"Up to %d characters.", max_len]
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField* f) { f.text = init; }];
        auto finish = [done, max_len](bool ok, NSString* t) {
            std::u16string out(t.length, u'\0');
            [t getCharacters:(unichar*)out.data() range:NSMakeRange(0, t.length)];
            if ((int)out.size() > max_len) out.resize(max_len);
            done(ok, out);
        };
        UIAlertController* __weak wa = a;
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction*) {
            finish(false, wa.textFields.firstObject.text ?: @"");
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
            finish(true, wa.textFields.firstObject.text ?: @"");
        }]];
        [ios::root_view_controller() presentViewController:a animated:YES completion:nil];
    });
}

}  // namespace input
