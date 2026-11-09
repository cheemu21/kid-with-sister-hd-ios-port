// Pieces of the macOS shell (mods/mouse.mm) the shared runtime calls: no mouse camera on iOS.
namespace mods {
bool mouse_captured() { return false; }
void mouse_release() {}
}  // namespace mods

// the Vulkan renderer's shader journal (vk/vk_draw.cpp); nothing to write on Metal
extern "C" void wwhd_compile_journal_on_crash() {}
