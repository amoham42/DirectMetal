#include "dm_uma_allocator.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <assert.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <time.h>
#include <vector>

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static constexpr uint32_t kInCount = 1024u * 1024u;   // 4 MiB
static constexpr uint32_t kOutCount = 256u * 1024u;   // 1 MiB
static constexpr int kWarmup = 10;
static constexpr int kFrames = 300;

int main(int argc, char **argv) {
    const char *json_path = nullptr;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--json") == 0 && i + 1 < argc) {
            json_path = argv[++i];
        }
    }

    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        assert(dev != nil && dev.hasUnifiedMemory);

        NSString *msl = @R"(
#include <metal_stdlib>
using namespace metal;
kernel void reduce4(device const uint* in_buf [[buffer(0)]],
                    device uint* out_buf [[buffer(1)]],
                    uint gid [[thread_position_in_grid]]) {
    uint base = gid * 4u;
    uint v = in_buf[base] * 3u + in_buf[base + 1u] * 5u + in_buf[base + 2u] ^ in_buf[base + 3u];
    out_buf[gid] = v + 17u;
}
)";
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:msl options:nil error:&err];
        assert(lib != nil);
        id<MTLFunction> fn = [lib newFunctionWithName:@"reduce4"];
        id<MTLComputePipelineState> cps = [dev newComputePipelineStateWithFunction:fn error:&err];
        assert(cps != nil);
        id<MTLCommandQueue> queue = [dev newCommandQueue];

        const size_t in_bytes = kInCount * sizeof(uint32_t);
        const size_t out_bytes = kOutCount * sizeof(uint32_t);

        // --- Path A: Discrete GPU Double-Copy Staging Emulation ---
        std::vector<uint32_t> cpu_src(kInCount);
        std::vector<uint32_t> cpu_dst_discrete(kOutCount);
        const uint64_t gpu_alloc_before_discrete = dev.currentAllocatedSize;
        id<MTLBuffer> stage_in = [dev newBufferWithLength:in_bytes options:MTLResourceStorageModeShared];
        id<MTLBuffer> priv_in = [dev newBufferWithLength:in_bytes options:MTLResourceStorageModePrivate];
        id<MTLBuffer> priv_out = [dev newBufferWithLength:out_bytes options:MTLResourceStorageModePrivate];
        id<MTLBuffer> stage_out = [dev newBufferWithLength:out_bytes options:MTLResourceStorageModeShared];
        const uint64_t gpu_alloc_discrete = dev.currentAllocatedSize - gpu_alloc_before_discrete;
        const size_t total_footprint_discrete = gpu_alloc_discrete + in_bytes + out_bytes;

        double discrete_sum_ms = 0.0;
        uint64_t discrete_checksum = 0;
        for (int f = 0; f < kWarmup + kFrames; ++f) {
            for (uint32_t i = 0; i < kInCount; ++i) {
                cpu_src[i] = (i * 131u) ^ (uint32_t)f;
            }
            const double t0 = now_ms();
            std::memcpy(stage_in.contents, cpu_src.data(), in_bytes);

            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLBlitCommandEncoder> b1 = [cb blitCommandEncoder];
            [b1 copyFromBuffer:stage_in sourceOffset:0 toBuffer:priv_in destinationOffset:0 size:in_bytes];
            [b1 endEncoding];

            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:cps];
            [ce setBuffer:priv_in offset:0 atIndex:0];
            [ce setBuffer:priv_out offset:0 atIndex:1];
            [ce dispatchThreads:MTLSizeMake(kOutCount, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [ce endEncoding];

            id<MTLBlitCommandEncoder> b2 = [cb blitCommandEncoder];
            [b2 copyFromBuffer:priv_out sourceOffset:0 toBuffer:stage_out destinationOffset:0 size:out_bytes];
            [b2 endEncoding];

            [cb commit];
            [cb waitUntilCompleted];
            std::memcpy(cpu_dst_discrete.data(), stage_out.contents, out_bytes);
            const double t1 = now_ms();
            if (f >= kWarmup) discrete_sum_ms += (t1 - t0);
            if (f == kWarmup + kFrames - 1) {
                for (uint32_t i = 0; i < kOutCount; ++i) discrete_checksum += cpu_dst_discrete[i];
            }
        }
        stage_in = nil; priv_in = nil; priv_out = nil; stage_out = nil;

        // --- Path B: DirectMetal UMA Zero-Copy (newBufferWithBytesNoCopy Shared Ring) ---
        const uint64_t gpu_alloc_before_uma = dev.currentAllocatedSize;
        dm_uma_ring_t *ring = dm_uma_ring_create(in_bytes + out_bytes + 65536u, DM_UMA_HEAP_UPLOAD);
        assert(ring != nullptr);
        const uint64_t gpu_alloc_uma = dev.currentAllocatedSize - gpu_alloc_before_uma;
        const size_t total_footprint_uma = gpu_alloc_uma;  // Zero separate CPU heap or private copy!

        // Also test MTLHeap pool reuse
        dm_uma_pool_t *pool = dm_uma_pool_create(2u * 1024u * 1024u, DM_UMA_HEAP_DYNAMIC_CB);
        assert(pool != nullptr);
        void *pool_cpu = nullptr;
        void *b_a = dm_uma_pool_acquire_buffer(pool, 65536, &pool_cpu);
        assert(b_a != nullptr && pool_cpu != nullptr);
        dm_uma_pool_recycle_buffer(pool, b_a);
        void *b_b = dm_uma_pool_acquire_buffer(pool, 65536, &pool_cpu);
        assert(b_b == b_a);
        assert(dm_uma_pool_telemetry(pool).reuse_hits == 1);
        dm_uma_pool_recycle_buffer(pool, b_b);
        dm_uma_pool_destroy(pool);

        double uma_sum_ms = 0.0;
        uint64_t uma_checksum = 0;
        std::vector<uint32_t> last_uma_out(kOutCount);
        for (int f = 0; f < kWarmup + kFrames; ++f) {
            dm_uma_ring_reset(ring);
            dm_uma_slice_t in_slice{}, out_slice{};
            assert(dm_uma_ring_alloc(ring, in_bytes, 256, &in_slice));
            assert(dm_uma_ring_alloc(ring, out_bytes, 256, &out_slice));
            uint32_t *in_ptr = static_cast<uint32_t *>(in_slice.cpu_ptr);
            const uint32_t *out_ptr = static_cast<const uint32_t *>(out_slice.cpu_ptr);

            const double t0 = now_ms();
            for (uint32_t i = 0; i < kInCount; ++i) {
                in_ptr[i] = (i * 131u) ^ (uint32_t)f;
            }
            id<MTLBuffer> mtl_buf = (__bridge id<MTLBuffer>)in_slice.metal_buffer_bridge;
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            [ce setComputePipelineState:cps];
            [ce setBuffer:mtl_buf offset:in_slice.offset atIndex:0];
            [ce setBuffer:mtl_buf offset:out_slice.offset atIndex:1];
            [ce dispatchThreads:MTLSizeMake(kOutCount, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [ce endEncoding];
            [cb commit];
            [cb waitUntilCompleted];

            uint64_t frame_sum = 0;
            for (uint32_t i = 0; i < kOutCount; ++i) {
                frame_sum += out_ptr[i];
                if (f == kWarmup + kFrames - 1) last_uma_out[i] = out_ptr[i];
            }
            const double t1 = now_ms();
            if (f >= kWarmup) uma_sum_ms += (t1 - t0);
            if (f == kWarmup + kFrames - 1) uma_checksum = frame_sum;
        }
        dm_uma_ring_destroy(ring);

        assert(uma_checksum == discrete_checksum);
        assert(std::memcmp(last_uma_out.data(), cpu_dst_discrete.data(), out_bytes) == 0);

        const double discrete_mean = discrete_sum_ms / kFrames;
        const double uma_mean = uma_sum_ms / kFrames;
        const double speedup = discrete_mean / uma_mean;
        const double payload_gb = (double)(in_bytes + out_bytes) / (1024.0 * 1024.0 * 1024.0);
        const double discrete_gbps = payload_gb / (discrete_mean / 1000.0);
        const double uma_gbps = payload_gb / (uma_mean / 1000.0);
        const double mem_reduction_pct = 100.0 * (1.0 - (double)total_footprint_uma / (double)total_footprint_discrete);

        printf("[dm_uma_bench] Bit-exact verification PASSED (checksum=0x%llx)\n", uma_checksum);
        printf("[dm_uma_bench] Discrete Staging (2x copy+blit): %.3f ms/frame (%.2f GB/s, footprint=%.2f MiB)\n",
               discrete_mean, discrete_gbps, (double)total_footprint_discrete / (1024.0 * 1024.0));
        printf("[dm_uma_bench] DirectMetal UMA Zero-Copy     : %.3f ms/frame (%.2f GB/s, footprint=%.2f MiB)\n",
               uma_mean, uma_gbps, (double)total_footprint_uma / (1024.0 * 1024.0));
        printf("[dm_uma_bench] Speedup: %.2fx | Footprint Reduction: %.1f%%\n",
               speedup, mem_reduction_pct);

        if (json_path) {
            FILE *jf = fopen(json_path, "w");
            assert(jf != nullptr);
            fprintf(jf,
                    "{\n"
                    "  \"bit_exact\": true,\n"
                    "  \"frames\": %d,\n"
                    "  \"payload_mib\": 5.0,\n"
                    "  \"discrete_mean_ms\": %.4f,\n"
                    "  \"uma_mean_ms\": %.4f,\n"
                    "  \"speedup_x\": %.3f,\n"
                    "  \"discrete_gbps\": %.3f,\n"
                    "  \"uma_gbps\": %.3f,\n"
                    "  \"discrete_footprint_mib\": %.3f,\n"
                    "  \"uma_footprint_mib\": %.3f,\n"
                    "  \"memory_reduction_pct\": %.2f\n"
                    "}\n",
                    kFrames, discrete_mean, uma_mean, speedup,
                    discrete_gbps, uma_gbps,
                    (double)total_footprint_discrete / (1024.0 * 1024.0),
                    (double)total_footprint_uma / (1024.0 * 1024.0),
                    mem_reduction_pct);
            fclose(jf);
        }
    }
    return 0;
}
