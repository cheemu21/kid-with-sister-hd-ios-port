// GX2 surface format mapping. Texel layouts follow Cemu's LatteTextureLoader decoders.
#include "formats.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>

namespace gfx {

// whether the GPU samples BC1-5 itself (every Mac; on iOS only some devices)
static bool bc_native() {
    static const bool native = [] {
        if (const char* e = getenv("WWHD_BC_DECODE")) return atoi(e) == 0;  // 1: always decode on the CPU
        id<MTLDevice> d = MTLCreateSystemDefaultDevice();
        if (@available(iOS 16.4, macOS 11.0, *)) return (bool)d.supportsBCTextureCompression;
        return false;
    }();
    return native;
}

static FormatInfo make(MTLPixelFormat p, uint32_t bpb, FormatInfo::Kind kind = FormatInfo::FLOAT, Convert cv = Convert::NONE,
                       uint32_t hostBpb = 0) {
    FormatInfo f;
    f.pixel = p;
    f.bytesPerBlock = bpb;
    f.hostBytesPerBlock = hostBpb ? hostBpb : bpb;
    f.convert = cv;
    f.kind = kind;
    return f;
}

FormatInfo format_info(uint32_t fmt, bool isDepth) {
    const uint32_t hw = fmt & 0x3F;
    const bool isInt = fmt & 0x100, isSigned = fmt & 0x200, isSrgb = fmt & 0x400;
    const auto kind = isInt ? (isSigned ? FormatInfo::SINT : FormatInfo::UINT) : FormatInfo::FLOAT;
    auto pick = [&](MTLPixelFormat unorm, MTLPixelFormat snorm, MTLPixelFormat uint, MTLPixelFormat sint) {
        if (isInt) return isSigned ? sint : uint;
        return isSigned ? snorm : unorm;
    };
    if (isDepth) {
        FormatInfo f;
        f.depth = true;
        switch (hw) {
        case 0x05: f.pixel = MTLPixelFormatDepth16Unorm; f.bytesPerBlock = f.hostBytesPerBlock = 2; return f;
        case 0x0E: f.pixel = MTLPixelFormatDepth32Float; f.bytesPerBlock = f.hostBytesPerBlock = 4; return f;
        case 0x11: case 0x12: case 0x13: case 0x14:
            f.pixel = MTLPixelFormatDepth32Float_Stencil8; f.stencil = true; f.bytesPerBlock = 4; f.hostBytesPerBlock = 8;
            f.convert = Convert::D24S8; return f;
        case 0x1C:
            f.pixel = MTLPixelFormatDepth32Float_Stencil8; f.stencil = true; f.bytesPerBlock = 8; f.hostBytesPerBlock = 8;
            f.convert = Convert::X24_8_32F; return f;
        default: break;
        }
    }
    FormatInfo f;
    switch (hw) {
    case 0x01: f = make(pick(MTLPixelFormatR8Unorm, MTLPixelFormatR8Snorm, MTLPixelFormatR8Uint, MTLPixelFormatR8Sint), 1, kind); break;
    case 0x02: f = make(MTLPixelFormatRG8Unorm, 1, kind, Convert::RG4, 2); break;
    case 0x05: f = make(pick(MTLPixelFormatR16Unorm, MTLPixelFormatR16Snorm, MTLPixelFormatR16Uint, MTLPixelFormatR16Sint), 2, kind); break;
    case 0x06: f = make(MTLPixelFormatR16Float, 2); break;
    case 0x07: f = make(pick(MTLPixelFormatRG8Unorm, MTLPixelFormatRG8Snorm, MTLPixelFormatRG8Uint, MTLPixelFormatRG8Sint), 2, kind); break;
    case 0x08: f = make(MTLPixelFormatRGBA8Unorm, 2, kind, Convert::RGB565, 4); break;
    case 0x0A: f = make(MTLPixelFormatRGBA8Unorm, 2, kind, Convert::RGBA5551, 4); break;
    case 0x0B: f = make(MTLPixelFormatRGBA8Unorm, 2, kind, Convert::RGBA4, 4); break;
    case 0x0C: f = make(MTLPixelFormatRGBA8Unorm, 2, kind, Convert::ABGR1555, 4); break;
    case 0x0D: f = make(isSigned ? MTLPixelFormatR32Sint : MTLPixelFormatR32Uint, 4, isSigned ? FormatInfo::SINT : FormatInfo::UINT); break;
    case 0x0E: f = make(MTLPixelFormatR32Float, 4); break;
    case 0x0F: f = make(pick(MTLPixelFormatRG16Unorm, MTLPixelFormatRG16Snorm, MTLPixelFormatRG16Uint, MTLPixelFormatRG16Sint), 4, kind); break;
    case 0x10: f = make(MTLPixelFormatRG16Float, 4); break;
    case 0x16: case 0x15: f = make(MTLPixelFormatRG11B10Float, 4); break;
    case 0x19: f = make(isInt ? MTLPixelFormatRGB10A2Uint : MTLPixelFormatRGB10A2Unorm, 4, kind); break;
    case 0x1A:
        f = make(isSrgb ? MTLPixelFormatRGBA8Unorm_sRGB
                        : pick(MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Snorm, MTLPixelFormatRGBA8Uint, MTLPixelFormatRGBA8Sint),
                 4, kind);
        break;
    case 0x1B: f = make(MTLPixelFormatRGB10A2Unorm, 4, kind); break;
    case 0x1D: f = make(isSigned ? MTLPixelFormatRG32Sint : MTLPixelFormatRG32Uint, 8, isSigned ? FormatInfo::SINT : FormatInfo::UINT); break;
    case 0x1E: f = make(MTLPixelFormatRG32Float, 8); break;
    case 0x1F: f = make(pick(MTLPixelFormatRGBA16Unorm, MTLPixelFormatRGBA16Snorm, MTLPixelFormatRGBA16Uint, MTLPixelFormatRGBA16Sint), 8, kind); break;
    case 0x20: f = make(MTLPixelFormatRGBA16Float, 8); break;
    case 0x22: f = make(isSigned ? MTLPixelFormatRGBA32Sint : MTLPixelFormatRGBA32Uint, 16, isSigned ? FormatInfo::SINT : FormatInfo::UINT); break;
    case 0x23: f = make(MTLPixelFormatRGBA32Float, 16); break;
    case 0x31: f = make(isSrgb ? MTLPixelFormatBC1_RGBA_sRGB : MTLPixelFormatBC1_RGBA, 8); f.compressed = true; break;
    case 0x32: f = make(isSrgb ? MTLPixelFormatBC2_RGBA_sRGB : MTLPixelFormatBC2_RGBA, 16); f.compressed = true; break;
    case 0x33: f = make(isSrgb ? MTLPixelFormatBC3_RGBA_sRGB : MTLPixelFormatBC3_RGBA, 16); f.compressed = true; break;
    case 0x34: f = make(isSigned ? MTLPixelFormatBC4_RSnorm : MTLPixelFormatBC4_RUnorm, 8); f.compressed = true; break;
    case 0x35: f = make(isSigned ? MTLPixelFormatBC5_RGSnorm : MTLPixelFormatBC5_RGUnorm, 16); f.compressed = true; break;
    // depth formats sampled as color textures
    case 0x11: case 0x12: case 0x13: case 0x14: f = make(MTLPixelFormatR32Float, 4, FormatInfo::FLOAT, Convert::D24_R32F, 4); break;
    default: f = make(MTLPixelFormatRGBA8Unorm, 4); break;
    }
    if (f.compressed && !bc_native()) {
        const uint8_t bc = (uint8_t)(hw - 0x30);  // 0x31..0x35: BC1..BC5
        f.bcDecode = bc;
        f.bcSigned = isSigned;
        f.pixel = bc <= 3 ? (isSrgb ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm)
                : bc == 4 ? (isSigned ? MTLPixelFormatR8Snorm : MTLPixelFormatR8Unorm)
                          : (isSigned ? MTLPixelFormatRG8Snorm : MTLPixelFormatRG8Unorm);
    }
    return f;
}

static inline uint8_t ex5(uint32_t v) { return (uint8_t)((v << 3) | (v >> 2)); }
static inline uint8_t ex6(uint32_t v) { return (uint8_t)((v << 2) | (v >> 4)); }
static inline uint8_t ex4(uint32_t v) { return (uint8_t)((v << 4) | v); }

void convert_row(Convert c, const uint8_t* src, uint8_t* dst, uint32_t n) {
    switch (c) {
    case Convert::NONE: break;
    case Convert::RGB565:
        for (uint32_t i = 0; i < n; i++) {
            uint16_t v = ((const uint16_t*)src)[i];
            dst[4 * i + 0] = ex5(v & 0x1F);
            dst[4 * i + 1] = ex6((v >> 5) & 0x3F);
            dst[4 * i + 2] = ex5((v >> 11) & 0x1F);
            dst[4 * i + 3] = 255;
        }
        break;
    case Convert::RGBA5551:
        for (uint32_t i = 0; i < n; i++) {
            uint16_t v = ((const uint16_t*)src)[i];
            dst[4 * i + 0] = ex5(v & 0x1F);
            dst[4 * i + 1] = ex5((v >> 5) & 0x1F);
            dst[4 * i + 2] = ex5((v >> 10) & 0x1F);
            dst[4 * i + 3] = (v >> 15) ? 255 : 0;
        }
        break;
    case Convert::ABGR1555:
        for (uint32_t i = 0; i < n; i++) {
            uint16_t v = ((const uint16_t*)src)[i];
            dst[4 * i + 0] = ex5((v >> 11) & 0x1F);
            dst[4 * i + 1] = ex5((v >> 6) & 0x1F);
            dst[4 * i + 2] = ex5((v >> 1) & 0x1F);
            dst[4 * i + 3] = (v & 1) ? 255 : 0;
        }
        break;
    case Convert::RGBA4:
        for (uint32_t i = 0; i < n; i++) {
            uint16_t v = ((const uint16_t*)src)[i];
            dst[4 * i + 0] = ex4(v & 0xF);
            dst[4 * i + 1] = ex4((v >> 4) & 0xF);
            dst[4 * i + 2] = ex4((v >> 8) & 0xF);
            dst[4 * i + 3] = ex4((v >> 12) & 0xF);
        }
        break;
    case Convert::RG4:
        for (uint32_t i = 0; i < n; i++) {
            uint8_t v = src[i];
            dst[2 * i + 0] = ex4(v >> 4);
            dst[2 * i + 1] = ex4(v & 0xF);
        }
        break;
    case Convert::D24S8:
        for (uint32_t i = 0; i < n; i++) {
            uint32_t v = ((const uint32_t*)src)[i];
            float d = (float)(v & 0xFFFFFF) / 16777215.0f;
            memcpy(dst + 8 * i, &d, 4);
            dst[8 * i + 4] = (uint8_t)(v >> 24);
            dst[8 * i + 5] = dst[8 * i + 6] = dst[8 * i + 7] = 0;
        }
        break;
    case Convert::D24_R32F:
        for (uint32_t i = 0; i < n; i++) {
            uint32_t v = ((const uint32_t*)src)[i];
            float d = (float)(v & 0xFFFFFF) / 16777215.0f;
            memcpy(dst + 4 * i, &d, 4);
        }
        break;
    case Convert::X24_8_32F:
        memcpy(dst, src, n * 8);
        break;
    }
}

}  // namespace gfx

// ---------------------------------------------------------------- BC1-5 on the CPU
namespace gfx {
uint32_t bc_texel_bytes(uint8_t bc) { return bc <= 3 ? 4 : bc == 4 ? 1 : 2; }

namespace {
void rgb565(uint16_t c, int* o) {
    o[0] = ((c >> 11) & 31) * 255 / 31;
    o[1] = ((c >> 5) & 63) * 255 / 63;
    o[2] = (c & 31) * 255 / 31;
}
// colour block (8 bytes) into 16 RGBA texels; fourColor: BC2/BC3 never use the 3-colour mode
void color_block(const uint8_t* b, bool fourColor, uint8_t out[16][4]) {
    uint16_t c0 = b[0] | b[1] << 8, c1 = b[2] | b[3] << 8;
    int p[4][4];
    rgb565(c0, p[0]);
    rgb565(c1, p[1]);
    p[0][3] = p[1][3] = p[2][3] = p[3][3] = 255;
    if (fourColor || c0 > c1) {
        for (int i = 0; i < 3; i++) {
            p[2][i] = (2 * p[0][i] + p[1][i]) / 3;
            p[3][i] = (p[0][i] + 2 * p[1][i]) / 3;
        }
    } else {
        for (int i = 0; i < 3; i++) { p[2][i] = (p[0][i] + p[1][i]) / 2; p[3][i] = 0; }
        p[3][3] = 0;
    }
    uint32_t idx = b[4] | b[5] << 8 | b[6] << 16 | (uint32_t)b[7] << 24;
    for (int t = 0; t < 16; t++) {
        const int* c = p[(idx >> (2 * t)) & 3];
        for (int i = 0; i < 4; i++) out[t][i] = (uint8_t)c[i];
    }
}
// one channel (8 bytes, BC4 / BC3 alpha / BC5 halves) into 16 values
void channel_block(const uint8_t* b, bool isSigned, uint8_t out[16]) {
    int e0 = isSigned ? std::max<int>((int8_t)b[0], -127) : b[0];
    int e1 = isSigned ? std::max<int>((int8_t)b[1], -127) : b[1];
    int v[8] = {e0, e1};
    if (e0 > e1) {
        for (int i = 1; i < 7; i++) v[i + 1] = ((7 - i) * e0 + i * e1) / 7;
    } else {
        for (int i = 1; i < 5; i++) v[i + 1] = ((5 - i) * e0 + i * e1) / 5;
        v[6] = isSigned ? -127 : 0;
        v[7] = isSigned ? 127 : 255;
    }
    uint64_t idx = 0;
    for (int i = 0; i < 6; i++) idx |= (uint64_t)b[2 + i] << (8 * i);
    for (int t = 0; t < 16; t++) out[t] = (uint8_t)(int8_t)v[(idx >> (3 * t)) & 7];
}
}  // namespace

void bc_decode(uint8_t bc, bool isSigned, const uint8_t* src, uint32_t bw, uint32_t bh, uint32_t slices, uint8_t* dst) {
    const uint32_t bpt = bc_texel_bytes(bc), blockBytes = (bc == 1 || bc == 4) ? 8 : 16;
    const size_t rowBytes = (size_t)bw * 4 * bpt, sliceBytes = rowBytes * bh * 4;
    for (uint32_t z = 0; z < slices; z++)
        for (uint32_t by = 0; by < bh; by++)
            for (uint32_t bx = 0; bx < bw; bx++, src += blockBytes) {
                uint8_t px[16][4];
                uint8_t ch[2][16];
                switch (bc) {
                case 1: color_block(src, false, px); break;
                case 2:
                    color_block(src + 8, true, px);
                    for (int t = 0; t < 16; t++) px[t][3] = (uint8_t)(((src[t / 2] >> (4 * (t & 1))) & 15) * 17);
                    break;
                case 3:
                    color_block(src + 8, true, px);
                    channel_block(src, false, ch[0]);
                    for (int t = 0; t < 16; t++) px[t][3] = ch[0][t];
                    break;
                case 4: channel_block(src, isSigned, ch[0]); break;
                default: channel_block(src, isSigned, ch[0]); channel_block(src + 8, isSigned, ch[1]); break;
                }
                for (int t = 0; t < 16; t++) {
                    uint8_t* o = dst + z * sliceBytes + (by * 4 + t / 4) * rowBytes + (bx * 4 + t % 4) * bpt;
                    if (bc <= 3) memcpy(o, px[t], 4);
                    else if (bc == 4) o[0] = ch[0][t];
                    else { o[0] = ch[0][t]; o[1] = ch[1][t]; }
                }
            }
}
}  // namespace gfx
