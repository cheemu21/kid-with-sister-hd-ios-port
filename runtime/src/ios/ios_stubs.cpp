// Pieces of the macOS shell (mods/mouse.mm) the shared runtime calls. On iOS the mouse camera
// (mods/camera.cpp) is driven by camera swipes (ios_touch.mm): "captured" while a finger turns it.
namespace ios { bool touch_camera_active(); }  // ios_touch.mm
namespace mods {
bool mouse_captured() { return ios::touch_camera_active(); }
void mouse_release() {}
}  // namespace mods

// the Vulkan renderer's shader journal (vk/vk_draw.cpp); nothing to write on Metal
extern "C" void wwhd_compile_journal_on_crash() {}
