// iOS shell pieces shared between ios_app.mm, ios_touch.mm and ios_input.mm.
#pragma once
#import <UIKit/UIKit.h>

#include <cstdint>

#include "input.h"

namespace ios {

// touch controls (ios_touch.mm): an overlay view over the whole screen
UIView* make_touch_controls(CGRect frame);
// where the GamePad picture is (its touches go to it, not to the sticks); full: it covers the screen,
// only the buttons stay active
void set_touch_controls_drc_rect(UIView* controls, CGRect drc, bool full);
// the GamePad state the touch controls hold (any thread)
struct TouchPad {
    uint32_t buttons = 0;
    float lx = 0, ly = 0, rx = 0, ry = 0;  // -1..1, +y up
};
TouchPad touch_pad();
// a game controller is connected: the touch controls hide
void set_touch_controls_hidden(bool hidden);

// the game's memory is ready: the touch controls start reading the HUD state (boot thread)
void set_game_live();

UIViewController* root_view_controller();  // ios_app.mm
// the GamePad picture: 0 inset, 1 full screen, 2 hidden (main thread; remembered)
int drc_mode();
void set_drc_mode(int m);
// Apple's Metal performance HUD (frame rate, GPU time, memory) over the game picture; remembered
bool metal_hud();
void set_metal_hud(bool on);

}  // namespace ios
