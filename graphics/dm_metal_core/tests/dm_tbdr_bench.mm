#include "dm_tbdr_optimizer.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <assert.h>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <time.h>
#include <vector>

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static void run_unit_tests(void) {
    // 1. 8 draw batches + clear + resolve -> 1 coalesced pass + Memoryless MSAA/depth
    dm_dx_attachment_desc_t atts[3] = {
        {0, 1920, 1080, 4, 4, false, false},  // MSAA color
        {1, 1920, 1080, 4, 4, true, false},   // MSAA depth
        {2, 1920, 1080, 1, 4, false, true},   // Resolved target (exported)
    };
    std::vector<dm_dx_pass_op_t> ops;
    ops.push_back({DM_DX_OP_CLEAR_RTV, 0, UINT32_MAX, 1, UINT32_MAX, 0});
    ops.push_back({DM_DX_OP_CLEAR_DSV, 0, UINT32_MAX, 1, UINT32_MAX, 0});
    for (int b = 0; b < 8; ++b) {
        ops.push_back({DM_DX_OP_DRAW_BATCH, 0, UINT32_MAX, 1, UINT32_MAX, 64});
    }
    ops.push_back({DM_DX_OP_RESOLVE_MSAA, 0, 2, 1, UINT32_MAX, 0});

    dm_tbdr_optimized_plan_t plan{};
    assert(dm_tbdr_optimize_passes(atts, 3, ops.data(), ops.size(), &plan));
    assert(plan.original_pass_count == 9);
    assert(plan.coalesced_pass_count == 1);
    assert(plan.passes[0].color_load == DM_TBDR_LOAD_CLEAR);
    assert(plan.passes[0].color_store == DM_TBDR_STORE_MULTISAMPLE_RESOLVE);
    assert(plan.passes[0].depth_load == DM_TBDR_LOAD_CLEAR);
    assert(plan.passes[0].depth_store == DM_TBDR_STORE_DONT_CARE);
    assert(plan.passes[0].total_draws == 512);
    assert(plan.attachments[0].promote_memoryless == true);
    assert(plan.attachments[1].promote_memoryless == true);
    assert(plan.attachments[2].promote_memoryless == false);

    // 2. Intervening SRV barrier must split pass into 2 and disable Memoryless for read target
    dm_dx_pass_op_t split_ops[4] = {
        {DM_DX_OP_CLEAR_RTV, 0, UINT32_MAX, 1, UINT32_MAX, 0},
        {DM_DX_OP_DRAW_BATCH, 0, UINT32_MAX, 1, UINT32_MAX, 32},
        {DM_DX_OP_READ_SRV_BARRIER, UINT32_MAX, UINT32_MAX, UINT32_MAX, 0, 0},
        {DM_DX_OP_DRAW_BATCH, 2, UINT32_MAX, UINT32_MAX, UINT32_MAX, 1},
    };
    dm_tbdr_optimized_plan_t split_plan{};
    assert(dm_tbdr_optimize_passes(atts, 3, split_ops, 4, &split_plan));
    assert(split_plan.coalesced_pass_count == 2);
    assert(split_plan.attachments[0].promote_memoryless == false);
    printf("[dm_tbdr_bench] Unit tests (pass coalescing, action inference, barrier split, memoryless) OK\n");
}

struct TriVertex {
    float x, y, z;
    float r, g, b, a;
};

int main(int argc, char **argv) {
    const char *json_path = nullptr;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--json") == 0 && i + 1 < argc) {
            json_path = argv[++i];
        }
    }

    run_unit_tests();

    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        assert(dev != nil);

        constexpr uint32_t kW = 1920, kH = 1080;
        constexpr int kBatches = 8, kTrisPerBatch = 64;
        constexpr int kWarmup = 10, kFrames = 200;

        NSString *msl = @R"(
#include <metal_stdlib>
using namespace metal;
struct VIn {
    float3 pos [[attribute(0)]];
    float4 col [[attribute(1)]];
};
struct VOut {
    float4 pos [[position]];
    float4 col;
};
vertex VOut tbdr_vs(VIn in [[stage_in]]) {
    VOut o;
    o.pos = float4(in.pos, 1.0f);
    o.col = in.col;
    return o;
}
fragment float4 tbdr_fs(VOut in [[stage_in]]) {
    return in.col;
}
)";
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:msl options:nil error:&err];
        assert(lib != nil);

        MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
        vd.attributes[0].format = MTLVertexFormatFloat3;
        vd.attributes[0].offset = 0;
        vd.attributes[0].bufferIndex = 0;
        vd.attributes[1].format = MTLVertexFormatFloat4;
        vd.attributes[1].offset = 12;
        vd.attributes[1].bufferIndex = 0;
        vd.layouts[0].stride = sizeof(TriVertex);

        MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
        rpd.vertexFunction = [lib newFunctionWithName:@"tbdr_vs"];
        rpd.fragmentFunction = [lib newFunctionWithName:@"tbdr_fs"];
        rpd.vertexDescriptor = vd;
        rpd.rasterSampleCount = 4;
        rpd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        rpd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        id<MTLRenderPipelineState> rps = [dev newRenderPipelineStateWithDescriptor:rpd error:&err];
        assert(rps != nil);

        MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
        dsd.depthCompareFunction = MTLCompareFunctionLess;
        dsd.depthWriteEnabled = YES;
        id<MTLDepthStencilState> dss = [dev newDepthStencilStateWithDescriptor:dsd];

        // Generate 8 batches x 64 overlapping triangles (512 tris)
        std::vector<TriVertex> verts;
        verts.reserve(kBatches * kTrisPerBatch * 3);
        for (int b = 0; b < kBatches; ++b) {
            for (int t = 0; t < kTrisPerBatch; ++t) {
                const int idx = b * kTrisPerBatch + t;
                const float cx = -0.85f + 1.70f * (float)(idx % 32) / 31.0f;
                const float cy = -0.85f + 1.70f * (float)(idx / 32) / 15.0f;
                const float z = 0.2f + 0.6f * (float)((idx * 7) % 19) / 18.0f;
                const float r = (float)(b + 1) / (float)kBatches;
                const float g = (float)(t % 16) / 15.0f;
                const float bl = 1.0f - 0.5f * r;
                verts.push_back({cx, cy + 0.14f, z, r, g, bl, 1.0f});
                verts.push_back({cx + 0.14f, cy - 0.12f, z + 0.02f, r * 0.8f, g, bl, 1.0f});
                verts.push_back({cx - 0.14f, cy - 0.12f, z - 0.02f, r, g * 0.8f, bl, 1.0f});
            }
        }
        id<MTLBuffer> vbuf = [dev newBufferWithBytes:verts.data()
                                              length:verts.size() * sizeof(TriVertex)
                                             options:MTLResourceStorageModeShared];

        // Resolved output targets (Shared so we can read back and verify bit-exact equivalence)
        MTLTextureDescriptor *res_td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                          width:kW height:kH mipmapped:NO];
        res_td.usage = MTLTextureUsageRenderTarget;
        res_td.storageMode = MTLStorageModeShared;
        id<MTLTexture> resolved_base = [dev newTextureWithDescriptor:res_td];
        id<MTLTexture> resolved_tbdr = [dev newTextureWithDescriptor:res_td];

        // --- Path A: Naive Uncoalesced Private MSAA+Depth (8 passes + load/store + resolve pass) ---
        MTLTextureDescriptor *msaa_td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                           width:kW height:kH mipmapped:NO];
        msaa_td.textureType = MTLTextureType2DMultisample;
        msaa_td.sampleCount = 4;
        msaa_td.usage = MTLTextureUsageRenderTarget;
        msaa_td.storageMode = MTLStorageModePrivate;

        MTLTextureDescriptor *depth_td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                            width:kW height:kH mipmapped:NO];
        depth_td.textureType = MTLTextureType2DMultisample;
        depth_td.sampleCount = 4;
        depth_td.usage = MTLTextureUsageRenderTarget;
        depth_td.storageMode = MTLStorageModePrivate;

        id<MTLTexture> priv_msaa = [dev newTextureWithDescriptor:msaa_td];
        id<MTLTexture> priv_depth = [dev newTextureWithDescriptor:depth_td];
        const uint64_t baseline_transient_bytes = priv_msaa.allocatedSize + priv_depth.allocatedSize;

        id<MTLCommandQueue> queue = [dev newCommandQueue];
        double baseline_sum_ms = 0.0;
        for (int f = 0; f < kWarmup + kFrames; ++f) {
            const double t0 = now_ms();
            id<MTLCommandBuffer> cb = [queue commandBuffer];

            // Pass 0: Clear
            MTLRenderPassDescriptor *clear_rp = [MTLRenderPassDescriptor renderPassDescriptor];
            clear_rp.colorAttachments[0].texture = priv_msaa;
            clear_rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            clear_rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            clear_rp.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.07, 0.11, 1.0);
            clear_rp.depthAttachment.texture = priv_depth;
            clear_rp.depthAttachment.loadAction = MTLLoadActionClear;
            clear_rp.depthAttachment.storeAction = MTLStoreActionStore;
            clear_rp.depthAttachment.clearDepth = 1.0;
            [[cb renderCommandEncoderWithDescriptor:clear_rp] endEncoding];

            // Passes 1..8: Separate render passes with Load+Store (DRAM round-trips)
            for (int b = 0; b < kBatches; ++b) {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = priv_msaa;
                rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                rp.depthAttachment.texture = priv_depth;
                rp.depthAttachment.loadAction = MTLLoadActionLoad;
                rp.depthAttachment.storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
                [re setRenderPipelineState:rps];
                [re setDepthStencilState:dss];
                [re setVertexBuffer:vbuf offset:0 atIndex:0];
                [re drawPrimitives:MTLPrimitiveTypeTriangle
                       vertexStart:(NSUInteger)(b * kTrisPerBatch * 3)
                       vertexCount:(NSUInteger)(kTrisPerBatch * 3)];
                [re endEncoding];
            }

            // Pass 9: Resolve
            MTLRenderPassDescriptor *res_rp = [MTLRenderPassDescriptor renderPassDescriptor];
            res_rp.colorAttachments[0].texture = priv_msaa;
            res_rp.colorAttachments[0].resolveTexture = resolved_base;
            res_rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
            res_rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
            [[cb renderCommandEncoderWithDescriptor:res_rp] endEncoding];

            [cb commit];
            [cb waitUntilCompleted];
            const double t1 = now_ms();
            if (f >= kWarmup) baseline_sum_ms += (t1 - t0);
        }
        priv_msaa = nil;
        priv_depth = nil;

        // --- Path B: DirectMetal TBDR Coalesced + MTLStorageModeMemoryless ---
        msaa_td.storageMode = MTLStorageModeMemoryless;
        depth_td.storageMode = MTLStorageModeMemoryless;
        id<MTLTexture> memless_msaa = [dev newTextureWithDescriptor:msaa_td];
        id<MTLTexture> memless_depth = [dev newTextureWithDescriptor:depth_td];
        assert(memless_msaa != nil && memless_depth != nil);
        const uint64_t opt_transient_bytes = memless_msaa.allocatedSize + memless_depth.allocatedSize;

        double opt_sum_ms = 0.0;
        for (int f = 0; f < kWarmup + kFrames; ++f) {
            const double t0 = now_ms();
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = memless_msaa;
            rp.colorAttachments[0].resolveTexture = resolved_tbdr;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.07, 0.11, 1.0);
            rp.depthAttachment.texture = memless_depth;
            rp.depthAttachment.loadAction = MTLLoadActionClear;
            rp.depthAttachment.storeAction = MTLStoreActionDontCare;
            rp.depthAttachment.clearDepth = 1.0;

            id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
            [re setRenderPipelineState:rps];
            [re setDepthStencilState:dss];
            [re setVertexBuffer:vbuf offset:0 atIndex:0];
            for (int b = 0; b < kBatches; ++b) {
                [re drawPrimitives:MTLPrimitiveTypeTriangle
                       vertexStart:(NSUInteger)(b * kTrisPerBatch * 3)
                       vertexCount:(NSUInteger)(kTrisPerBatch * 3)];
            }
            [re endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            const double t1 = now_ms();
            if (f >= kWarmup) opt_sum_ms += (t1 - t0);
        }

        // Verify resolved 1080p images match pixel-for-pixel
        std::vector<uint8_t> px_a((size_t)kW * kH * 4u), px_b((size_t)kW * kH * 4u);
        [resolved_base getBytes:px_a.data() bytesPerRow:kW * 4u fromRegion:MTLRegionMake2D(0, 0, kW, kH) mipmapLevel:0];
        [resolved_tbdr getBytes:px_b.data() bytesPerRow:kW * 4u fromRegion:MTLRegionMake2D(0, 0, kW, kH) mipmapLevel:0];
        int max_diff = 0;
        for (size_t i = 0; i < px_a.size(); ++i) {
            const int d = std::abs((int)px_a[i] - (int)px_b[i]);
            if (d > max_diff) max_diff = d;
        }
        assert(max_diff == 0);

        const double base_ms = baseline_sum_ms / kFrames;
        const double opt_ms = opt_sum_ms / kFrames;
        const double speedup = base_ms / opt_ms;
        const double base_mb = (double)baseline_transient_bytes / (1024.0 * 1024.0);
        const double opt_mb = (double)opt_transient_bytes / (1024.0 * 1024.0);

        printf("[dm_tbdr_bench] 1080p 4x MSAA + D32_FLOAT pixel-exact match (max_diff=%d)\n", max_diff);
        printf("[dm_tbdr_bench] Uncoalesced Private (9 passes): %.3f ms/frame | Transient DRAM=%.2f MiB\n",
               base_ms, base_mb);
        printf("[dm_tbdr_bench] Coalesced Memoryless (1 pass) : %.3f ms/frame | Transient DRAM=%.2f MiB\n",
               opt_ms, opt_mb);
        printf("[dm_tbdr_bench] Speedup: %.2fx | Transient DRAM Saved: %.2f MiB (100%%)\n",
               speedup, base_mb - opt_mb);

        if (json_path) {
            FILE *jf = fopen(json_path, "w");
            assert(jf != nullptr);
            fprintf(jf,
                    "{\n"
                    "  \"pixel_exact\": true,\n"
                    "  \"max_diff\": %d,\n"
                    "  \"resolution\": \"1920x1080 4xMSAA\",\n"
                    "  \"passes_original\": 9,\n"
                    "  \"passes_coalesced\": 1,\n"
                    "  \"baseline_mean_ms\": %.4f,\n"
                    "  \"optimized_mean_ms\": %.4f,\n"
                    "  \"speedup_x\": %.3f,\n"
                    "  \"baseline_transient_mib\": %.3f,\n"
                    "  \"optimized_transient_mib\": %.3f,\n"
                    "  \"dram_saved_mib\": %.3f\n"
                    "}\n",
                    max_diff, base_ms, opt_ms, speedup, base_mb, opt_mb, base_mb - opt_mb);
            fclose(jf);
        }
    }
    return 0;
}
