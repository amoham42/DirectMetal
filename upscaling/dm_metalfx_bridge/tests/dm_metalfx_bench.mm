#include "dm_metalfx_bridge.h"
#include "dm_png_writer.hpp"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include <assert.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <time.h>
#include <vector>

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
    const NSUInteger w = tex.width, h = tex.height;
    id<MTLTexture> rgba8_tex = tex;

    id<MTLCommandBuffer> cb = [queue commandBuffer];
    if (tex.pixelFormat == MTLPixelFormatRGBA16Float) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                      width:w height:h mipmapped:NO];
        td.usage = MTLTextureUsageShaderWrite;
        td.storageMode = MTLStorageModePrivate;
        rgba8_tex = [dev newTextureWithDescriptor:td];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:fp16_blit_pso];
        [ce setTexture:tex atIndex:0];
        [ce setTexture:rgba8_tex atIndex:1];
        [ce dispatchThreads:MTLSizeMake(w, h, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [ce endEncoding];
    }

    const NSUInteger row_pitch = w * 4u;
    const NSUInteger total_bytes = row_pitch * h;
    id<MTLBuffer> rb = [dev newBufferWithLength:total_bytes options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
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

    dm::write_png_rgba8(path, (uint32_t)w, (uint32_t)h,
                        static_cast<const uint8_t *>(rb.contents), (uint32_t)row_pitch);
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
    ensure_dir(out_dir);

    dm_metalfx_caps_t caps{};
    assert(dm_metalfx_query_caps(&caps));
    printf("[dm_metalfx_bench] Spatial=%s Temporal=%s Metal4FX(S=%s,T=%s) Scale=[%.2f, %.2f]\n",
           caps.spatial_supported ? "yes" : "no",
           caps.temporal_supported ? "yes" : "no",
           caps.metal4fx_spatial ? "yes" : "no",
           caps.metal4fx_temporal ? "yes" : "no",
           caps.temporal_min_scale, caps.temporal_max_scale);
    assert(caps.spatial_supported && caps.temporal_supported);

    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [dev newCommandQueue];

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
        assert(lib != nil);

        id<MTLFunction> vs = [lib newFunctionWithName:@"scene_vs"];
        id<MTLFunction> fs = [lib newFunctionWithName:@"scene_fs"];
        id<MTLFunction> blit_fn = [lib newFunctionWithName:@"fp16_to_rgba8"];
        id<MTLComputePipelineState> fp16_blit_pso = [dev newComputePipelineStateWithFunction:blit_fn error:&err];
        assert(fp16_blit_pso != nil);

        auto build_scene_pso = [&](MTLPixelFormat col_fmt, bool with_motion) -> id<MTLRenderPipelineState> {
            MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
            rpd.vertexFunction = vs;
            rpd.fragmentFunction = fs;
            rpd.colorAttachments[0].pixelFormat = col_fmt;
            if (with_motion) {
                rpd.colorAttachments[1].pixelFormat = MTLPixelFormatRG16Float;
                rpd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
            }
            NSError *pe = nil;
            id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:rpd error:&pe];
            assert(pso != nil);
            return pso;
        };

        id<MTLRenderPipelineState> pso_rgba8 = build_scene_pso(MTLPixelFormatRGBA8Unorm, false);
        id<MTLRenderPipelineState> pso_fp16_mrt = build_scene_pso(MTLPixelFormatRGBA16Float, true);

        constexpr uint32_t kOutW = 1920, kOutH = 1080;
        uint32_t q_w = 0, q_h = 0, p_w = 0, p_h = 0;
        dm_metalfx_resolve_render_size(DM_UPSCALER_FSR, DM_UPSCALE_QUALITY, kOutW, kOutH, &q_w, &q_h);
        dm_metalfx_resolve_render_size(DM_UPSCALER_FSR, DM_UPSCALE_PERFORMANCE, kOutW, kOutH, &p_w, &p_h);

        auto make_tex = [&](uint32_t w, uint32_t h, MTLPixelFormat fmt, MTLTextureUsage usage) -> id<MTLTexture> {
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt width:w height:h mipmapped:NO];
            td.usage = usage;
            td.storageMode = MTLStorageModePrivate;
            return [dev newTextureWithDescriptor:td];
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
                [re setRenderPipelineState:(fp16 ? pso_fp16_mrt : pso_rgba8)];
                [re setFragmentBytes:&uni length:sizeof(uni) atIndex:0];
                [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [re endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
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
            assert(sc != nullptr);
            id<MTLTexture> in_tex = make_tex(iw, ih, MTLPixelFormatRGBA8Unorm,
                                             MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
            id<MTLTexture> out_tex = make_tex(kOutW, kOutH, MTLPixelFormatRGBA8Unorm,
                                              MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
            struct { float jx, jy, ix, iy; } su{0, 0, 1.0f / iw, 1.0f / ih};

            double sum = 0.0;
            for (int f = 0; f < kWarmup + kFrames; ++f) {
                const double t0 = now_ms();
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = in_tex;
                rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
                [re setRenderPipelineState:pso_rgba8];
                [re setFragmentBytes:&su length:sizeof(su) atIndex:0];
                [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                [re endEncoding];

                assert(dm_metalfx_spatial_encode(sc, (__bridge void *)cb,
                                                 (__bridge void *)in_tex,
                                                 (__bridge void *)out_tex, iw, ih));
                [cb commit];
                [cb waitUntilCompleted];
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
        assert(tc != nullptr);
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
            [re setRenderPipelineState:pso_fp16_mrt];
            [re setFragmentBytes:&tu length:sizeof(tu) atIndex:0];
            [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [re endEncoding];

            assert(dm_metalfx_temporal_encode(tc, (__bridge void *)cb,
                                              (__bridge void *)t_in,
                                              (__bridge void *)t_dep,
                                              (__bridge void *)t_mot,
                                              (__bridge void *)t_out,
                                              jx, jy, 1.0f, 1.0f, f == 0));
            [cb commit];
            [cb waitUntilCompleted];
            const double t1 = now_ms();
            if (f >= kWarmup) temp_sum += (t1 - t0);
        }
        const double temporal_q_ms = temp_sum / kFrames;
        save_private_tex_png(dev, queue, t_out, fp16_blit_pso, out_dir + "/metalfx_temporal_quality.png");
        dm_metalfx_temporal_destroy(tc);

        const double sq_speedup = native8_ms / spatial_q_ms;
        const double sp_speedup = native8_ms / spatial_p_ms;
        const double tq_speedup = native16_ms / temporal_q_ms;

        printf("[dm_metalfx_bench] Native 1080p (RGBA8): %.3f ms (%.1f FPS)\n", native8_ms, 1000.0 / native8_ms);
        printf("[dm_metalfx_bench] Spatial Quality (%ux%u->1080p): %.3f ms (%.1f FPS, %.2fx)\n",
               q_w, q_h, spatial_q_ms, 1000.0 / spatial_q_ms, sq_speedup);
        printf("[dm_metalfx_bench] Spatial Perf    (%ux%u->1080p): %.3f ms (%.1f FPS, %.2fx)\n",
               p_w, p_h, spatial_p_ms, 1000.0 / spatial_p_ms, sp_speedup);
        printf("[dm_metalfx_bench] Temporal Quality (%ux%u->1080p): %.3f ms (%.1f FPS, %.2fx vs 1080p FP16 %.3f ms)\n",
               q_w, q_h, temporal_q_ms, 1000.0 / temporal_q_ms, tq_speedup, native16_ms);

        if (json_path) {
            FILE *jf = fopen(json_path, "w");
            assert(jf != nullptr);
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
                    native8_ms, 1000.0 / native8_ms, native16_ms,
                    spatial_q_ms, 1000.0 / spatial_q_ms, sq_speedup,
                    spatial_p_ms, 1000.0 / spatial_p_ms, sp_speedup,
                    temporal_q_ms, 1000.0 / temporal_q_ms, tq_speedup,
                    out_dir.c_str());
            fclose(jf);
        }
    }
    return 0;
}
