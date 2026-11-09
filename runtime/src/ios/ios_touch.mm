// Touch controls: a port of the Android app's ControlsView (android/.../ControlsView.java) and
// TouchIcons, drawn over the game picture with the same artwork (res/drawable-nodpi, bundled as
// WWHD.app/touch/*.webp).
//
// - a floating left stick (where the thumb lands on the left side), the camera on swipes over the
//   right side (double tap: centre it, pinch: zoom), and an optional fixed camera stick
// - context buttons whose icons follow the game (A, B, ZR, the items on X/Y/R: touch_hud.cpp), lock-on,
//   first person, the D-pad items Link has, pause, and one-touch combat moves (macros of the GamePad
//   combinations); during skippable scenes only a Skip button, and a tap elsewhere is A
// - the ≡ menu (GamePad screen, layout editor, size, opacity, camera, combat buttons, vibration) and
//   the ✎ layout editor: move and resize every control on a grid, remove and put back
// Positions: a screen corner plus offsets in units of a seventh of the shorter side, as on Android.
#import <UIKit/UIKit.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <mutex>
#include <string>
#include <vector>

#include "android/touch_hud.h"
#include "ios_shell.h"
#include "mods/mods.h"
#include "platform.h"

namespace {
std::mutex g_mu;
ios::TouchPad g_pad;
std::atomic<bool> g_live{false};  // the game's memory is there: the HUD state can be read

enum Kind { K_STICK, K_BUTTON, K_MACRO, K_MENU, K_EDIT, K_CAMSTICK, K_SKIP };
enum Move { M_JUMP = 1, M_VERTICAL, M_SPIN, M_DODGE };
enum { HUD_FLAGS, HUD_A, HUD_B, HUD_ZR, HUD_X, HUD_Y, HUD_R };

// TouchIcons' colours
constexpr uint32_t GREEN = 0xFF3CB043, RED = 0xFFD9362B, SKY = 0xFF2F8FD8, VIOLET = 0xFF7E4FC9, AMBER = 0xFFE9A925,
                   ORANGE = 0xFFE8702A, TEAL = 0xFF22A6A0, BONE = 0xFFF1E6C8, NAVY = 0xFF1B2A4A;

// TouchIcons' tables: the codes touch_hud::state reports index these (0 unknown, 1 nothing)
const std::vector<const char*> A_ACTIONS = {nullptr, "bubble_blank_a", "a_talk", "a_look", "a_read", "a_open", "a_door",
    "a_lift", "a_throw", "a_put_down", "a_pick_up", "a_grab", "a_climb", "a_jump", "a_let_go", "a_roll", "a_board_boat",
    "a_leave_boat", "a_stop", "a_put_away", "a_next", "a_parry", "a_swim", "a_drink", "a_generic"};
const std::vector<const char*> B_ACTIONS = {nullptr, "b_empty", "b_sword", "b_cancel", "b_drop"};
const std::vector<const char*> ZR_ACTIONS = {nullptr, "bubble_blank_zr", "zr_shield", "zr_crouch", "zr_grab",
    "zr_boat_jump", "zr_no_sail", "zr_brake"};
const std::vector<const char*> ITEMS = {nullptr, "bubble_empty_item", "item_telescope", "item_sail", "item_swift_sail",
    "item_wind_waker", "item_grappling_hook", "item_spoils_bag", "item_boomerang", "item_deku_leaf",
    "item_tingle_bottle", "item_picto_box", "item_deluxe_picto_box", "item_iron_boots", "item_magic_armor",
    "item_bait_bag", "item_hero_bow", "item_fire_arrow", "item_ice_arrow", "item_light_arrow", "item_bombs",
    "item_bottle_empty", "item_bottle_red_potion", "item_bottle_green_potion", "item_bottle_blue_potion",
    "item_bottle_soup", "item_bottle_half_soup", "item_bottle_water", "item_bottle_forest_water",
    "item_bottle_fairy", "item_bottle_firefly", "item_delivery_bag", "item_hookshot", "item_skull_hammer",
    "item_hyoi_pear", "item_all_purpose_bait"};
const char* at(const std::vector<const char*>& t, int code) { return code > 0 && code < (int)t.size() ? t[code] : nullptr; }

UIColor* col(uint32_t c, CGFloat alpha = 1) {
    return [UIColor colorWithRed:((c >> 16) & 0xFF) / 255.0 green:((c >> 8) & 0xFF) / 255.0 blue:(c & 0xFF) / 255.0
                           alpha:alpha];
}
uint32_t darker(uint32_t c) {
    uint32_t r = ((c >> 16) & 0xFF) * 7 / 10, g = ((c >> 8) & 0xFF) * 7 / 10, b = (c & 0xFF) * 7 / 10;
    return 0xFF000000 | r << 16 | g << 8 | b;
}
float clampf(float v) { return std::max(-1.f, std::min(1.f, v)); }

struct Ctl {
    std::string id;
    Kind kind;
    uint32_t bit;
    uint32_t color;
    std::string label, icon;
    float ax, ox, ay, oy, d;              // default place: (ax * W + ox * u, ay * H + oy * u), diameter d * u
    float fx = NAN, fy = NAN, fd = NAN;   // the user's place: fractions of the view, diameter in base units
    CGFloat cx = 0, cy = 0, r = 0;        // on screen
    bool pressed = false, removed = false;
    bool custom() const { return !std::isnan(fx); }
    bool removable() const { return kind != K_MENU && kind != K_EDIT && kind != K_SKIP; }
    bool hit(CGPoint p, CGFloat slack) const {
        CGFloat rr = r * slack;
        return (p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy) <= rr * rr;
    }
};

struct Step { int ms; uint32_t buttons; bool stick; float sx, sy; };

NSUserDefaults* prefs() { return NSUserDefaults.standardUserDefaults; }
float pref_f(NSString* k, float def) { id v = [prefs() objectForKey:k]; return v ? [v floatValue] : def; }
bool pref_b(NSString* k, bool def) { id v = [prefs() objectForKey:k]; return v ? [v boolValue] : def; }
int pref_i(NSString* k, int def) { id v = [prefs() objectForKey:k]; return v ? [v intValue] : def; }
}  // namespace

@interface WWTouchControls : UIView
- (void)setDrcRect:(CGRect)r full:(bool)full;
- (void)setControlsVisible:(bool)visible;
@end

@implementation WWTouchControls {
    std::vector<Ctl> _ctls;
    NSMutableDictionary<NSString*, id>* _icons;
    NSMapTable<UITouch*, NSNumber*>* _pointers;  // touch -> control index
    UIImpactFeedbackGenerator* _haptic;

    CGRect _drc;
    bool _drcMenu;  // the GamePad picture fills the screen: only A, B and pause stay
    bool _controlsVisible;
    float _scale, _opacity, _camSens;
    bool _haptics, _cameraStick;
    int _combatMode;  // 0 auto (with a sword), 1 always, 2 never
    CGFloat _unit, _baseUnit;

    int32_t _state[touch_hud::kSize];
    NSTimer* _hudTimer;

    bool _menuShown;
    NSTimer* _menuTimer;

    // left stick: the finger's offset from where it went down
    UITouch* _stickTouch;
    CGPoint _stickO;
    float _stickX, _stickY;
    // camera: swipe speed on the right side acts as the right stick
    UITouch* _camTouch;
    CGPoint _camLast, _camDown;
    float _camAccX, _camAccY, _camX, _camY;
    double _lastCamTap;
    NSTimer* _camTimer;
    UITouch* _pinchTouch;
    CGPoint _pinch;
    float _pinchStartDist, _pinchStartZoom, _cameraZoom;
    UITouch* _camStickTouch;
    float _camStickX, _camStickY;
    uint32_t _pulseBits;
    // combat move / sequence in progress
    std::vector<Step> _macro;
    int _macroStep;
    unsigned _macroGen;
    uint32_t _macroBits;
    bool _macroStick;
    float _macroSx, _macroSy;

    // layout editor
    bool _editMode;
    int _editSel;
    UITouch *_editTouch, *_editTouch2;
    bool _editResizing, _editAddOpen;
    CGFloat _editDx, _editDy, _editPinchStart, _editSizeStart;
    CGRect _editReset, _editRemove, _editAdd, _editDone, _editCancel, _editPanel;
    std::vector<CGRect> _panelSlots;
    std::vector<int> _panelCtls;
}

- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    self.multipleTouchEnabled = YES;
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    _icons = [NSMutableDictionary new];
    _pointers = [NSMapTable strongToStrongObjectsMapTable];
    _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    _controlsVisible = true;
    _menuShown = true;
    _cameraZoom = 1;
    _macroStep = -1;
    _editSel = -1;
    memset(_state, 0, sizeof _state);
    using namespace input;
    auto add = [&](const char* id, Kind k, uint32_t bit, uint32_t color, const char* label, const char* icon, float ax,
                   float ox, float ay, float oy, float d) {
        Ctl c;
        c.id = id; c.kind = k; c.bit = bit; c.color = color; c.label = label; c.icon = icon;
        c.ax = ax; c.ox = ox; c.ay = ay; c.oy = oy; c.d = d;
        _ctls.push_back(c);
    };
    add("stick", K_STICK, 0, SKY, "", "stick_base", 0, 2.0f, 1, -1.9f, 2.2f);
    add("camstick", K_CAMSTICK, 0, SKY, "", "stick_base", 1, -6.6f, 1, -1.9f, 2.0f);
    // the D-pad as four buttons: baton, cannon, salvage hook, down
    add("dpad_up", K_BUTTON, kUp, TEAL, "↑", "dpad_up_wind_waker", 0, 1.7f, 0, 2.1f, 0.85f);
    add("dpad_left", K_BUTTON, kLeft, TEAL, "←", "dpad_left_cannon", 0, 1.05f, 0, 2.75f, 0.85f);
    add("dpad_right", K_BUTTON, kRight, TEAL, "→", "dpad_right_grapple", 0, 2.35f, 0, 2.75f, 0.85f);
    add("dpad_down", K_BUTTON, kDown, TEAL, "↓", "dpad_down", 0, 1.7f, 0, 3.4f, 0.85f);
    add("zl", K_BUTTON, kZL, VIOLET, "ZL", "zl_target", 0, 1.1f, 0, 0.9f, 1.2f);
    add("zr", K_BUTTON, kZR, AMBER, "ZR", "zr_shield", 1, -1.1f, 0, 0.9f, 1.2f);
    add("fp", K_BUTTON, kStickR, BONE, "◉", "btn_first_person", 1, -2.6f, 0, 0.9f, 0.9f);
    add("a", K_BUTTON, kA, GREEN, "A", "bubble_blank_a", 1, -1.3f, 1, -1.9f, 1.5f);
    add("b", K_BUTTON, kB, RED, "B", "b_sword", 1, -2.9f, 1, -1.2f, 1.25f);
    add("x", K_BUTTON, kX, SKY, "X", "bubble_empty_item", 1, -0.9f, 1, -3.7f, 1.05f);
    add("y", K_BUTTON, kY, SKY, "Y", "bubble_empty_item", 1, -2.3f, 1, -3.4f, 1.05f);
    add("r", K_BUTTON, kR, SKY, "R", "bubble_empty_item", 1, -3.6f, 1, -2.6f, 1.05f);
    add("jump", K_MACRO, M_JUMP, ORANGE, "⤒", "combat_jump_attack", 1, -3.8f, 1, -4.3f, 0.95f);
    add("vertical", K_MACRO, M_VERTICAL, ORANGE, "⇓", "combat_vertical_slash", 1, -4.7f, 1, -3.3f, 0.95f);
    add("spin", K_MACRO, M_SPIN, ORANGE, "⟳", "combat_spin_attack", 1, -4.9f, 1, -2.1f, 0.95f);
    add("dodge", K_MACRO, M_DODGE, ORANGE, "⇆", "combat_dodge", 1, -4.4f, 1, -0.9f, 0.95f);
    add("pause", K_BUTTON, kPlus, BONE, "❚❚", "btn_pause", 0.5f, -0.9f, 1, -0.5f, 0.75f);
    // during skippable scenes the only control: + twice (the game asks "Skip?" on the first)
    add("skip", K_SKIP, kPlus, BONE, "", "", 1, -1.6f, 1, -0.9f, 1.0f);
    add("menu", K_MENU, 0, BONE, "≡", "btn_menu", 0.5f, 0, 1, -0.5f, 0.75f);
    add("edit", K_EDIT, 0, BONE, "✎", "btn_layout_edit", 0.5f, 0.9f, 1, -0.5f, 0.75f);
    [self loadPrefs];
    [self setLayout:[prefs() stringForKey:@"touch.layout"]];
    [self touched];
    _hudTimer = [NSTimer timerWithTimeInterval:0.1 target:self selector:@selector(pollHud) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:_hudTimer forMode:NSRunLoopCommonModes];
    return self;
}

- (void)loadPrefs {
    _scale = pref_f(@"touch.scale", 1);
    _opacity = pref_f(@"touch.opacity", 0.45f);
    _camSens = pref_f(@"touch.cameraSensitivity", 1);
    _haptics = pref_b(@"touch.haptics", true);
    _combatMode = pref_i(@"touch.combat", 0);
    _cameraStick = pref_b(@"touch.cameraStick", true);
    if (!_cameraStick) _camStickTouch = nil;
    [self layoutControls];
    [self setNeedsDisplay];
}

// ---------------------------------------------------------------- icons (TouchIcons)
- (UIImage*)icon:(const std::string&)name {
    if (name.empty()) return nil;
    NSString* k = [NSString stringWithUTF8String:name.c_str()];
    id v = _icons[k];
    if (!v) {
        NSString* p = [NSBundle.mainBundle pathForResource:k ofType:@"webp" inDirectory:@"touch"];
        UIImage* img = p ? [UIImage imageWithContentsOfFile:p] : nil;
        v = img ?: (id)NSNull.null;
        _icons[k] = v;
    }
    return v == NSNull.null ? nil : v;
}

static void draw_text(NSString* s, CGFloat cx, CGFloat cy, CGFloat size, UIColor* color, UIColor* outline = nil,
                      CGFloat outlineW = 0) {
    NSMutableDictionary* a = [@{NSFontAttributeName: [UIFont boldSystemFontOfSize:size],
                                NSForegroundColorAttributeName: color} mutableCopy];
    if (outline) {
        a[NSStrokeColorAttributeName] = outline;
        a[NSStrokeWidthAttributeName] = @(-outlineW);  // negative: fill and stroke
    }
    CGSize sz = [s sizeWithAttributes:a];
    [s drawAtPoint:CGPointMake(cx - sz.width / 2, cy - sz.height / 2) withAttributes:a];
}

// the icon `name` as a bubble of radius r; without its artwork a bubble of `color` with `label`.
// alpha 0..255; pressed darkens it
- (void)drawIcon:(const std::string&)name color:(uint32_t)color label:(const std::string&)label x:(CGFloat)cx
               y:(CGFloat)cy r:(CGFloat)r alpha:(int)alpha pressed:(bool)pressed {
    CGContextRef g = UIGraphicsGetCurrentContext();
    CGFloat a = alpha / 255.0;
    UIImage* img = [self icon:name];
    if (img) {
        CGRect rc = CGRectMake(cx - r, cy - r, 2 * r, 2 * r);
        [img drawInRect:rc blendMode:kCGBlendModeNormal alpha:a];
        if (pressed) {
            UIImage* o = [self icon:"bubble_pressed_overlay"];
            if (o) [o drawInRect:rc blendMode:kCGBlendModeNormal alpha:a];
            else {
                CGContextSetFillColorWithColor(g, col(NAVY, a / 3).CGColor);
                CGContextFillEllipseInRect(g, CGRectInset(rc, r * 0.1, r * 0.1));
            }
        }
        return;
    }
    CGRect rc = CGRectMake(cx - r * 0.9, cy - r * 0.9, r * 1.8, r * 1.8);
    CGContextSetFillColorWithColor(g, col(pressed ? darker(color) : color, a).CGColor);
    CGContextFillEllipseInRect(g, rc);
    // shine on the upper left, as the bubbles of the artwork
    CGContextSetFillColorWithColor(g, col(0xFFFFFFFF, a / 3).CGColor);
    CGContextFillEllipseInRect(g, CGRectMake(cx - r * 0.35 - r * 0.22, cy - r * 0.38 - r * 0.22, r * 0.44, r * 0.44));
    CGContextSetStrokeColorWithColor(g, col(NAVY, a).CGColor);
    CGContextSetLineWidth(g, std::max<CGFloat>(1.5, r * 0.09));
    CGContextStrokeEllipseInRect(g, rc);
    if (!label.empty()) {
        NSString* s = [NSString stringWithUTF8String:label.c_str()];
        draw_text(s, cx, cy, r * (s.length > 2 ? 0.5 : 0.75), col(color == BONE ? NAVY : 0xFFFFFFFF, a));
    }
}

// a letter over an icon (e.g. "X" on an empty item slot): white with a navy outline
- (void)drawLabel:(const std::string&)label x:(CGFloat)cx y:(CGFloat)cy r:(CGFloat)r alpha:(int)alpha {
    CGFloat a = alpha / 255.0;
    draw_text([NSString stringWithUTF8String:label.c_str()], cx, cy, r * 0.7, col(0xFFFFFFFF, a), col(NAVY, a), 4);
}

// ---------------------------------------------------------------- game state
- (void)pollHud {
    if (!_controlsVisible && !_editMode) return;
    if (!g_live.load()) return;
    int32_t s[touch_hud::kSize];
    touch_hud::state(s);
    if (memcmp(s, _state, sizeof s)) {
        bool wasCutscene = [self cutscene];
        memcpy(_state, s, sizeof s);
        if (wasCutscene != [self cutscene]) [self releaseAll];
        [self setNeedsDisplay];
    }
}
- (bool)hudKnown { return _state[HUD_FLAGS] & touch_hud::kKnown; }
- (bool)hudFlag:(int)f { return _state[HUD_FLAGS] & f; }
- (bool)cutscene { return [self hudFlag:touch_hud::kCutscene] && !_editMode; }
- (bool)combatShown {
    if (_editMode || _combatMode == 1) return true;
    if (_combatMode == 2) return false;
    return ![self hudKnown] || [self hudFlag:touch_hud::kHasSword];  // the combat moves need a sword
}

- (bool)shown:(const Ctl&)c {
    if (c.removed) return false;
    if (c.kind == K_CAMSTICK && !_cameraStick) return false;
    if ([self cutscene]) return (_controlsVisible && c.kind == K_SKIP) || (c.kind == K_MENU && _menuShown);
    if (c.kind == K_SKIP) return _editMode;
    if (_editMode) return true;
    if (c.kind == K_MENU || c.kind == K_EDIT) return _menuShown;
    if (!_controlsVisible) return false;
    if (_drcMenu && !(c.id == "a" || c.id == "b" || c.id == "pause")) return false;
    if (c.kind == K_MACRO) return [self combatShown];
    // D-pad items Link doesn't have yet are hidden: the Wind Waker (up), the cannon (left: it fires
    // bombs) and the salvage hook (right)
    if (c.kind == K_BUTTON && [self hudKnown]) {
        if (c.bit == input::kUp) return [self hudFlag:touch_hud::kHasBaton];
        if (c.bit == input::kLeft) return [self hudFlag:touch_hud::kHasBombs];
        if (c.bit == input::kRight) return [self hudFlag:touch_hud::kHasGrapple];
    }
    return true;
}

- (Ctl*)byId:(const char*)id {
    for (auto& c : _ctls)
        if (c.id == id) return &c;
    return nullptr;
}

// ---------------------------------------------------------------- menu button auto-hide
- (bool)touched {
    bool wasHidden = !_menuShown;
    _menuShown = true;
    [_menuTimer invalidate];
    __weak WWTouchControls* w = self;
    _menuTimer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:NO block:^(NSTimer*) {
        WWTouchControls* s = w;
        if (!s) return;
        s->_menuShown = false;
        [s setNeedsDisplay];
    }];
    if (wasHidden) [self setNeedsDisplay];
    return wasHidden;
}

// ---------------------------------------------------------------- output
- (void)publish {
    ios::TouchPad p;
    p.buttons = _pulseBits | _macroBits;
    for (auto& c : _ctls)
        if (c.kind == K_BUTTON && c.pressed) p.buttons |= c.bit;
    p.lx = _macroStick ? _macroSx : _stickX;
    p.ly = _macroStick ? _macroSy : _stickY;
    p.rx = _camStickTouch ? _camStickX : _camX;
    p.ry = _camStickTouch ? _camStickY : _camY;
    std::lock_guard<std::mutex> lk(g_mu);
    g_pad = p;
}
- (void)changed {
    [self publish];
    [self setNeedsDisplay];
}
- (void)buzz {
    if (_haptics) [_haptic impactOccurred];
}

// ---------------------------------------------------------------- camera
- (void)cameraTick {
    // a swipe of about 10 u per second turns the camera at full speed (times the sensitivity)
    float k = _camSens / std::max<CGFloat>(1, _baseUnit * 0.16);
    float tx = clampf(_camAccX * k), ty = clampf(-_camAccY * k);
    _camAccX = _camAccY = 0;
    _camX = _camX * 0.35f + tx * 0.65f;
    _camY = _camY * 0.35f + ty * 0.65f;
    if (std::fabs(_camX) < 0.02f) _camX = 0;
    if (std::fabs(_camY) < 0.02f) _camY = 0;
    [self publish];
    if (!_camTouch && _camX == 0 && _camY == 0) {
        [_camTimer invalidate];
        _camTimer = nil;
    }
}
- (void)startCamTimer {
    if (_camTimer) return;
    _camTimer = [NSTimer timerWithTimeInterval:1.0 / 60 target:self selector:@selector(cameraTick) userInfo:nil
                                       repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:_camTimer forMode:NSRunLoopCommonModes];
}
- (void)cameraDown:(UITouch*)t at:(CGPoint)p {
    _camTouch = t;
    _camLast = _camDown = p;
    [self startCamTimer];
    double now = CACurrentMediaTime();
    if (now - _lastCamTap < 0.3) {  // second tap: centre the camera
        _lastCamTap = 0;
        _pulseBits = input::kZL;
        [self buzz];
        [self changed];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            self->_pulseBits = 0;
            [self changed];
        });
    }
}
- (void)pinchDown:(UITouch*)t at:(CGPoint)p {
    _pinchTouch = t;
    _pinch = p;
    _pinchStartDist = std::max<CGFloat>(1, std::hypot(p.x - _camLast.x, p.y - _camLast.y));
    _pinchStartZoom = _cameraZoom;
    _camAccX = _camAccY = _camX = _camY = 0;
    [self publish];
}
// fingers apart: closer; together: further away
- (void)pinchMoved {
    float d = std::max<CGFloat>(1, std::hypot(_pinch.x - _camLast.x, _pinch.y - _camLast.y));
    float z = std::max(0.5f, std::min(2.f, _pinchStartZoom * _pinchStartDist / d));
    if (std::fabs(z - _cameraZoom) < 0.005f) return;
    _cameraZoom = z;
    mods::set_camera_zoom(z);
}
- (void)cameraUp:(CGPoint)p {
    _camTouch = nil;
    bool tap = std::hypot(p.x - _camDown.x, p.y - _camDown.y) < _baseUnit * 0.3;
    _lastCamTap = tap ? CACurrentMediaTime() : 0;
}

// ---------------------------------------------------------------- combat moves
- (void)applyMacroStep {
    if (_macro.empty() || _macroStep >= (int)_macro.size()) {
        _macro.clear();
        _macroStep = -1;
        _macroBits = 0;
        _macroStick = false;
        [self changed];
        return;
    }
    const Step& s = _macro[_macroStep];
    _macroBits = s.buttons;
    _macroStick = s.stick;
    _macroSx = s.sx;
    _macroSy = s.sy;
    [self changed];
    unsigned gen = _macroGen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)s.ms * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (gen != self->_macroGen) return;
        self->_macroStep++;
        [self applyMacroStep];
    });
}
- (void)startSequence:(std::vector<Step>)steps {
    if (!_macro.empty()) return;
    _macro = std::move(steps);
    _macroStep = 0;
    _macroGen++;
    [self applyMacroStep];
}
- (void)startMacro:(int)move {
    const uint32_t ZL = input::kZL, A = input::kA, B = input::kB;
    switch (move) {
        case M_JUMP: [self startSequence:{{60, ZL, false, 0, 0}, {140, ZL | A, false, 0, 0}, {60, ZL, false, 0, 0}}]; break;
        case M_VERTICAL: [self startSequence:{{60, ZL, false, 0, 0}, {140, ZL | B, false, 0, 0}, {60, ZL, false, 0, 0}}]; break;
        case M_SPIN: [self startSequence:{{1100, B, false, 0, 0}}]; break;  // hold B until the sword charges
        case M_DODGE: {  // lock on + stick + A: sideways where the stick points, else a backflip
            float sx = _stickX, sy = _stickY, len = std::hypot(sx, sy);
            if (len < 0.4f) { sx = 0; sy = -1; } else { sx /= len; sy /= len; }
            [self startSequence:{{60, ZL, false, 0, 0}, {80, ZL, true, sx, sy}, {140, ZL | A, true, sx, sy}, {60, ZL, false, 0, 0}}];
            break;
        }
    }
}

// ---------------------------------------------------------------- layout
- (void)layoutSubviews {
    [super layoutSubviews];
    [self layoutControls];
    [self setNeedsDisplay];
}

// u = shorter side / 7, times the size setting; over the whole screen, as on Android
- (void)layoutControls {
    CGSize s = self.bounds.size;
    if (s.width <= 0 || s.height <= 0) return;
    _baseUnit = std::min(s.width, s.height) / 7;
    _unit = _baseUnit * _scale;
    CGFloat left = 0, w = s.width;
    for (auto& c : _ctls) {
        if (c.custom()) {
            c.cx = c.fx * s.width;
            c.cy = c.fy * s.height;
            c.r = c.fd * _baseUnit / 2;
        } else {
            c.cx = left + c.ax * w + c.ox * _unit;
            c.cy = c.ay * s.height + c.oy * _unit;
            c.r = c.d * _unit / 2;
        }
        c.cx = std::max(c.r * 0.5, std::min(s.width - c.r * 0.5, c.cx));
        c.cy = std::max(c.r * 0.5, std::min(s.height - c.r * 0.5, c.cy));
    }
}

// the saved layout: "id:fx,fy,d;..." for the controls the user moved, "id:-" for removed ones
- (void)setLayout:(NSString*)str {
    for (auto& c : _ctls) {
        c.fx = c.fy = c.fd = NAN;
        c.removed = false;
    }
    for (NSString* part in [str ?: @"" componentsSeparatedByString:@";"]) {
        NSArray* kv = [part componentsSeparatedByString:@":"];
        if (kv.count != 2) continue;
        Ctl* c = [self byId:[kv[0] UTF8String]];
        if (!c) continue;
        if ([kv[1] isEqualToString:@"-"]) {
            c->removed = c->removable();
            continue;
        }
        NSArray* v = [kv[1] componentsSeparatedByString:@","];
        if (v.count != 3) continue;
        c->fx = [v[0] floatValue];
        c->fy = [v[1] floatValue];
        c->fd = [v[2] floatValue];
        if (!(c->fd > 0)) c->fx = c->fy = c->fd = NAN;
    }
    [self layoutControls];
    [self setNeedsDisplay];
}
- (NSString*)layoutString {
    NSMutableArray* parts = [NSMutableArray new];
    for (auto& c : _ctls) {
        if (c.removed) [parts addObject:[NSString stringWithFormat:@"%s:-", c.id.c_str()]];
        else if (c.custom()) [parts addObject:[NSString stringWithFormat:@"%s:%.4f,%.4f,%.3f", c.id.c_str(), c.fx, c.fy, c.fd]];
    }
    return [parts componentsJoinedByString:@";"];
}

// exact hits first, then a little slack (thumbs are imprecise); the stick is a zone, not a button
- (int)controlAt:(CGPoint)p {
    for (CGFloat slack : {1.0, 1.25})
        for (int i = 0; i < (int)_ctls.size(); i++) {
            auto& c = _ctls[i];
            if (![self shown:c] || (c.kind == K_STICK && !_editMode)) continue;
            if (c.hit(p, slack)) return i;
        }
    return -1;
}

- (void)updateStick:(CGPoint)p {
    Ctl* s = [self byId:"stick"];
    CGFloat r = s->r * 0.8;
    // the stick stays where the thumb landed until it lifts: beyond the rim it is pushed fully
    CGFloat dx = p.x - _stickO.x, dy = p.y - _stickO.y, len = std::hypot(dx, dy);
    if (len > r) { dx = dx / len * r; dy = dy / len * r; }
    _stickX = clampf(dx / r);
    _stickY = clampf(-dy / r);
}
// a fixed stick: the offset from its centre, full past 80% of its radius, times the camera speed
- (void)updateCamStick:(CGPoint)p {
    Ctl* s = [self byId:"camstick"];
    CGFloat r = s->r * 0.8;
    float dx = (p.x - s->cx) / r, dy = -(p.y - s->cy) / r, len = std::hypot(dx, dy);
    if (len > 1) { dx /= len; dy /= len; }
    float dead = 0.12f, m = std::min(len, 1.f);
    float k = len < dead ? 0 : std::min(1.f, (m - dead) / (1 - dead)) / std::max(1e-4f, m);
    _camStickX = clampf(dx * k * _camSens);
    _camStickY = clampf(dy * k * _camSens);
}

- (void)releaseAll {
    for (auto& c : _ctls) c.pressed = false;
    [_pointers removeAllObjects];
    _stickTouch = _camTouch = _pinchTouch = _camStickTouch = nil;
    _stickX = _stickY = _camX = _camY = _camStickX = _camStickY = 0;
    _macroGen++;
    _macro.clear();
    _macroStep = -1;
    _macroBits = _pulseBits = 0;
    _macroStick = false;
    [self publish];
}

- (void)setDrcRect:(CGRect)r full:(bool)full {
    _drc = r;
    if (full != _drcMenu) {
        _drcMenu = full;
        if (full) {
            for (auto& c : _ctls)
                if (![self shown:c]) c.pressed = false;
            _stickTouch = nil;
            _stickX = _stickY = 0;
            [self publish];
        }
    }
    [self setNeedsDisplay];
}

- (void)setControlsVisible:(bool)visible {
    if (!visible && _controlsVisible) [self releaseAll];
    _controlsVisible = visible;
    [self setNeedsDisplay];
}

// ---------------------------------------------------------------- touches
// a touch nothing here wants (the GamePad picture) falls through to the GamePad view below
- (UIView*)hitTest:(CGPoint)p withEvent:(UIEvent*)e {
    if (self.hidden || ![self pointInside:p withEvent:e]) return nil;
    if (_editMode || [self controlAt:p] >= 0) return self;
    // the ≡ and ✎ buttons while hidden: the touch only shows them (touchesBegan). UIKit may hit-test a
    // touch more than once, so nothing changes here
    bool shownBefore = _menuShown;
    _menuShown = true;
    int m = [self controlAt:p];
    _menuShown = shownBefore;
    if (m >= 0 && (_ctls[m].kind == K_MENU || _ctls[m].kind == K_EDIT)) return self;
    if ([self cutscene] && _controlsVisible) return self;
    if (!CGRectIsEmpty(_drc) && CGRectContainsPoint(_drc, p)) {
        [self touched];
        return nil;
    }
    return self;
}

- (void)touchesBegan:(NSSet<UITouch*>*)ts withEvent:(UIEvent*)e {
    if (_editMode) {
        for (UITouch* t in ts) [self editDown:t];
        [self setNeedsDisplay];
        return;
    }
    bool menuWasHidden = [self touched];
    bool changed = false;
    for (UITouch* t in ts) {
        CGPoint p = [t locationInView:self];
        int i = [self controlAt:p];
        if (i >= 0) {
            Ctl& c = _ctls[i];
            if (c.kind == K_MENU || c.kind == K_EDIT) {
                if (!menuWasHidden) {  // a touch on a hidden button only shows it
                    if (c.kind == K_MENU) [self showMenu];
                    else [self setEditMode:true];
                }
                return;
            }
            if (c.kind == K_SKIP) {
                [self buzz];
                const uint32_t P = input::kPlus;
                [self startSequence:{{120, P, false, 0, 0}, {450, 0, false, 0, 0}, {120, P, false, 0, 0}, {60, 0, false, 0, 0}}];
                c.pressed = true;
                [_pointers setObject:@(i) forKey:t];
                changed = true;
                continue;
            }
            if (c.kind == K_CAMSTICK) {
                if (!_camStickTouch) {
                    _camStickTouch = t;
                    [self updateCamStick:p];
                    changed = true;
                }
                continue;
            }
            [_pointers setObject:@(i) forKey:t];
            c.pressed = true;
            [self buzz];
            if (c.kind == K_MACRO) [self startMacro:c.bit];
            changed = true;
        } else if ([self cutscene] && _controlsVisible) {
            // a tap anywhere else during a scene: A (advances its text)
            [self startSequence:{{110, input::kA, false, 0, 0}}];
        } else if (!_controlsVisible) {
            continue;
        } else if (p.x < self.bounds.size.width * 0.45 && ![self byId:"stick"]->removed && !_drcMenu) {
            if (!_stickTouch) {
                _stickTouch = t;
                _stickO = p;
                [self updateStick:p];
                changed = true;
            }
        } else if (!_camTouch) {
            [self cameraDown:t at:p];
        } else if (!_pinchTouch) {
            [self pinchDown:t at:p];
        }
    }
    if (changed) [self changed];
}

- (void)touchesMoved:(NSSet<UITouch*>*)ts withEvent:(UIEvent*)e {
    if (_editMode) {
        [self editMoved];
        return;
    }
    bool changed = false;
    for (UITouch* t in ts) {
        CGPoint p = [t locationInView:self];
        if (t == _stickTouch) {
            [self updateStick:p];
            changed = true;
        } else if (t == _camStickTouch) {
            [self updateCamStick:p];
            changed = true;
        } else if (t == _pinchTouch) {
            _pinch = p;
            [self pinchMoved];
        } else if (t == _camTouch) {
            if (!_pinchTouch) {  // turning; a pinch holds the camera still
                _camAccX += p.x - _camLast.x;
                _camAccY += p.y - _camLast.y;
            }
            _camLast = p;
            if (_pinchTouch) [self pinchMoved];
        } else if (NSNumber* n = [_pointers objectForKey:t]) {
            Ctl& c = _ctls[n.intValue];
            if (c.kind == K_BUTTON) {
                // sliding between buttons moves the press (e.g. from B to A)
                int now = [self controlAt:p];
                if (now >= 0 && now != n.intValue && _ctls[now].kind == K_BUTTON) {
                    c.pressed = false;
                    _ctls[now].pressed = true;
                    [_pointers setObject:@(now) forKey:t];
                    [self buzz];
                    changed = true;
                }
            }
        }
    }
    if (changed) [self changed];
}

- (void)endTouches:(NSSet<UITouch*>*)ts cancelled:(bool)cancelled {
    if (_editMode) {
        for (UITouch* t in ts) [self editUp:t cancelled:cancelled];
        [self setNeedsDisplay];
        return;
    }
    for (UITouch* t in ts) {
        CGPoint p = [t locationInView:self];
        if (t == _stickTouch) {
            _stickTouch = nil;
            _stickX = _stickY = 0;
        }
        if (t == _camStickTouch) {
            _camStickTouch = nil;
            _camStickX = _camStickY = 0;
        }
        if (t == _pinchTouch) {
            _pinchTouch = nil;
            _lastCamTap = 0;
        } else if (t == _camTouch && _pinchTouch) {
            // the first finger lifted during a pinch: the other one goes on turning the camera
            _camTouch = _pinchTouch;
            _pinchTouch = nil;
            _camLast = _camDown = _pinch;
            _lastCamTap = 0;
        } else if (t == _camTouch) {
            [self cameraUp:p];
        }
        if (NSNumber* n = [_pointers objectForKey:t]) {
            _ctls[n.intValue].pressed = false;
            [_pointers removeObjectForKey:t];
        }
    }
    [self changed];
}
- (void)touchesEnded:(NSSet<UITouch*>*)ts withEvent:(UIEvent*)e { [self endTouches:ts cancelled:false]; }
- (void)touchesCancelled:(NSSet<UITouch*>*)ts withEvent:(UIEvent*)e { [self endTouches:ts cancelled:true]; }

// ---------------------------------------------------------------- the ≡ menu
- (void)choose:(NSString*)title options:(NSArray<NSString*>*)names current:(NSInteger)cur
          apply:(void (^)(NSInteger))apply {
    UIAlertController* a = [UIAlertController alertControllerWithTitle:title message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSInteger i = 0; i < (NSInteger)names.count; i++) {
        NSString* n = i == cur ? [@"✓ " stringByAppendingString:names[i]] : names[i];
        [a addAction:[UIAlertAction actionWithTitle:n style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
            apply(i);
            [self showMenu];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Back" style:UIAlertActionStyleCancel handler:^(UIAlertAction*) {
        [self showMenu];
    }]];
    [self present:a];
}

- (void)present:(UIAlertController*)a {
    Ctl* m = [self byId:"menu"];
    a.popoverPresentationController.sourceView = self;
    a.popoverPresentationController.sourceRect = CGRectMake(m->cx - m->r, m->cy - m->r, 2 * m->r, 2 * m->r);
    [ios::root_view_controller() presentViewController:a animated:YES completion:nil];
}

static NSInteger nearest(const std::vector<float>& v, float x) {
    NSInteger best = 0;
    for (size_t i = 1; i < v.size(); i++)
        if (std::fabs(v[i] - x) < std::fabs(v[best] - x)) best = (NSInteger)i;
    return best;
}

- (void)showMenu {
    [self releaseAll];
    platform::set_game_paused(true);
    UIAlertController* a = [UIAlertController alertControllerWithTitle:@"Touch controls" message:nil
                                                        preferredStyle:UIAlertControllerStyleActionSheet];
    auto add = [&](NSString* t, void (^h)(void)) {
        [a addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault handler:^(UIAlertAction*) { h(); }]];
    };
    NSArray* drcNames = @[ @"Inset", @"Full screen", @"Hidden" ];
    add([NSString stringWithFormat:@"GamePad screen: %@", drcNames[ios::drc_mode()]], ^{
        [self choose:@"GamePad screen" options:drcNames current:ios::drc_mode() apply:^(NSInteger i) {
            ios::set_drc_mode((int)i);
        }];
    });
    add(@"Edit layout ✎", ^{
        platform::set_game_paused(false);
        [self setEditMode:true];
    });
    static const std::vector<float> sizes = {0.7f, 0.85f, 1, 1.15f, 1.3f}, opac = {0.25f, 0.45f, 0.65f, 0.85f},
                                    speeds = {0.5f, 0.75f, 1, 1.5f, 2};
    auto pct = [](const std::vector<float>& v) {
        NSMutableArray* r = [NSMutableArray new];
        for (float f : v) [r addObject:[NSString stringWithFormat:@"%d%%", (int)std::lround(f * 100)]];
        return r;
    };
    add([NSString stringWithFormat:@"Button size: %d%%", (int)std::lround(_scale * 100)], ^{
        [self choose:@"Button size" options:pct(sizes) current:nearest(sizes, self->_scale) apply:^(NSInteger i) {
            [prefs() setFloat:sizes[i] forKey:@"touch.scale"];
            [self loadPrefs];
        }];
    });
    add([NSString stringWithFormat:@"Opacity: %d%%", (int)std::lround(_opacity * 100)], ^{
        [self choose:@"Opacity" options:pct(opac) current:nearest(opac, self->_opacity) apply:^(NSInteger i) {
            [prefs() setFloat:opac[i] forKey:@"touch.opacity"];
            [self loadPrefs];
        }];
    });
    add([NSString stringWithFormat:@"Camera speed: %d%%", (int)std::lround(_camSens * 100)], ^{
        [self choose:@"Camera speed" options:pct(speeds) current:nearest(speeds, self->_camSens) apply:^(NSInteger i) {
            [prefs() setFloat:speeds[i] forKey:@"touch.cameraSensitivity"];
            [self loadPrefs];
        }];
    });
    add([NSString stringWithFormat:@"Camera stick: %@", _cameraStick ? @"On" : @"Off"], ^{
        [prefs() setBool:!self->_cameraStick forKey:@"touch.cameraStick"];
        [self loadPrefs];
        [self showMenu];
    });
    NSArray* combatNames = @[ @"Auto (with a sword)", @"Always", @"Never" ];
    add([NSString stringWithFormat:@"Combat buttons: %@", combatNames[_combatMode % 3]], ^{
        [self choose:@"Combat buttons" options:combatNames current:self->_combatMode apply:^(NSInteger i) {
            [prefs() setInteger:i forKey:@"touch.combat"];
            [self loadPrefs];
        }];
    });
    add([NSString stringWithFormat:@"Performance overlay: %@", ios::perf_overlay() ? @"On" : @"Off"], ^{
        ios::set_perf_overlay(!ios::perf_overlay());
        [self showMenu];
    });
    add([NSString stringWithFormat:@"Apple Metal HUD: %@", ios::metal_hud() ? @"On" : @"Off"], ^{
        bool on = !ios::metal_hud();
        ios::set_metal_hud(on);
        if (on) {
            UIAlertController* n = [UIAlertController
                alertControllerWithTitle:@"Apple Metal HUD"
                                 message:@"iOS shows it only with Developer Mode on (Settings > Privacy & Security), "
                                         @"and it may need the app to be closed and opened again. The Performance overlay "
                                         @"works everywhere."
                          preferredStyle:UIAlertControllerStyleAlert];
            [n addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction*) {
                [self showMenu];
            }]];
            [ios::root_view_controller() presentViewController:n animated:YES completion:nil];
        } else {
            [self showMenu];
        }
    });
    add([NSString stringWithFormat:@"Vibration: %@", _haptics ? @"On" : @"Off"], ^{
        [prefs() setBool:!self->_haptics forKey:@"touch.haptics"];
        [self loadPrefs];
        [self showMenu];
    });
    [a addAction:[UIAlertAction actionWithTitle:@"Resume" style:UIAlertActionStyleCancel handler:^(UIAlertAction*) {
        platform::set_game_paused(false);
        [self touched];
    }]];
    [self present:a];
}

// ---------------------------------------------------------------- layout editor
// drag to move (snaps to the grid), drag the handle or pinch to resize
- (bool)anyRemoved {
    for (auto& c : _ctls)
        if (c.removed) return true;
    return false;
}
- (void)setEditMode:(bool)on {
    if (on == _editMode) return;
    [self releaseAll];
    _editMode = on;
    _editSel = -1;
    _editTouch = _editTouch2 = nil;
    _editAddOpen = false;
    [self changed];
}
- (CGFloat)grid { return _baseUnit * 0.25; }
- (CGFloat)snap:(CGFloat)v { return std::round(v / [self grid]) * [self grid]; }
- (void)pin:(Ctl&)c {
    CGSize s = self.bounds.size;
    c.fx = c.cx / std::max<CGFloat>(1, s.width);
    c.fy = c.cy / std::max<CGFloat>(1, s.height);
    c.fd = c.r * 2 / _baseUnit;
}
- (CGPoint)handle:(const Ctl&)c { return CGPointMake(c.cx + c.r * 0.75, c.cy + c.r * 0.75); }
- (void)setRadius:(Ctl&)c r:(CGFloat)r { c.r = std::max(_baseUnit * 0.25, std::min(_baseUnit * 2, r)); }

- (void)editDown:(UITouch*)t {
    CGPoint p = [t locationInView:self];
    if (_editTouch) {  // second finger: pinch the selected control
        if (_editSel >= 0 && !_editTouch2) {
            _editTouch2 = t;
            CGPoint q = [_editTouch locationInView:self];
            _editPinchStart = std::hypot(p.x - q.x, p.y - q.y);
            _editSizeStart = _ctls[_editSel].r;
        }
        return;
    }
    if (_editAddOpen) {  // the panel takes the touch: a control to put back, or outside to close
        for (size_t i = 0; i < _panelSlots.size(); i++)
            if (CGRectContainsPoint(_panelSlots[i], p)) {
                _ctls[_panelCtls[i]].removed = false;
                _editSel = _panelCtls[i];
                [self buzz];
                break;
            }
        if (!CGRectContainsPoint(_editPanel, p) || ![self anyRemoved]) _editAddOpen = false;
        return;
    }
    if (CGRectContainsPoint(_editDone, p)) {
        [prefs() setObject:[self layoutString] forKey:@"touch.layout"];
        [self setEditMode:false];
        return;
    }
    if (CGRectContainsPoint(_editCancel, p)) {
        [self setLayout:[prefs() stringForKey:@"touch.layout"]];
        [self setEditMode:false];
        return;
    }
    if (CGRectContainsPoint(_editReset, p)) {
        for (auto& c : _ctls) {
            c.fx = c.fy = c.fd = NAN;
            c.removed = false;
        }
        _editSel = -1;
        [self layoutControls];
        return;
    }
    if (CGRectContainsPoint(_editRemove, p)) {
        if (_editSel >= 0 && _ctls[_editSel].removable()) {
            _ctls[_editSel].removed = true;
            _editSel = -1;
            [self buzz];
        }
        return;
    }
    if (CGRectContainsPoint(_editAdd, p)) {
        _editAddOpen = [self anyRemoved];
        return;
    }
    _editResizing = false;
    if (_editSel >= 0) {
        CGPoint h = [self handle:_ctls[_editSel]];
        _editResizing = std::hypot(p.x - h.x, p.y - h.y) < _baseUnit * 0.35;
    }
    if (!_editResizing) {
        _editSel = [self controlAt:p];
        if (_editSel >= 0) {
            _editDx = p.x - _ctls[_editSel].cx;
            _editDy = p.y - _ctls[_editSel].cy;
        }
    }
    if (_editSel >= 0) _editTouch = t;
}

- (void)editMoved {
    if (_editSel < 0 || !_editTouch) return;
    Ctl& c = _ctls[_editSel];
    CGPoint p = [_editTouch locationInView:self];
    if (_editTouch2) {
        CGPoint q = [_editTouch2 locationInView:self];
        if (_editPinchStart > 0) [self setRadius:c r:_editSizeStart * std::hypot(p.x - q.x, p.y - q.y) / _editPinchStart];
    } else if (_editResizing) {
        [self setRadius:c r:std::hypot(p.x - c.cx, p.y - c.cy) / 0.75 / std::sqrt(2.0)];
    } else {
        c.cx = std::max<CGFloat>(0, std::min(self.bounds.size.width, p.x - _editDx));
        c.cy = std::max<CGFloat>(0, std::min(self.bounds.size.height, p.y - _editDy));
    }
    [self pin:c];
    [self setNeedsDisplay];
}

- (void)editUp:(UITouch*)t cancelled:(bool)cancelled {
    if (t == _editTouch2) {
        _editTouch2 = nil;
    } else if (t == _editTouch || cancelled) {
        if (_editSel >= 0 && !_editResizing && !_editTouch2) {
            Ctl& c = _ctls[_editSel];
            c.cx = [self snap:c.cx];
            c.cy = [self snap:c.cy];
            [self pin:c];
        }
        _editTouch = _editTouch2 = nil;
        _editResizing = false;
    }
}

// ---------------------------------------------------------------- drawing
- (void)drawRect:(CGRect)dirty {
    CGContextRef g = UIGraphicsGetCurrentContext();
    if (_editMode) [self drawGrid:g];
    int a = _editMode ? 230 : (int)(255 * _opacity);
    for (int i = 0; i < (int)_ctls.size(); i++) {
        Ctl& c = _ctls[i];
        if (![self shown:c]) continue;
        switch (c.kind) {
            case K_STICK: [self drawStick:c alpha:a]; break;
            case K_CAMSTICK: [self drawCamStick:c alpha:a]; break;
            case K_SKIP: [self drawSkip:c alpha:_editMode ? a : std::max(a, 200)]; break;
            default: [self drawButton:c alpha:a]; break;
        }
        if (_editMode && i == _editSel) {
            CGContextSetStrokeColorWithColor(g, col(0xFFFFCC26).CGColor);
            CGContextSetLineWidth(g, std::max<CGFloat>(2, _unit * 0.04));
            CGFloat rr = c.r * 1.05;
            CGContextStrokeEllipseInRect(g, CGRectMake(c.cx - rr, c.cy - rr, 2 * rr, 2 * rr));
            CGPoint h = [self handle:c];
            [self drawIcon:"editor_resize_handle" color:0xFFFFFFFF label:"↘" x:h.x y:h.y r:_baseUnit * 0.22 alpha:255
                   pressed:false];
        }
    }
    if (_editMode) [self drawEditBar:g];
}

- (void)drawButton:(Ctl&)c alpha:(int)a {
    std::string name = c.icon, overlay;
    const char* n = nullptr;
    if (c.id == "a") {
        if ((n = at(A_ACTIONS, _state[HUD_A]))) name = n;
        else overlay = c.label;
    } else if (c.id == "b") {
        if ((n = at(B_ACTIONS, _state[HUD_B]))) name = n;
    } else if (c.id == "zr") {
        if ((n = at(ZR_ACTIONS, _state[HUD_ZR]))) name = n;
    } else if (c.id == "x" || c.id == "y" || c.id == "r") {
        int slot = c.id == "x" ? HUD_X : c.id == "y" ? HUD_Y : HUD_R;
        if ((n = at(ITEMS, _state[slot]))) name = n;
        else overlay = c.label;
    } else if (c.id == "zl" && [self hudFlag:touch_hud::kTargeting]) {
        name = "zl_target_active";
    }
    bool hasIcon = [self icon:name] != nil;
    [self drawIcon:name color:c.color label:overlay.empty() ? c.label : overlay x:c.cx y:c.cy r:c.r alpha:a
           pressed:c.pressed];
    if (hasIcon && !overlay.empty()) [self drawLabel:overlay x:c.cx y:c.cy r:c.r alpha:a];
}

- (void)drawStickBase:(CGFloat)x y:(CGFloat)y r:(CGFloat)r alpha:(int)alpha {
    if ([self icon:"stick_base"]) {
        [self drawIcon:"stick_base" color:0 label:"" x:x y:y r:r alpha:alpha pressed:false];
        return;
    }
    CGContextRef g = UIGraphicsGetCurrentContext();
    CGRect rc = CGRectMake(x - r, y - r, 2 * r, 2 * r);
    CGContextSetFillColorWithColor(g, col(SKY, alpha / 255.0 / 3).CGColor);
    CGContextFillEllipseInRect(g, rc);
    CGContextSetStrokeColorWithColor(g, col(NAVY, alpha / 255.0).CGColor);
    CGContextStrokeEllipseInRect(g, rc);
}

- (void)drawStick:(Ctl&)c alpha:(int)a {
    bool active = _stickTouch != nil;
    CGFloat bx = active ? _stickO.x : c.cx, by = active ? _stickO.y : c.cy;
    int alpha = active ? a : a * 2 / 3;
    [self drawStickBase:bx y:by r:c.r alpha:alpha];
    [self drawIcon:"stick_knob" color:BONE label:"" x:bx + _stickX * c.r * 0.8 y:by - _stickY * c.r * 0.8 r:c.r * 0.42
             alpha:alpha pressed:false];
}

- (void)drawCamStick:(Ctl&)c alpha:(int)a {
    int alpha = _camStickTouch ? a : a * 2 / 3;
    [self drawStickBase:c.cx y:c.cy r:c.r alpha:alpha];
    float sx = _camSens > 0 ? _camStickX / _camSens : 0, sy = _camSens > 0 ? _camStickY / _camSens : 0;
    [self drawIcon:"stick_knob" color:BONE label:"" x:c.cx + clampf(sx) * c.r * 0.8 y:c.cy - clampf(sy) * c.r * 0.8
                 r:c.r * 0.42 alpha:alpha pressed:false];
    draw_text(@"◎", c.cx, c.cy - c.r * 1.05, _unit * 0.34, col(0xFFFFFFFF, alpha / 255.0));
}

// a rounded "Skip ▶▶" plate
- (void)drawSkip:(Ctl&)c alpha:(int)a {
    CGFloat w = c.r * 2.6, h = c.r * 1.05;
    UIBezierPath* p = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(c.cx - w / 2, c.cy - h / 2, w, h) cornerRadius:h / 2];
    [col(c.pressed ? 0xFF2E7DB8 : 0xFF1B4F72, a / 255.0 * 0.75) setFill];
    [p fill];
    [col(0xFFFFFFFF, a / 255.0) setStroke];
    p.lineWidth = std::max<CGFloat>(2, _unit * 0.04);
    [p stroke];
    draw_text(@"Skip  ▶▶", c.cx, c.cy, h * 0.42, col(0xFFFFFFFF, a / 255.0));
}

- (void)drawGrid:(CGContextRef)g {
    CGSize s = self.bounds.size;
    CGContextSetFillColorWithColor(g, [UIColor colorWithWhite:0 alpha:90 / 255.0].CGColor);
    CGContextFillRect(g, self.bounds);
    CGFloat gr = [self grid];
    CGContextSetLineWidth(g, 1);
    for (int i = 0; i * gr <= s.width; i++) {
        CGContextSetStrokeColorWithColor(g, col(0xFF9FD8FF, (i % 4 == 0 ? 90 : 35) / 255.0).CGColor);
        CGContextStrokeLineSegments(g, (CGPoint[]){{i * gr, 0}, {i * gr, s.height}}, 2);
    }
    for (int i = 0; i * gr <= s.height; i++) {
        CGContextSetStrokeColorWithColor(g, col(0xFF9FD8FF, (i % 4 == 0 ? 90 : 35) / 255.0).CGColor);
        CGContextStrokeLineSegments(g, (CGPoint[]){{0, i * gr}, {s.width, i * gr}}, 2);
    }
}

- (void)drawEditBar:(CGContextRef)g {
    CGFloat r = _baseUnit * 0.42, cy = _baseUnit * 0.6, cx = self.bounds.size.width / 2, step = _baseUnit * 1.15;
    auto slot = [&](float k) { return CGRectMake(cx + k * step - r, cy - r, 2 * r, 2 * r); };
    _editReset = slot(-2);
    _editRemove = slot(-1);
    _editAdd = slot(0);
    _editCancel = slot(1);
    _editDone = slot(2);
    bool canRemove = _editSel >= 0 && _ctls[_editSel].removable(), canAdd = [self anyRemoved];
    [self drawIcon:"editor_reset" color:BONE label:"↺" x:CGRectGetMidX(_editReset) y:cy r:r alpha:255 pressed:false];
    [self drawIcon:"editor_remove" color:RED label:"🗑" x:CGRectGetMidX(_editRemove) y:cy r:r alpha:canRemove ? 255 : 90
           pressed:false];
    [self drawIcon:"editor_add" color:SKY label:"+" x:CGRectGetMidX(_editAdd) y:cy r:r alpha:canAdd ? 255 : 90 pressed:false];
    [self drawIcon:"editor_cancel" color:NAVY label:"✕" x:CGRectGetMidX(_editCancel) y:cy r:r alpha:255 pressed:false];
    [self drawIcon:"editor_done" color:GREEN label:"✓" x:CGRectGetMidX(_editDone) y:cy r:r alpha:255 pressed:false];
    if (_editAddOpen) [self drawAddPanel:g];
    // the hint, wrapped to the screen width
    NSMutableParagraphStyle* ps = [NSMutableParagraphStyle new];
    ps.alignment = NSTextAlignmentCenter;
    NSDictionary* at = @{NSFontAttributeName: [UIFont boldSystemFontOfSize:std::max<CGFloat>(11, _baseUnit * 0.2)],
                         NSForegroundColorAttributeName: UIColor.whiteColor, NSParagraphStyleAttributeName: ps,
                         NSStrokeColorAttributeName: col(NAVY), NSStrokeWidthAttributeName: @(-3)};
    NSString* hint = @"Drag to move · corner handle or pinch to resize · 🗑 removes the selected control · "
                     @"+ puts removed ones back · ✕ cancels";
    CGFloat hw = self.bounds.size.width - 32;
    CGRect hr = [hint boundingRectWithSize:CGSizeMake(hw, 1000) options:NSStringDrawingUsesLineFragmentOrigin
                                attributes:at context:nil];
    [hint drawWithRect:CGRectMake(16, cy + r + _baseUnit * 0.15, hw, std::ceil(hr.size.height))
               options:NSStringDrawingUsesLineFragmentOrigin attributes:at context:nil];
}

// the controls taken off the screen, in a grid: a touch puts one back
- (void)drawAddPanel:(CGContextRef)g {
    _panelSlots.clear();
    _panelCtls.clear();
    for (int i = 0; i < (int)_ctls.size(); i++)
        if (_ctls[i].removed) _panelCtls.push_back(i);
    int n = (int)_panelCtls.size();
    if (!n) return;
    CGFloat cell = _baseUnit * 1.1, r = _baseUnit * 0.42;
    int cols = std::min(n, 6), rows = (n + cols - 1) / cols;
    CGFloat w = cols * cell + _baseUnit * 0.4, h = rows * cell + _baseUnit * 0.9;
    CGFloat left = (self.bounds.size.width - w) / 2, top = (self.bounds.size.height - h) / 2;
    _editPanel = CGRectMake(left, top, w, h);
    [col(NAVY, 0.9) setFill];
    [[UIBezierPath bezierPathWithRoundedRect:_editPanel cornerRadius:_baseUnit * 0.2] fill];
    draw_text(@"Touch a control to put it back", self.bounds.size.width / 2, top + _baseUnit * 0.35, _baseUnit * 0.24,
              UIColor.whiteColor);
    for (int i = 0; i < n; i++) {
        Ctl& c = _ctls[_panelCtls[i]];
        CGFloat x = left + _baseUnit * 0.2 + (i % cols + 0.5) * cell, y = top + _baseUnit * 0.7 + (i / cols + 0.5) * cell;
        _panelSlots.push_back(CGRectMake(x - cell / 2, y - cell / 2, cell, cell));
        [self drawIcon:c.icon color:c.color label:c.label x:x y:y r:r alpha:255 pressed:false];
    }
}
@end

namespace ios {
static WWTouchControls* g_view = nil;
static bool g_hidden = false;

UIView* make_touch_controls(CGRect frame) {
    g_view = [[WWTouchControls alloc] initWithFrame:frame];
    [g_view setControlsVisible:!g_hidden];
    return g_view;
}
void set_touch_controls_drc_rect(UIView* controls, CGRect drc, bool full) {
    [(WWTouchControls*)controls setDrcRect:drc full:full];
}
TouchPad touch_pad() {
    std::lock_guard<std::mutex> lk(g_mu);
    return g_pad;
}
// a game controller is connected: only the ≡ and ✎ buttons stay (they hide after a few seconds)
void set_touch_controls_hidden(bool hidden) {  // main thread
    g_hidden = hidden;
    if (g_view) [g_view setControlsVisible:!hidden];
}
void set_game_live() { g_live = true; }
}  // namespace ios
