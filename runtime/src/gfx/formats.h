// GX2 surface formats -> Metal pixel formats, and texel conversion for
// formats Metal has no direct equivalent for.
#pragma once
#include <Metal/Metal.h>

#include <cstdint>

namespace gfx {

enum class Convert : uint8_t {
    NONE,        // copy texels as stored
    RGB565,      // Latte 5_6_5 -> RGBA8
    RGBA5551,    // Latte 1_5_5_5 (R in low bits) -> RGBA8
    ABGR1555,    // Latte 5_5_5_1 -> RGBA8
    RGBA4,       // Latte 4_4_4_4 -> RGBA8
    RG4,         // Latte 4_4 -> RG8
    D24S8,       // 24-bit depth + 8-bit stencil -> Depth32Float_Stencil8
    D24_R32F,    // 24-bit depth sampled as a color texture -> R32Float
    X24_8_32F,   // 32F depth + 8 stencil in 64 bits -> Depth32Float_Stencil8
};

struct FormatInfo {
    MTLPixelFormat pixel = MTLPixelFormatInvalid;
    uint32_t bytesPerBlock = 0;  // guest (source) bytes per texel or per 4x4 block
    uint32_t hostBytesPerBlock = 0;
    bool compressed = false;     // 4x4 blocks
    // BC1-5 the GPU can't sample (iOS devices without BC texture support): pixel is RGBA8 / R8 / RG8 and
    // the blocks are decoded on the CPU at upload (bc_decode); 0 = none, else the BC number
    uint8_t bcDecode = 0;
    bool bcSigned = false;
    bool depth = false;
    bool stencil = false;
    Convert convert = Convert::NONE;
    enum Kind : uint8_t { FLOAT, UINT, SINT } kind = FLOAT;  // shader-visible data type
};

// isDepth: the surface is used as a depth buffer (selects depth pixel formats)
FormatInfo format_info(uint32_t gx2Format, bool isDepth);

// bcDecode != 0: decode bw x bh blocks per slice into texels (rows of bw * 4 texels); bytes per texel
// are bc_texel_bytes
uint32_t bc_texel_bytes(uint8_t bc);
void bc_decode(uint8_t bc, bool isSigned, const uint8_t* src, uint32_t bw, uint32_t bh, uint32_t slices, uint8_t* dst);

// convert one row of `count` texels (or blocks) from guest layout to host layout
void convert_row(Convert c, const uint8_t* src, uint8_t* dst, uint32_t count);

}  // namespace gfx
