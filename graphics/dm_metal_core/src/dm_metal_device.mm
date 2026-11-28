#include "dm_metal_core.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <ctype.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysctl.h>

static void query_macos_build(char *buf, size_t cap) {
    size_t sz = cap;
    if (sysctlbyname("kern.osversion", buf, &sz, NULL, 0) != 0 || sz == 0) {
        snprintf(buf, cap, "unknown");
    } else {
        buf[cap - 1] = '\0';
    }
}

bool dm_metal_query_device(dm_metal_device_info_t *out) {
    if (!out) return false;
    memset(out, 0, sizeof(*out));

    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) return false;

        snprintf(out->gpu_name, sizeof(out->gpu_name), "%s", dev.name.UTF8String);
        out->registry_id = dev.registryID;
        out->has_unified_memory = dev.hasUnifiedMemory;
        out->recommended_working_set_bytes = dev.recommendedMaxWorkingSetSize;
        out->max_buffer_length = dev.maxBufferLength;
        out->supports_raytracing = dev.supportsRaytracing;
        out->supports_barycentrics = dev.supportsShaderBarycentricCoordinates;

        // Raw enum values keep Xcode 16 (macOS 15 SDK) builds working while detecting Apple10/Metal4 at runtime on macOS 26+.
        static constexpr MTLGPUFamily kDMGPUFamilyApple10 = static_cast<MTLGPUFamily>(1010);
        static constexpr MTLGPUFamily kDMGPUFamilyMetal4 = static_cast<MTLGPUFamily>(5002);

        const char *family = "Mac2";
        if ([dev supportsFamily:kDMGPUFamilyApple10]) {
            family = "Apple10";
        } else if ([dev supportsFamily:MTLGPUFamilyApple9]) {
            family = "Apple9";
        } else if ([dev supportsFamily:MTLGPUFamilyApple8]) {
            family = "Apple8";
        } else if ([dev supportsFamily:MTLGPUFamilyApple7]) {
            family = "Apple7";
        }
        snprintf(out->gpu_family, sizeof(out->gpu_family), "%s", family);

        out->supports_metal3 = [dev supportsFamily:MTLGPUFamilyMetal3];
        if (@available(macOS 26.0, *)) {
            out->supports_metal4 = [dev supportsFamily:kDMGPUFamilyMetal4];
        } else {
            out->supports_metal4 = false;
        }

        NSOperatingSystemVersion os_ver = [NSProcessInfo processInfo].operatingSystemVersion;
        snprintf(out->macos_version, sizeof(out->macos_version), "%ld.%ld.%ld",
                 (long)os_ver.majorVersion, (long)os_ver.minorVersion, (long)os_ver.patchVersion);
        query_macos_build(out->macos_build, sizeof(out->macos_build));

        char fam_lower[64];
        snprintf(fam_lower, sizeof(fam_lower), "%s", out->gpu_family);
        for (size_t i = 0; fam_lower[i]; ++i) {
            fam_lower[i] = (char)tolower((unsigned char)fam_lower[i]);
        }
        snprintf(out->cache_key, sizeof(out->cache_key), "%s_%s", fam_lower, out->macos_build);
        return true;
    }
}

bool dm_metal_run_smoke_test(char *error_buf, size_t error_cap) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            if (error_buf) snprintf(error_buf, error_cap, "MTLCreateSystemDefaultDevice returned nil");
            return false;
        }

        NSString *msl = @R"(
#include <metal_stdlib>
using namespace metal;

kernel void dm_compute_fill(texture2d<float, access::write> tex [[texture(0)]],
                            device uint* buf [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= 64 || gid.y >= 64) return;
    tex.write(float4(float(gid.x) / 63.0f, float(gid.y) / 63.0f, 0.5f, 1.0f), gid);
    buf[gid.y * 64 + gid.x] = (gid.x * 31u) ^ (gid.y * 17u);
}

struct VOut {
    float4 pos [[position]];
    float4 col;
};

vertex VOut dm_vs(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(0.0f, 0.7f), float2(0.7f, -0.7f), float2(-0.7f, -0.7f) };
    float4 c[3] = { float4(1, 0, 0, 1), float4(0, 1, 0, 1), float4(0, 0, 1, 1) };
    VOut o;
    o.pos = float4(p[vid], 0.0f, 1.0f);
    o.col = c[vid];
    return o;
}

fragment float4 dm_fs(VOut in [[stage_in]]) {
    return in.col;
}
)";

        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:msl options:nil error:&err];
        if (!lib) {
            if (error_buf) snprintf(error_buf, error_cap, "Shader compile failed: %s",
                                    err.localizedDescription.UTF8String);
            return false;
        }

        id<MTLFunction> cs_fn = [lib newFunctionWithName:@"dm_compute_fill"];
        id<MTLFunction> vs_fn = [lib newFunctionWithName:@"dm_vs"];
        id<MTLFunction> fs_fn = [lib newFunctionWithName:@"dm_fs"];

        id<MTLComputePipelineState> cps = [dev newComputePipelineStateWithFunction:cs_fn error:&err];
        if (!cps) {
            if (error_buf) snprintf(error_buf, error_cap, "Compute PSO failed: %s",
                                    err.localizedDescription.UTF8String);
            return false;
        }

        MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
        rpd.vertexFunction = vs_fn;
        rpd.fragmentFunction = fs_fn;
        rpd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> rps = [dev newRenderPipelineStateWithDescriptor:rpd error:&err];
        if (!rps) {
            if (error_buf) snprintf(error_buf, error_cap, "Render PSO failed: %s",
                                    err.localizedDescription.UTF8String);
            return false;
        }

        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                      width:64
                                                                                     height:64
                                                                                  mipmapped:NO];
        td.usage = MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> cs_tex = [dev newTextureWithDescriptor:td];
        id<MTLTexture> rt_tex = [dev newTextureWithDescriptor:td];

        id<MTLBuffer> uma_buf = [dev newBufferWithLength:64 * 64 * sizeof(uint32_t)
                                                 options:MTLResourceStorageModeShared];

        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];

        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        [ce setComputePipelineState:cps];
        [ce setTexture:cs_tex atIndex:0];
        [ce setBuffer:uma_buf offset:0 atIndex:0];
        [ce dispatchThreads:MTLSizeMake(64, 64, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [ce endEncoding];

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = rt_tex;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.1, 0.15, 1.0);
        id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:pass];
        [re setRenderPipelineState:rps];
        [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [re endEncoding];

        [cb commit];
        [cb waitUntilCompleted];
        if (cb.status != MTLCommandBufferStatusCompleted) {
            if (error_buf) snprintf(error_buf, error_cap, "Command buffer failed");
            return false;
        }

        const uint32_t *ptr = (const uint32_t *)uma_buf.contents;
        for (uint32_t y = 0; y < 64; ++y) {
            for (uint32_t x = 0; x < 64; ++x) {
                uint32_t expected = (x * 31u) ^ (y * 17u);
                if (ptr[y * 64 + x] != expected) {
                    if (error_buf) snprintf(error_buf, error_cap, "UMA compute mismatch at (%u,%u)", x, y);
                    return false;
                }
            }
        }

        uint8_t center[4] = {0};
        [rt_tex getBytes:center bytesPerRow:64 * 4 fromRegion:MTLRegionMake2D(32, 32, 1, 1) mipmapLevel:0];
        if (center[0] < 40 || center[1] < 40 || center[2] < 40) {
            if (error_buf) snprintf(error_buf, error_cap, "Render triangle center pixel invalid: %u,%u,%u",
                                    center[0], center[1], center[2]);
            return false;
        }
        return true;
    }
}
