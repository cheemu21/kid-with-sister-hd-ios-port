// The guest memory base on iOS (runtime/include/ppc.h declares it const for the game code).
// Defined here without const and without ppc.h so mem::init can set it once, before the game runs.
#include <cstdint>

extern "C" {
uint8_t* ppc_mem_base = nullptr;
}

namespace mem {
void set_base(uint8_t* base) { ppc_mem_base = base; }
}  // namespace mem
