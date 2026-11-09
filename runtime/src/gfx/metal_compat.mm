// Renderer hooks the shared runtime calls that only the Vulkan renderer (runtime/src/vk) implements
// in full: the Metal renderer (macOS, iOS) answers with the plain 16:9 behaviour.
#include "gx2/gx2.h"
#include "metal.h"

namespace gfx {

// wider-than-16:9 TV picture (aspect.cpp): Metal always draws the game's own 16:9 layout
void set_frame_aspect(float) {}
bool target_aspect_factors(uint32_t, uint32_t, float& kx, float& ky) {
    kx = ky = 1.0f;
    return false;
}

// depth peeks (peekz.cpp): no answers are written back, so the sun's lens flare stays hidden as in
// the game without the hook
void peek_z(const uint32_t*, uint32_t) {}

// swaps submitted to the GPU: swap() commits each frame as it counts it
uint64_t frames_submitted() { return __atomic_load_n(&R.frame, __ATOMIC_RELAXED); }

bool drc_window_shown();  // metal_main.mm
bool drc_shown() { return drc_window_shown(); }

// Fast Forward (mods/turbo.cpp): only the Vulkan renderer's frame generation needs to know
void set_fast_forward(bool) {}

}  // namespace gfx
