#include "dm_metalfx_bridge.h"
#include "dm_upscaler_abi.h"
#include "dm_png_writer.hpp"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include <climits>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <time.h>

extern "C" {
int dm_ffx_fsr_query_render_resolution(int quality_mode, uint32_t out_w, uint32_t out_h,
                                       uint32_t *in_w, uint32_t *in_h);
int dm_xess_get_input_resolution(int quality_preset, uint32_t out_w, uint32_t out_h,
                                 uint32_t *in_w, uint32_t *in_h);
}

#define DM_CHECK(expr)                                                                 \
    do {                                                                               \
        if (!(expr)) {                                                                 \
            fprintf(stderr, "[dm_metalfx_bench] CHECK FAILED (%s:%d): %s\n",           \
                    __FILE__, __LINE__, #expr);                                        \
            std::abort();                                                              \
        }                                                                              \
    } while (0)

static bool ctest_skip_allowed(void) {
    const char *v = std::getenv("DM_CTEST_ALLOW_SKIP");
    return v && v[0] && std::strcmp(v, "0") != 0;
}

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static void ensure_dir(const std::string &dir) {
    std::string cur;
    for (char c : dir) {
        cur.push_back(c);
        if (c == '/' && cur.size() > 1) mkdir(cur.c_str(), 0755);
    }
    mkdir(dir.c_str(), 0755);
}

static float halton(int idx, int base) {
    float f = 1.0f, r = 0.0f;
    int i = idx;
    while (i > 0) {
        f /= (float)base;
        r += f * (float)(i % base);
        i /= base;
    }
    return r;
}

static void save_private_tex_png(id<MTLDevice> dev, id<MTLCommandQueue> queue,
                                 id<MTLTexture> tex, id<MTLComputePipelineState> fp16_blit_pso,
                                 const std::string &path) {
    DM_CHECK(dev != nil && queue != nil && tex != nil);
    const NSUInteger w = tex.width, h = tex.height;
    id<MTLTexture> rgba8_tex = tex;

    id<MTLCommandBuffer> cb = [queue commandBuffer];
    DM_CHECK(cb != nil);
    if (tex.pixelFormat == MTLPixelFormatRGBA16Float) {
        DM_CHECK(fp16_blit_pso != nil);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                      width:w height:h mipmapped:NO];
        DM_CHECK(td != nil);
        td.usage = MTLTextureUsageShaderWrite;
        td.storageMode = MTLStorageModePrivate;
        rgba8_tex = [dev newTextureWithDescriptor:td];
        DM_CHECK(rgba8_tex != nil);
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        DM_CHECK(ce != nil);
        [ce setComputePipelineState:fp16_blit_pso];
        [ce setTexture:tex atIndex:0];
        [ce setTexture:rgba8_tex atIndex:1];
        [ce dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [ce endEncoding];
    }

    const NSUInteger row_pitch = w * 4u;
    const NSUInteger total_bytes = row_pitch * h;
    id<MTLBuffer> rb = [dev newBufferWithLength:total_bytes options:MTLResourceStorageModeShared];
    DM_CHECK(rb != nil && rb.contents != nullptr);
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    DM_CHECK(be != nil);
    [be copyFromTexture:rgba8_tex
            sourceSlice:0
            sourceLevel:0
           sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(w, h, 1)
               toBuffer:rb
      destinationOffset:0
 destinationBytesPerRow:row_pitch
destinationBytesPerImage:total_bytes];
    [be endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    DM_CHECK(cb.status == MTLCommandBufferStatusCompleted);

    DM_CHECK(dm::write_png_rgba8(path, (uint32_t)w, (uint32_t)h,
                                 static_cast<const uint8_t *>(rb.contents), (uint32_t)row_pitch));
}

static void run_device_independent_metalfx_and_shim_tests(void) {
    // 1. NULL context / output / parameter guards (device-independent)
    DM_CHECK(!dm_metalfx_query_caps(nullptr));
    dm_metalfx_spatial_destroy(nullptr);
    dm_metalfx_temporal_destroy(nullptr);
    dm_upscaler_destroy(nullptr);

    int dummy = 42;
    DM_CHECK(!dm_metalfx_spatial_encode(nullptr, &dummy, &dummy, &dummy, 1280, 720));
    DM_CHECK(!dm_metalfx_spatial_encode(nullptr, nullptr, nullptr, nullptr, 0, 0));
    DM_CHECK(!dm_metalfx_temporal_encode(nullptr, &dummy, &dummy, &dummy, &dummy, &dummy,
                                         0.0f, 0.0f, 1.0f, 1.0f, true));
    DM_CHECK(!dm_metalfx_temporal_encode(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr,
                                         0.0f, 0.0f, 1.0f, 1.0f, false));

    dm_upscale_dispatch_desc_t empty_desc{};
    DM_CHECK(!dm_upscaler_dispatch(nullptr, nullptr));
    DM_CHECK(!dm_upscaler_dispatch(nullptr, &empty_desc));

    uint32_t sentinel_w = 0xDEADu;
    uint32_t sentinel_h = 0xBEEFu;
    dm_upscaler_get_render_resolution(nullptr, nullptr, nullptr);
    dm_upscaler_get_render_resolution(nullptr, &sentinel_w, &sentinel_h);
    DM_CHECK(sentinel_w == 0xDEADu && sentinel_h == 0xBEEFu);

    // 2. Invalid 0x0, downscale (input > output), and invalid pixel format (0) create guards
    DM_CHECK(dm_metalfx_spatial_create(0, 0, 0, 0, MTLPixelFormatRGBA8Unorm, false) == nullptr);
    DM_CHECK(dm_metalfx_spatial_create(0, 720, 1920, 1080, MTLPixelFormatRGBA8Unorm, false) == nullptr);
    DM_CHECK(dm_metalfx_spatial_create(1280, 0, 1920, 1080, MTLPixelFormatRGBA8Unorm, false) == nullptr);
    DM_CHECK(dm_metalfx_spatial_create(1280, 720, 0, 1080, MTLPixelFormatRGBA8Unorm, false) == nullptr);
    DM_CHECK(dm_metalfx_spatial_create(1280, 720, 1920, 0, MTLPixelFormatRGBA8Unorm, false) == nullptr);
    DM_CHECK(dm_metalfx_spatial_create(1921, 1080, 1920, 1080, MTLPixelFormatRGBA8Unorm, false) == nullptr);
    DM_CHECK(dm_metalfx_spatial_create(1920, 1081, 1920, 1080, MTLPixelFormatRGBA8Unorm, false) == nullptr);
    DM_CHECK(dm_metalfx_spatial_create(3840, 2160, 1920, 1080, MTLPixelFormatRGBA16Float, true) == nullptr);
    DM_CHECK(dm_metalfx_spatial_create(1280, 720, 1920, 1080, 0, false) == nullptr);

    DM_CHECK(dm_metalfx_temporal_create(0, 0, 0, 0,
                                        MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float,
                                        MTLPixelFormatRG16Float, MTLPixelFormatRGBA16Float) == nullptr);
    DM_CHECK(dm_metalfx_temporal_create(0, 720, 1920, 1080,
                                        MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float,
                                        MTLPixelFormatRG16Float, MTLPixelFormatRGBA16Float) == nullptr);
    DM_CHECK(dm_metalfx_temporal_create(1280, 0, 1920, 1080,
                                        MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float,
                                        MTLPixelFormatRG16Float, MTLPixelFormatRGBA16Float) == nullptr);
    DM_CHECK(dm_metalfx_temporal_create(1280, 720, 0, 1080,
                                        MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float,
                                        MTLPixelFormatRG16Float, MTLPixelFormatRGBA16Float) == nullptr);
    DM_CHECK(dm_metalfx_temporal_create(1280, 720, 1920, 0,
                                        MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float,
                                        MTLPixelFormatRG16Float, MTLPixelFormatRGBA16Float) == nullptr);
    DM_CHECK(dm_metalfx_temporal_create(1921, 1080, 1920, 1080,
                                        MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float,
                                        MTLPixelFormatRG16Float, MTLPixelFormatRGBA16Float) == nullptr);
    DM_CHECK(dm_metalfx_temporal_create(1920, 1081, 1920, 1080,
                                        MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float,
                                        MTLPixelFormatRG16Float, MTLPixelFormatRGBA16Float) == nullptr);
    DM_CHECK(dm_metalfx_temporal_create(1280, 720, 1920, 1080,
                                        0, MTLPixelFormatDepth32Float,
                                        MTLPixelFormatRG16Float, MTLPixelFormatRGBA16Float) == nullptr);
    DM_CHECK(dm_metalfx_temporal_create(1280, 720, 1920, 1080,
                                        MTLPixelFormatRGBA16Float, 0,
                                        MTLPixelFormatRG16Float, MTLPixelFormatRGBA16Float) == nullptr);
    DM_CHECK(dm_metalfx_temporal_create(1280, 720, 1920, 1080,
                                        MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float,
                                        0, MTLPixelFormatRGBA16Float) == nullptr);
    DM_CHECK(dm_metalfx_temporal_create(1280, 720, 1920, 1080,
                                        MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float,
                                        MTLPixelFormatRG16Float, 0) == nullptr);

    // Unified ABI create rejection on 0x0, sub-minimum (<64px where clamped rw > output), and format=0
    DM_CHECK(dm_upscaler_create(DM_UPSCALER_FSR, DM_UPSCALE_QUALITY, 0, 0, false,
                                MTLPixelFormatRGBA8Unorm, 0, 0) == nullptr);
    DM_CHECK(dm_upscaler_create(DM_UPSCALER_FSR, DM_UPSCALE_QUALITY, 0, 1080, false,
                                MTLPixelFormatRGBA8Unorm, 0, 0) == nullptr);
    DM_CHECK(dm_upscaler_create(DM_UPSCALER_FSR, DM_UPSCALE_QUALITY, 1920, 0, false,
                                MTLPixelFormatRGBA8Unorm, 0, 0) == nullptr);
    DM_CHECK(dm_upscaler_create(DM_UPSCALER_XESS, DM_UPSCALE_QUALITY, 0, 0, true,
                                MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float, MTLPixelFormatRG16Float) == nullptr);
    DM_CHECK(dm_upscaler_create(DM_UPSCALER_METALFX, DM_UPSCALE_QUALITY, 32, 32, false,
                                MTLPixelFormatRGBA8Unorm, 0, 0) == nullptr);
    DM_CHECK(dm_upscaler_create(DM_UPSCALER_METALFX, DM_UPSCALE_QUALITY, 32, 32, true,
                                MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float, MTLPixelFormatRG16Float) == nullptr);
    DM_CHECK(dm_upscaler_create(DM_UPSCALER_FSR, DM_UPSCALE_QUALITY, 1920, 1080, false, 0, 0, 0) == nullptr);
    DM_CHECK(dm_upscaler_create(DM_UPSCALER_FSR, DM_UPSCALE_QUALITY, 1920, 1080, true,
                                MTLPixelFormatRGBA16Float, 0, MTLPixelFormatRG16Float) == nullptr);
    DM_CHECK(dm_upscaler_create(DM_UPSCALER_FSR, DM_UPSCALE_QUALITY, 1920, 1080, true,
                                MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float, 0) == nullptr);

    // 3. Resolution resolver NULL out-pointers, 0x0 clamping, monotonicity & invalid quality/vendor enums
    uint32_t rw = 0, rh = 0;
    dm_metalfx_resolve_render_size(DM_UPSCALER_METALFX, DM_UPSCALE_QUALITY, 1920, 1080, nullptr, nullptr);
    dm_metalfx_resolve_render_size(DM_UPSCALER_METALFX, DM_UPSCALE_QUALITY, 1920, 1080, &rw, nullptr);
    dm_metalfx_resolve_render_size(DM_UPSCALER_METALFX, DM_UPSCALE_QUALITY, 1920, 1080, nullptr, &rh);
    DM_CHECK(rw == 1280u && rh == 720u);

    uint32_t zero_w = 0, zero_h = 0;
    dm_metalfx_resolve_render_size(DM_UPSCALER_FSR, DM_UPSCALE_QUALITY, 0, 0, &zero_w, &zero_h);
    DM_CHECK(zero_w == 64u && zero_h == 64u);
    dm_metalfx_resolve_render_size(DM_UPSCALER_DLSS, DM_UPSCALE_ULTRA_PERFORMANCE, 13, 19, &zero_w, &zero_h);
    DM_CHECK(zero_w == 64u && zero_h == 64u);

    const dm_upscaler_vendor_t vendors[4] = {
        DM_UPSCALER_METALFX, DM_UPSCALER_DLSS, DM_UPSCALER_FSR, DM_UPSCALER_XESS
    };
    const dm_upscale_quality_t qualities[5] = {
        DM_UPSCALE_ULTRA_QUALITY, DM_UPSCALE_QUALITY, DM_UPSCALE_BALANCED,
        DM_UPSCALE_PERFORMANCE, DM_UPSCALE_ULTRA_PERFORMANCE
    };
    for (dm_upscaler_vendor_t v : vendors) {
        uint32_t prev_w = 3840u, prev_h = 2160u;
        for (dm_upscale_quality_t q : qualities) {
            uint32_t cw = 0, ch = 0;
            dm_metalfx_resolve_render_size(v, q, 3840, 2160, &cw, &ch);
            DM_CHECK(cw >= 64u && ch >= 64u);
            DM_CHECK((cw % 2u) == 0u && (ch % 2u) == 0u);
            DM_CHECK(cw <= prev_w && ch <= prev_h);
            prev_w = cw;
            prev_h = ch;
        }
    }

    // Invalid quality and vendor enum values must safely default to Quality (1.5x -> 1280x720)
    const int bad_qualities[3] = {-1, 99, INT_MAX};
    for (int bq : bad_qualities) {
        uint32_t bw = 0, bh = 0;
        dm_metalfx_resolve_render_size(static_cast<dm_upscaler_vendor_t>(-7),
                                       static_cast<dm_upscale_quality_t>(bq),
                                       1920, 1080, &bw, &bh);
        DM_CHECK(bw == 1280u && bh == 720u);
    }

    // 4. ffx_fsr_shim & libxess_shim NULL / 0x0 / invalid quality parameter safety
    DM_CHECK(dm_ffx_fsr_query_render_resolution(1, 1920, 1080, nullptr, nullptr) == 0);
    uint32_t fsr_w = 0, fsr_h = 0;
    DM_CHECK(dm_ffx_fsr_query_render_resolution(1, 1920, 1080, &fsr_w, nullptr) == 0 && fsr_w == 1280u);
    DM_CHECK(dm_ffx_fsr_query_render_resolution(1, 1920, 1080, nullptr, &fsr_h) == 0 && fsr_h == 720u);

    uint32_t exp_bw = 0, exp_bh = 0;
    dm_metalfx_resolve_render_size(DM_UPSCALER_FSR, DM_UPSCALE_BALANCED, 1920, 1080, &exp_bw, &exp_bh);
    DM_CHECK(dm_ffx_fsr_query_render_resolution(2, 1920, 1080, &fsr_w, &fsr_h) == 0);
    DM_CHECK(fsr_w == exp_bw && fsr_h == exp_bh);
    DM_CHECK(dm_ffx_fsr_query_render_resolution(3, 1920, 1080, &fsr_w, &fsr_h) == 0);
    DM_CHECK(fsr_w == 960u && fsr_h == 540u);
    DM_CHECK(dm_ffx_fsr_query_render_resolution(4, 1920, 1080, &fsr_w, &fsr_h) == 0);
    DM_CHECK(fsr_w == 640u && fsr_h == 360u);

    const int invalid_fsr_modes[6] = {INT_MIN, -1, 0, 5, 999, INT_MAX};
    for (int m : invalid_fsr_modes) {
        fsr_w = 0;
        fsr_h = 0;
        DM_CHECK(dm_ffx_fsr_query_render_resolution(m, 1920, 1080, &fsr_w, &fsr_h) == 0);
        DM_CHECK(fsr_w == 1280u && fsr_h == 720u);
    }
    DM_CHECK(dm_ffx_fsr_query_render_resolution(3, 0, 0, &fsr_w, &fsr_h) == 0);
    DM_CHECK(fsr_w == 64u && fsr_h == 64u);

    DM_CHECK(dm_xess_get_input_resolution(102, 1920, 1080, nullptr, nullptr) == 0);
    uint32_t xess_w = 0, xess_h = 0;
    DM_CHECK(dm_xess_get_input_resolution(102, 1920, 1080, &xess_w, nullptr) == 0 && xess_w == 1280u);
    DM_CHECK(dm_xess_get_input_resolution(102, 1920, 1080, nullptr, &xess_h) == 0 && xess_h == 720u);
    DM_CHECK(dm_xess_get_input_resolution(100, 1920, 1080, &xess_w, &xess_h) == 0);
    DM_CHECK(xess_w == 960u && xess_h == 540u);
    DM_CHECK(dm_xess_get_input_resolution(101, 1920, 1080, &xess_w, &xess_h) == 0);
    DM_CHECK(xess_w == exp_bw && xess_h == exp_bh);

    uint32_t exp_uqw = 0, exp_uqh = 0;
    dm_metalfx_resolve_render_size(DM_UPSCALER_XESS, DM_UPSCALE_ULTRA_QUALITY, 1920, 1080, &exp_uqw, &exp_uqh);
    DM_CHECK(dm_xess_get_input_resolution(103, 1920, 1080, &xess_w, &xess_h) == 0);
    DM_CHECK(xess_w == exp_uqw && xess_h == exp_uqh);

    const int invalid_xess_presets[7] = {INT_MIN, -1, 0, 99, 104, 5000, INT_MAX};
    for (int p : invalid_xess_presets) {
        xess_w = 0;
        xess_h = 0;
        DM_CHECK(dm_xess_get_input_resolution(p, 1920, 1080, &xess_w, &xess_h) == 0);
        DM_CHECK(xess_w == 1280u && xess_h == 720u);
    }
    DM_CHECK(dm_xess_get_input_resolution(100, 0, 0, &xess_w, &xess_h) == 0);
    DM_CHECK(xess_w == 64u && xess_h == 64u);
}

static void run_gpu_metalfx_and_shim_edge_tests(id<MTLDevice> dev,
                                                id<MTLCommandQueue> queue,
                                                const dm_metalfx_caps_t &caps) {
    DM_CHECK(std::isfinite(caps.temporal_min_scale) && std::isfinite(caps.temporal_max_scale));
    DM_CHECK(caps.temporal_min_scale > 0.0f && caps.temporal_max_scale >= caps.temporal_min_scale);

    // 1. Out-of-range upscale dimensions & unsupported scale ratios on live MetalFX device
    // Downscale dimensions (input > output) and sub-minimum (<64px) output sizes must fail cleanly
    DM_CHECK(dm_metalfx_spatial_create(2560, 1440, 1920, 1080, MTLPixelFormatRGBA8Unorm, false) == nullptr);
    DM_CHECK(dm_metalfx_spatial_create(1922, 1080, 1920, 1080, MTLPixelFormatRGBA16Float, true) == nullptr);
    DM_CHECK(dm_metalfx_temporal_create(2560, 1440, 1920, 1080,
                                        MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float,
                                        MTLPixelFormatRG16Float, MTLPixelFormatRGBA16Float) == nullptr);
    // Extreme 60x upscale ratio (64x64 -> 3840x2160, within 16384 2D texture limit) exceeds temporal_max_scale
    DM_CHECK(dm_metalfx_temporal_create(64, 64, 3840, 2160,
                                        MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float,
                                        MTLPixelFormatRG16Float, MTLPixelFormatRGBA16Float) == nullptr);
    DM_CHECK(dm_upscaler_create(DM_UPSCALER_FSR, DM_UPSCALE_ULTRA_QUALITY, 48, 48, false,
                                MTLPixelFormatRGBA8Unorm, 0, 0) == nullptr);
    DM_CHECK(dm_upscaler_create(DM_UPSCALER_XESS, DM_UPSCALE_ULTRA_QUALITY, 48, 48, true,
                                MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float, MTLPixelFormatRG16Float) == nullptr);

    auto make_priv_tex = [&](uint32_t w, uint32_t h, MTLPixelFormat fmt, MTLTextureUsage usage) -> id<MTLTexture> {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:w height:h mipmapped:NO];
        DM_CHECK(td != nil);
        td.usage = usage;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> t = [dev newTextureWithDescriptor:td];
        DM_CHECK(t != nil);
        return t;
    };

    // 2. Live spatial & temporal encode NULL and out-of-bounds content dimension guards
    dm_metalfx_spatial_t *sc = dm_metalfx_spatial_create(640, 360, 1280, 720, MTLPixelFormatRGBA8Unorm, false);
    DM_CHECK(sc != nullptr);
    dm_metalfx_spatial_t *sc_hdr = dm_metalfx_spatial_create(640, 360, 1280, 720, MTLPixelFormatRGBA16Float, true);
    DM_CHECK(sc_hdr != nullptr);
    dm_metalfx_spatial_destroy(sc_hdr);

    id<MTLTexture> sp_in = make_priv_tex(640, 360, MTLPixelFormatRGBA8Unorm,
                                         MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
    id<MTLTexture> sp_out = make_priv_tex(1280, 720, MTLPixelFormatRGBA8Unorm,
                                          MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
    id<MTLCommandBuffer> guard_cb = [queue commandBuffer];
    DM_CHECK(guard_cb != nil);

    DM_CHECK(!dm_metalfx_spatial_encode(sc, nullptr, (__bridge void *)sp_in, (__bridge void *)sp_out, 640, 360));
    DM_CHECK(!dm_metalfx_spatial_encode(sc, (__bridge void *)guard_cb, nullptr, (__bridge void *)sp_out, 640, 360));
    DM_CHECK(!dm_metalfx_spatial_encode(sc, (__bridge void *)guard_cb, (__bridge void *)sp_in, nullptr, 640, 360));
    DM_CHECK(!dm_metalfx_spatial_encode(sc, (__bridge void *)guard_cb, (__bridge void *)sp_in, (__bridge void *)sp_out, 0, 360));
    DM_CHECK(!dm_metalfx_spatial_encode(sc, (__bridge void *)guard_cb, (__bridge void *)sp_in, (__bridge void *)sp_out, 640, 0));
    DM_CHECK(!dm_metalfx_spatial_encode(sc, (__bridge void *)guard_cb, (__bridge void *)sp_in, (__bridge void *)sp_out, 641, 360));
    DM_CHECK(!dm_metalfx_spatial_encode(sc, (__bridge void *)guard_cb, (__bridge void *)sp_in, (__bridge void *)sp_out, 640, 361));
    dm_metalfx_spatial_destroy(sc);

    dm_metalfx_temporal_t *tc = dm_metalfx_temporal_create(
        640, 360, 1280, 720,
        MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float,
        MTLPixelFormatRG16Float, MTLPixelFormatRGBA16Float);
    DM_CHECK(tc != nullptr);
    id<MTLTexture> tp_col = make_priv_tex(640, 360, MTLPixelFormatRGBA16Float,
                                          MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
    id<MTLTexture> tp_dep = make_priv_tex(640, 360, MTLPixelFormatDepth32Float,
                                          MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
    id<MTLTexture> tp_mot = make_priv_tex(640, 360, MTLPixelFormatRG16Float,
                                          MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
    id<MTLTexture> tp_out = make_priv_tex(1280, 720, MTLPixelFormatRGBA16Float,
                                          MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);

    DM_CHECK(!dm_metalfx_temporal_encode(tc, nullptr, (__bridge void *)tp_col, (__bridge void *)tp_dep,
                                         (__bridge void *)tp_mot, (__bridge void *)tp_out, 0.0f, 0.0f, 1.0f, 1.0f, true));
    DM_CHECK(!dm_metalfx_temporal_encode(tc, (__bridge void *)guard_cb, nullptr, (__bridge void *)tp_dep,
                                         (__bridge void *)tp_mot, (__bridge void *)tp_out, 0.0f, 0.0f, 1.0f, 1.0f, true));
    DM_CHECK(!dm_metalfx_temporal_encode(tc, (__bridge void *)guard_cb, (__bridge void *)tp_col, nullptr,
                                         (__bridge void *)tp_mot, (__bridge void *)tp_out, 0.0f, 0.0f, 1.0f, 1.0f, true));
    DM_CHECK(!dm_metalfx_temporal_encode(tc, (__bridge void *)guard_cb, (__bridge void *)tp_col, (__bridge void *)tp_dep,
                                         nullptr, (__bridge void *)tp_out, 0.0f, 0.0f, 1.0f, 1.0f, true));
    DM_CHECK(!dm_metalfx_temporal_encode(tc, (__bridge void *)guard_cb, (__bridge void *)tp_col, (__bridge void *)tp_dep,
                                         (__bridge void *)tp_mot, nullptr, 0.0f, 0.0f, 1.0f, 1.0f, true));
    dm_metalfx_temporal_destroy(tc);

    // 3. Unified dm_upscaler_* shim context lifecycle, invalid quality fallback & dispatch validation
    dm_upscaler_context_t *fsr_ctx = dm_upscaler_create(
        DM_UPSCALER_FSR, static_cast<dm_upscale_quality_t>(77), 1280, 720, false,
        MTLPixelFormatRGBA8Unorm, 0, 0);
    DM_CHECK(fsr_ctx != nullptr);
    uint32_t ctx_w = 0, ctx_h = 0, exp_ctx_w = 0, exp_ctx_h = 0;
    dm_metalfx_resolve_render_size(DM_UPSCALER_FSR, DM_UPSCALE_QUALITY, 1280, 720, &exp_ctx_w, &exp_ctx_h);
    dm_upscaler_get_render_resolution(fsr_ctx, nullptr, nullptr);
    dm_upscaler_get_render_resolution(fsr_ctx, &ctx_w, nullptr);
    dm_upscaler_get_render_resolution(fsr_ctx, nullptr, &ctx_h);
    DM_CHECK(ctx_w == 852u && ctx_h == 480u);
    DM_CHECK(ctx_w == exp_ctx_w && ctx_h == exp_ctx_h);

    id<MTLTexture> fsr_in = make_priv_tex(ctx_w, ctx_h, MTLPixelFormatRGBA8Unorm,
                                          MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
    DM_CHECK(!dm_upscaler_dispatch(fsr_ctx, nullptr));
    dm_upscale_dispatch_desc_t bad_sp_desc{};
    DM_CHECK(!dm_upscaler_dispatch(fsr_ctx, &bad_sp_desc));

    bad_sp_desc.command_buffer = (__bridge void *)guard_cb;
    bad_sp_desc.color_texture = (__bridge void *)fsr_in;
    bad_sp_desc.output_texture = (__bridge void *)sp_out;
    bad_sp_desc.render_width = ctx_w + 2u;  // Exceeds color_texture.width
    bad_sp_desc.render_height = ctx_h;
    DM_CHECK(!dm_upscaler_dispatch(fsr_ctx, &bad_sp_desc));

    // render_width/height == 0 falls back cleanly to ctx->render_width/height
    bad_sp_desc.render_width = 0;
    bad_sp_desc.render_height = 0;
    DM_CHECK(dm_upscaler_dispatch(fsr_ctx, &bad_sp_desc));

    dm_upscaler_context_t *xess_ctx = dm_upscaler_create(
        DM_UPSCALER_XESS, DM_UPSCALE_PERFORMANCE, 1280, 720, true,
        MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float, MTLPixelFormatRG16Float);
    DM_CHECK(xess_ctx != nullptr);
    uint32_t xw = 0, xh = 0;
    dm_upscaler_get_render_resolution(xess_ctx, &xw, &xh);
    DM_CHECK(xw == 640u && xh == 360u);

    dm_upscale_dispatch_desc_t tp_desc{};
    tp_desc.command_buffer = (__bridge void *)guard_cb;
    tp_desc.color_texture = (__bridge void *)tp_col;
    tp_desc.output_texture = (__bridge void *)tp_out;
    DM_CHECK(!dm_upscaler_dispatch(xess_ctx, &tp_desc));  // Missing depth & motion textures

    tp_desc.depth_texture = (__bridge void *)tp_dep;
    tp_desc.motion_texture = (__bridge void *)tp_mot;
    tp_desc.motion_scale_x = 1.0f;
    tp_desc.motion_scale_y = 1.0f;
    tp_desc.reset = true;
    DM_CHECK(dm_upscaler_dispatch(xess_ctx, &tp_desc));

    [guard_cb commit];
    [guard_cb waitUntilCompleted];
    DM_CHECK(guard_cb.status == MTLCommandBufferStatusCompleted);

    dm_upscaler_destroy(fsr_ctx);
    dm_upscaler_destroy(xess_ctx);

    printf("[dm_metalfx_bench] Unit tests (NULL/0x0/out-of-range guards, quality modes, FSR/XeSS shims) OK\n");
}

int main(int argc, char **argv) {
    const char *json_path = nullptr;
    std::string out_dir = "captures/m1pro/metalfx";
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--json") == 0 && i + 1 < argc) {
            json_path = argv[++i];
        } else if (std::strcmp(argv[i], "--out-dir") == 0 && i + 1 < argc) {
            out_dir = argv[++i];
        }
    }

    run_device_independent_metalfx_and_shim_tests();

    dm_metalfx_caps_t caps;
    std::memset(&caps, 0xA5, sizeof(caps));
    if (!dm_metalfx_query_caps(&caps)) {
        DM_CHECK(!caps.spatial_supported && !caps.temporal_supported);
        DM_CHECK(caps.temporal_min_scale == 0.0f && caps.temporal_max_scale == 0.0f);
        if (ctest_skip_allowed()) {
            printf("[dm_metalfx_bench] SKIP: no Metal device available in headless environment\n");
            return 77;
        }
        fprintf(stderr, "[dm_metalfx_bench] FAIL: dm_metalfx_query_caps returned false\n");
        return 1;
    }

    printf("[dm_metalfx_bench] Spatial=%s Temporal=%s Metal4FX(S=%s,T=%s) Scale=[%.2f, %.2f]\n",
           caps.spatial_supported ? "yes" : "no",
           caps.temporal_supported ? "yes" : "no",
           caps.metal4fx_spatial ? "yes" : "no",
           caps.metal4fx_temporal ? "yes" : "no",
           caps.temporal_min_scale, caps.temporal_max_scale);

    if ((!caps.spatial_supported || !caps.temporal_supported) && ctest_skip_allowed()) {
        printf("[dm_metalfx_bench] SKIP: MetalFX Spatial/Temporal unsupported on paravirtualized GPU\n");
        return 77;
    }
    DM_CHECK(caps.spatial_supported && caps.temporal_supported);

    ensure_dir(out_dir);

    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        DM_CHECK(dev != nil);
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        DM_CHECK(queue != nil);

        run_gpu_metalfx_and_shim_edge_tests(dev, queue, caps);

        // Realistic pixel-shading heavy procedural scene + depth + zero-motion output
        NSString *msl = @R"(
#include <metal_stdlib>
using namespace metal;

struct SceneUniforms {
    float2 jitter_uv;
    float2 inv_res;
};

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

struct GOut {
    float4 color [[color(0)]];
    float2 motion [[color(1)]];
};

vertex VOut scene_vs(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-1.0f, -1.0f), float2(-1.0f, 3.0f), float2(3.0f, -1.0f) };
    VOut o;
    o.pos = float4(p[vid], 0.0f, 1.0f);
    o.uv = float2(p[vid].x * 0.5f + 0.5f, 0.5f - p[vid].y * 0.5f);
    return o;
}

fragment GOut scene_fs(VOut in [[stage_in]], constant SceneUniforms& u [[buffer(0)]]) {
    float2 uv = in.uv + u.jitter_uv;
    float2 p = (uv - 0.5f) * float2(16.0f / 9.0f, 1.0f) * 2.2f;

    // 48-iteration procedural lighting & procedural geometry detail (realistic shader ALU load)
    float3 col = float3(0.06f, 0.09f, 0.14f);
    float d_min = 10.0f;
    for (int i = 0; i < 48; ++i) {
        float fi = float(i) * 0.1309f;
        float2 c = float2(cos(fi * 2.0f), sin(fi * 3.0f)) * 0.55f;
        float d = length(p - c) - (0.14f + 0.06f * sin(fi * 5.0f));
        d_min = min(d_min, d);
        float w = exp(-abs(d) * 14.0f);
        float3 tint = 0.5f + 0.5f * cos(fi + float3(0.0f, 2.094f, 4.188f));
        col += tint * w * 0.08f;
    }
    float checker = 0.85f + 0.15f * sin(p.x * 24.0f) * sin(p.y * 24.0f);
    float ring = smoothstep(0.03f, 0.0f, abs(length(p) - 0.65f));
    col = saturate(col * checker + float3(0.9f, 0.8f, 0.3f) * ring * 0.5f);

    GOut o;
    o.color = float4(col, 1.0f);
    o.motion = float2(0.0f, 0.0f);
    return o;
}

kernel void fp16_to_rgba8(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 c = src.read(gid);
    dst.write(float4(saturate(c.rgb), 1.0f), gid);
}
)";
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:msl options:nil error:&err];
        DM_CHECK(lib != nil);

        id<MTLFunction> vs = [lib newFunctionWithName:@"scene_vs"];
        id<MTLFunction> fs = [lib newFunctionWithName:@"scene_fs"];
        id<MTLFunction> blit_fn = [lib newFunctionWithName:@"fp16_to_rgba8"];
        DM_CHECK(vs != nil && fs != nil && blit_fn != nil);
        id<MTLComputePipelineState> fp16_blit_pso = [dev newComputePipelineStateWithFunction:blit_fn error:&err];
        DM_CHECK(fp16_blit_pso != nil);

        auto build_scene_pso = [&](MTLPixelFormat col_fmt, bool with_motion) -> id<MTLRenderPipelineState> {
            MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
            DM_CHECK(rpd != nil);
            rpd.vertexFunction = vs;
            rpd.fragmentFunction = fs;
            rpd.colorAttachments[0].pixelFormat = col_fmt;
            if (with_motion) {
                rpd.colorAttachments[1].pixelFormat = MTLPixelFormatRG16Float;
                rpd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
            }
            NSError *pe = nil;
            id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:rpd error:&pe];
            DM_CHECK(pso != nil);
            return pso;
        };

        id<MTLRenderPipelineState> pso_rgba8 = build_scene_pso(MTLPixelFormatRGBA8Unorm, false);
        id<MTLRenderPipelineState> pso_fp16_mrt = build_scene_pso(MTLPixelFormatRGBA16Float, true);

        constexpr uint32_t kOutW = 1920, kOutH = 1080;
        uint32_t q_w = 0, q_h = 0, p_w = 0, p_h = 0;
        dm_metalfx_resolve_render_size(DM_UPSCALER_FSR, DM_UPSCALE_QUALITY, kOutW, kOutH, &q_w, &q_h);
        dm_metalfx_resolve_render_size(DM_UPSCALER_FSR, DM_UPSCALE_PERFORMANCE, kOutW, kOutH, &p_w, &p_h);
        DM_CHECK(q_w > 0 && q_h > 0 && p_w > 0 && p_h > 0);

        auto make_tex = [&](uint32_t w, uint32_t h, MTLPixelFormat fmt, MTLTextureUsage usage) -> id<MTLTexture> {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:w height:h mipmapped:NO];
            DM_CHECK(td != nil);
            td.usage = usage;
            td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> t = [dev newTextureWithDescriptor:td];
            DM_CHECK(t != nil);
            return t;
        };

        // 1. Native 1080p baseline (RGBA8 + FP16)
        id<MTLTexture> nat8_tex = make_tex(kOutW, kOutH, MTLPixelFormatRGBA8Unorm,
                                           MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        id<MTLTexture> nat16_tex = make_tex(kOutW, kOutH, MTLPixelFormatRGBA16Float,
                                            MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        id<MTLTexture> nat_mot = make_tex(kOutW, kOutH, MTLPixelFormatRG16Float, MTLTextureUsageRenderTarget);
        id<MTLTexture> nat_dep = make_tex(kOutW, kOutH, MTLPixelFormatDepth32Float, MTLTextureUsageRenderTarget);

        struct { float jx, jy, ix, iy; } uni{0, 0, 1.0f / kOutW, 1.0f / kOutH};

        constexpr int kWarmup = 5, kFrames = 60;
        auto bench_native = [&](bool fp16) -> double {
            double sum = 0.0;
            for (int f = 0; f < kWarmup + kFrames; ++f) {
                const double t0 = now_ms();
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                DM_CHECK(cb != nil);
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = fp16 ? nat16_tex : nat8_tex;
                rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                if (fp16) {
                    rp.colorAttachments[1].texture = nat_mot;
                    rp.colorAttachments[1].loadAction = MTLLoadActionDontCare;
                    rp.colorAttachments[1].storeAction = MTLStoreActionStore;
                    rp.depthAttachment.texture = nat_dep;
                    rp.depthAttachment.loadAction = MTLLoadActionClear;
                    rp.depthAttachment.storeAction = MTLStoreActionDontCare;
                    rp.depthAttachment.clearDepth = 0.5;
                }
                id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
                DM_CHECK(re != nil);
                [re setRenderPipelineState:(fp16 ? pso_fp16_mrt : pso_rgba8)];
                [re setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
                [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [re endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                DM_CHECK(cb.status == MTLCommandBufferStatusCompleted);
                const double t1 = now_ms();
                if (f >= kWarmup) sum += (t1 - t0);
            }
            return sum / kFrames;
        };

        const double native8_ms = bench_native(false);
        const double native16_ms = bench_native(true);
        save_private_tex_png(dev, queue, nat8_tex, fp16_blit_pso, out_dir + "/native_1080p.png");

        // 2. MetalFX Spatial Quality (1280x720 -> 1920x1080) & Performance (960x540 -> 1920x1080)
        auto run_spatial = [&](uint32_t iw, uint32_t ih, const std::string &png_name) -> double {
            dm_metalfx_spatial_t *sc = dm_metalfx_spatial_create(iw, ih, kOutW, kOutH, MTLPixelFormatRGBA8Unorm, false);
            DM_CHECK(sc != nullptr);
            id<MTLTexture> in_tex = make_tex(iw, ih, MTLPixelFormatRGBA8Unorm,
                                             MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
            id<MTLTexture> out_tex = make_tex(kOutW, kOutH, MTLPixelFormatRGBA8Unorm,
                                              MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
            struct { float jx, jy, ix, iy; } su{0, 0, 1.0f / iw, 1.0f / ih};

            double sum = 0.0;
            for (int f = 0; f < kWarmup + kFrames; ++f) {
                const double t0 = now_ms();
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                DM_CHECK(cb != nil);
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = in_tex;
                rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
                DM_CHECK(re != nil);
                [re setRenderPipelineState:pso_rgba8];
                [re setFragmentBytes:&su length:sizeof(su) atIndex:0];
                [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [re endEncoding];

                DM_CHECK(dm_metalfx_spatial_encode(sc, (__bridge void *)cb,
                                                   (__bridge void *)in_tex,
                                                   (__bridge void *)out_tex, iw, ih));
                [cb commit];
                [cb waitUntilCompleted];
                DM_CHECK(cb.status == MTLCommandBufferStatusCompleted);
                const double t1 = now_ms();
                if (f >= kWarmup) sum += (t1 - t0);
            }
            save_private_tex_png(dev, queue, out_tex, fp16_blit_pso, out_dir + "/" + png_name);
            dm_metalfx_spatial_destroy(sc);
            return sum / kFrames;
        };

        const double spatial_q_ms = run_spatial(q_w, q_h, "metalfx_spatial_quality.png");
        const double spatial_p_ms = run_spatial(p_w, p_h, "metalfx_spatial_perf.png");

        // 3. MetalFX Temporal Quality (1280x720 -> 1920x1080, Halton jittered accumulation)
        dm_metalfx_temporal_t *tc = dm_metalfx_temporal_create(
            q_w, q_h, kOutW, kOutH,
            MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float,
            MTLPixelFormatRG16Float, MTLPixelFormatRGBA16Float);
        DM_CHECK(tc != nullptr);
        id<MTLTexture> t_in = make_tex(q_w, q_h, MTLPixelFormatRGBA16Float,
                                       MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        id<MTLTexture> t_dep = make_tex(q_w, q_h, MTLPixelFormatDepth32Float,
                                        MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        id<MTLTexture> t_mot = make_tex(q_w, q_h, MTLPixelFormatRG16Float,
                                        MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        id<MTLTexture> t_out = make_tex(kOutW, kOutH, MTLPixelFormatRGBA16Float,
                                        MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);

        double temp_sum = 0.0;
        for (int f = 0; f < kWarmup + kFrames; ++f) {
            const float jx = halton((f % 8) + 1, 2) - 0.5f;
            const float jy = halton((f % 8) + 1, 3) - 0.5f;
            struct { float jx, jy, ix, iy; } tu{jx / (float)q_w, jy / (float)q_h, 1.0f / q_w, 1.0f / q_h};

            const double t0 = now_ms();
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            DM_CHECK(cb != nil);
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = t_in;
            rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[1].texture = t_mot;
            rp.colorAttachments[1].loadAction = MTLLoadActionDontCare;
            rp.colorAttachments[1].storeAction = MTLStoreActionStore;
            rp.depthAttachment.texture = t_dep;
            rp.depthAttachment.loadAction = MTLLoadActionClear;
            rp.depthAttachment.storeAction = MTLStoreActionStore;
            rp.depthAttachment.clearDepth = 0.5;
            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
            DM_CHECK(re != nil);
            [re setRenderPipelineState:pso_fp16_mrt];
            [re setFragmentBytes:&tu length:sizeof(tu) atIndex:0];
            [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [re endEncoding];

            DM_CHECK(dm_metalfx_temporal_encode(tc, (__bridge void *)cb,
                                                (__bridge void *)t_in,
                                                (__bridge void *)t_dep,
                                                (__bridge void *)t_mot,
                                                (__bridge void *)t_out,
                                                jx, jy, 1.0f, 1.0f, f == 0));
            [cb commit];
            [cb waitUntilCompleted];
            DM_CHECK(cb.status == MTLCommandBufferStatusCompleted);
            const double t1 = now_ms();
            if (f >= kWarmup) temp_sum += (t1 - t0);
        }
        const double temporal_q_ms = temp_sum / kFrames;
        save_private_tex_png(dev, queue, t_out, fp16_blit_pso, out_dir + "/metalfx_temporal_quality.png");
        dm_metalfx_temporal_destroy(tc);

        const double sq_speedup = spatial_q_ms > 0.0 ? (native8_ms / spatial_q_ms) : 0.0;
        const double sp_speedup = spatial_p_ms > 0.0 ? (native8_ms / spatial_p_ms) : 0.0;
        const double tq_speedup = temporal_q_ms > 0.0 ? (native16_ms / temporal_q_ms) : 0.0;
        const double nat8_fps = native8_ms > 0.0 ? (1000.0 / native8_ms) : 0.0;
        const double sq_fps = spatial_q_ms > 0.0 ? (1000.0 / spatial_q_ms) : 0.0;
        const double sp_fps = spatial_p_ms > 0.0 ? (1000.0 / spatial_p_ms) : 0.0;
        const double tq_fps = temporal_q_ms > 0.0 ? (1000.0 / temporal_q_ms) : 0.0;

        printf("[dm_metalfx_bench] Native 1080p (RGBA8): %.3f ms (%.1f FPS)\n", native8_ms, nat8_fps);
        printf("[dm_metalfx_bench] Spatial Quality (%ux%u->1080p): %.3f ms (%.1f FPS, %.2fx)\n",
               q_w, q_h, spatial_q_ms, sq_fps, sq_speedup);
        printf("[dm_metalfx_bench] Spatial Perf    (%ux%u->1080p): %.3f ms (%.1f FPS, %.2fx)\n",
               p_w, p_h, spatial_p_ms, sp_fps, sp_speedup);
        printf("[dm_metalfx_bench] Temporal Quality (%ux%u->1080p): %.3f ms (%.1f FPS, %.2fx vs 1080p FP16 %.3f ms)\n",
               q_w, q_h, temporal_q_ms, tq_fps, tq_speedup, native16_ms);

        if (json_path) {
            FILE *jf = fopen(json_path, "w");
            DM_CHECK(jf != nullptr);
            fprintf(jf,
                    "{\n"
                    "  \"spatial_supported\": %s,\n"
                    "  \"temporal_supported\": %s,\n"
                    "  \"metal4fx_spatial\": %s,\n"
                    "  \"metal4fx_temporal\": %s,\n"
                    "  \"native_1080p_ms\": %.4f,\n"
                    "  \"native_1080p_fps\": %.2f,\n"
                    "  \"native_1080p_fp16_ms\": %.4f,\n"
                    "  \"spatial_quality_ms\": %.4f,\n"
                    "  \"spatial_quality_fps\": %.2f,\n"
                    "  \"spatial_quality_speedup_x\": %.3f,\n"
                    "  \"spatial_perf_ms\": %.4f,\n"
                    "  \"spatial_perf_fps\": %.2f,\n"
                    "  \"spatial_perf_speedup_x\": %.3f,\n"
                    "  \"temporal_quality_ms\": %.4f,\n"
                    "  \"temporal_quality_fps\": %.2f,\n"
                    "  \"temporal_quality_speedup_x\": %.3f,\n"
                    "  \"png_dir\": \"%s\"\n"
                    "}\n",
                    caps.spatial_supported ? "true" : "false",
                    caps.temporal_supported ? "true" : "false",
                    caps.metal4fx_spatial ? "true" : "false",
                    caps.metal4fx_temporal ? "true" : "false",
                    native8_ms, nat8_fps, native16_ms,
                    spatial_q_ms, sq_fps, sq_speedup,
                    spatial_p_ms, sp_fps, sp_speedup,
                    temporal_q_ms, tq_fps, tq_speedup,
                    out_dir.c_str());
            fclose(jf);
        }
    }
    return 0;
}
