#include "dm_uma_allocator.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <time.h>
#include <vector>

#define DM_CHECK(expr)                                                                 \
    do {                                                                               \
        if (!(expr)) {                                                                 \
            fprintf(stderr, "[dm_uma_bench] CHECK FAILED (%s:%d): %s\n",               \
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

static void run_device_independent_uma_tests(void) {
    // Zero-size and integer-overflow creation guards (no GPU required)
    DM_CHECK(dm_uma_ring_create(0, DM_UMA_HEAP_UPLOAD) == nullptr);
    DM_CHECK(dm_uma_ring_create(0, DM_UMA_HEAP_READBACK) == nullptr);
    DM_CHECK(dm_uma_ring_create(0, DM_UMA_HEAP_DYNAMIC_CB) == nullptr);
    DM_CHECK(dm_uma_ring_create(0, DM_UMA_HEAP_DEFAULT_SHARED) == nullptr);
    DM_CHECK(dm_uma_ring_create(SIZE_MAX, DM_UMA_HEAP_UPLOAD) == nullptr);

    DM_CHECK(dm_uma_pool_create(0, DM_UMA_HEAP_UPLOAD) == nullptr);
    DM_CHECK(dm_uma_pool_create(0, DM_UMA_HEAP_READBACK) == nullptr);
    DM_CHECK(dm_uma_pool_create(0, DM_UMA_HEAP_DYNAMIC_CB) == nullptr);
    DM_CHECK(dm_uma_pool_create(0, DM_UMA_HEAP_DEFAULT_SHARED) == nullptr);
    DM_CHECK(dm_uma_pool_create(SIZE_MAX, DM_UMA_HEAP_DYNAMIC_CB) == nullptr);

    // NULL ring lifecycle, buffer & telemetry guards
    dm_uma_ring_destroy(nullptr);
    dm_uma_ring_reset(nullptr);
    DM_CHECK(dm_uma_ring_metal_buffer(nullptr) == nullptr);
    const dm_uma_telemetry_t null_rt = dm_uma_ring_telemetry(nullptr);
    DM_CHECK(null_rt.bytes_allocated == 0);
    DM_CHECK(null_rt.bytes_pooled_capacity == 0);
    DM_CHECK(null_rt.bytes_saved_vs_discrete == 0);
    DM_CHECK(null_rt.alloc_count == 0);
    DM_CHECK(null_rt.reuse_hits == 0);
    DM_CHECK(null_rt.zero_copy_mappings == 0);

    // NULL ring allocation must fail and sanitize non-null out_slice
    dm_uma_slice_t poisoned_slice;
    std::memset(&poisoned_slice, 0xCC, sizeof(poisoned_slice));
    DM_CHECK(!dm_uma_ring_alloc(nullptr, 256, 256, &poisoned_slice));
    DM_CHECK(poisoned_slice.cpu_ptr == nullptr);
    DM_CHECK(poisoned_slice.metal_buffer_bridge == nullptr);
    DM_CHECK(poisoned_slice.offset == 0);
    DM_CHECK(poisoned_slice.size == 0);
    DM_CHECK(!dm_uma_ring_alloc(nullptr, 256, 256, nullptr));
    DM_CHECK(!dm_uma_ring_alloc(nullptr, 0, 0, nullptr));

    // NULL pool lifecycle, acquire, recycle & telemetry guards
    dm_uma_pool_destroy(nullptr);
    dm_uma_pool_recycle_buffer(nullptr, nullptr);
    int dummy_tag = 7;
    dm_uma_pool_recycle_buffer(nullptr, &dummy_tag);

    const dm_uma_telemetry_t null_pt = dm_uma_pool_telemetry(nullptr);
    DM_CHECK(null_pt.bytes_allocated == 0);
    DM_CHECK(null_pt.bytes_pooled_capacity == 0);
    DM_CHECK(null_pt.bytes_saved_vs_discrete == 0);
    DM_CHECK(null_pt.alloc_count == 0);
    DM_CHECK(null_pt.reuse_hits == 0);
    DM_CHECK(null_pt.zero_copy_mappings == 0);

    void *cpu_sentinel = &dummy_tag;
    DM_CHECK(dm_uma_pool_acquire_buffer(nullptr, 1024, &cpu_sentinel) == nullptr);
    DM_CHECK(cpu_sentinel == nullptr);
    DM_CHECK(dm_uma_pool_acquire_buffer(nullptr, 0, nullptr) == nullptr);
}

static void run_gpu_uma_edge_case_tests(id<MTLDevice> dev) {
    constexpr size_t kPageSize = 16384u;
    constexpr size_t kMinAlign = 256u;

    // 1. UMA Ring: page rounding, zero-size/NULL/overflow guards, alignment invariants & reset lifecycle
    dm_uma_ring_t *r = dm_uma_ring_create(100, DM_UMA_HEAP_READBACK);
    DM_CHECK(r != nullptr);
    void *ring_buf_raw = dm_uma_ring_metal_buffer(r);
    DM_CHECK(ring_buf_raw != nullptr);
    {
        id<MTLBuffer> ring_mtl = (__bridge id<MTLBuffer>)ring_buf_raw;
        DM_CHECK(ring_mtl.length == kPageSize);
        DM_CHECK(ring_mtl.storageMode == MTLStorageModeShared);
    }
    const dm_uma_telemetry_t r_init = dm_uma_ring_telemetry(r);
    DM_CHECK(r_init.bytes_pooled_capacity == kPageSize);
    DM_CHECK(r_init.zero_copy_mappings == 1);
    DM_CHECK(r_init.alloc_count == 0);

    dm_uma_slice_t s{};
    std::memset(&s, 0xAB, sizeof(s));
    DM_CHECK(!dm_uma_ring_alloc(r, 0, 256, &s));
    DM_CHECK(s.cpu_ptr == nullptr && s.offset == 0 && s.size == 0);
    DM_CHECK(!dm_uma_ring_alloc(r, 64, 256, nullptr));
    DM_CHECK(!dm_uma_ring_alloc(r, SIZE_MAX, 256, &s));
    DM_CHECK(!dm_uma_ring_alloc(r, 64, SIZE_MAX, &s));
    DM_CHECK(!dm_uma_ring_alloc(r, kPageSize + 1u, 256, &s));
    DM_CHECK(dm_uma_ring_telemetry(r).alloc_count == 0);

    // Alignment invariants: minimum 256B offset/pointer alignment, non-multiple rounding & power-of-2 alignments
    dm_uma_slice_t s1{}, s2{}, s3{}, s4{}, s5{};
    DM_CHECK(dm_uma_ring_alloc(r, 13, 0, &s1));
    DM_CHECK(s1.offset == 0 && s1.size == 13 && s1.metal_buffer_bridge == ring_buf_raw);
    DM_CHECK((reinterpret_cast<uintptr_t>(s1.cpu_ptr) % kPageSize) == 0u);

    DM_CHECK(dm_uma_ring_alloc(r, 7, 1, &s2));
    DM_CHECK(s2.offset == kMinAlign && s2.size == 7);
    DM_CHECK((s2.offset % kMinAlign) == 0u);
    DM_CHECK((reinterpret_cast<uintptr_t>(s2.cpu_ptr) % kMinAlign) == 0u);
    DM_CHECK(s2.offset >= s1.offset + s1.size);
    DM_CHECK(static_cast<uint8_t *>(s2.cpu_ptr) == static_cast<uint8_t *>(s1.cpu_ptr) + s2.offset);

    // Non-multiple alignment 300 (>256) must round up to 512
    DM_CHECK(dm_uma_ring_alloc(r, 33, 300, &s3));
    DM_CHECK(s3.offset == 512u && (s3.offset % 512u) == 0u);
    DM_CHECK((reinterpret_cast<uintptr_t>(s3.cpu_ptr) % 512u) == 0u);
    DM_CHECK(s3.offset >= s2.offset + s2.size);

    DM_CHECK(dm_uma_ring_alloc(r, 64, 1024, &s4));
    DM_CHECK(s4.offset == 1024u && (s4.offset % 1024u) == 0u);
    DM_CHECK((reinterpret_cast<uintptr_t>(s4.cpu_ptr) % 1024u) == 0u);

    DM_CHECK(dm_uma_ring_alloc(r, 128, 4096, &s5));
    DM_CHECK(s5.offset == 4096u && (s5.offset % 4096u) == 0u);
    DM_CHECK((reinterpret_cast<uintptr_t>(s5.cpu_ptr) % 4096u) == 0u);

    const dm_uma_telemetry_t r_mid = dm_uma_ring_telemetry(r);
    DM_CHECK(r_mid.alloc_count == 5);
    DM_CHECK(r_mid.bytes_allocated == (13u + 7u + 33u + 64u + 128u));
    DM_CHECK(r_mid.bytes_saved_vs_discrete == r_mid.bytes_allocated);

    // Over-remaining-capacity request must fail cleanly without advancing cursor
    DM_CHECK(!dm_uma_ring_alloc(r, kPageSize - 4096u, 256, &s));
    dm_uma_slice_t s_tail{};
    DM_CHECK(dm_uma_ring_alloc(r, kPageSize - 4352u, 256, &s_tail));
    DM_CHECK(s_tail.offset == 4352u);
    DM_CHECK(!dm_uma_ring_alloc(r, 1, 1, &s));  // Completely full

    // Reset reclaims entire capacity while preserving cumulative telemetry
    dm_uma_ring_reset(r);
    dm_uma_slice_t s_full{};
    DM_CHECK(dm_uma_ring_alloc(r, kPageSize, 256, &s_full));
    DM_CHECK(s_full.offset == 0 && s_full.size == kPageSize);
    dm_uma_ring_destroy(r);

    // 2. UMA Pool: zero-size, overflow, over-heap, double-recycle (double-free) & foreign-buffer safety
    dm_uma_pool_t *pool = dm_uma_pool_create(65536, DM_UMA_HEAP_DEFAULT_SHARED);
    dm_uma_pool_t *pool_other = dm_uma_pool_create(32768, DM_UMA_HEAP_UPLOAD);
    DM_CHECK(pool != nullptr && pool_other != nullptr);
    DM_CHECK(dm_uma_pool_telemetry(pool).bytes_pooled_capacity >= 65536u);

    int marker = 0;
    void *cpu = &marker;
    DM_CHECK(dm_uma_pool_acquire_buffer(pool, 0, &cpu) == nullptr && cpu == nullptr);
    cpu = &marker;
    DM_CHECK(dm_uma_pool_acquire_buffer(pool, SIZE_MAX, &cpu) == nullptr && cpu == nullptr);
    cpu = &marker;
    DM_CHECK(dm_uma_pool_acquire_buffer(pool, 64u * 1024u * 1024u, &cpu) == nullptr && cpu == nullptr);
    DM_CHECK(dm_uma_pool_telemetry(pool).alloc_count == 0);

    // Acquire with nullptr out_cpu_ptr and verify 256-byte sub-allocation alignment
    void *b1 = dm_uma_pool_acquire_buffer(pool, 100, nullptr);
    DM_CHECK(b1 != nullptr);
    {
        id<MTLBuffer> mtl_b1 = (__bridge id<MTLBuffer>)b1;
        DM_CHECK(mtl_b1.length >= kMinAlign && (mtl_b1.length % kMinAlign) == 0u);
        DM_CHECK(mtl_b1.contents != nullptr);
        DM_CHECK((reinterpret_cast<uintptr_t>(mtl_b1.contents) % kMinAlign) == 0u);
    }

    // Recycle nullptr must be a safe no-op; foreign/cross-pool recycle must be ignored
    dm_uma_pool_recycle_buffer(pool, nullptr);
    {
        id<MTLBuffer> foreign = [dev newBufferWithLength:512 options:MTLResourceStorageModeShared];
        DM_CHECK(foreign != nil);
        dm_uma_pool_recycle_buffer(pool, (__bridge void *)foreign);
    }
    dm_uma_pool_recycle_buffer(pool_other, b1);  // b1 belongs to pool, not pool_other

    // Double-recycle (double-free) safety: recycling b1 multiple times must NOT duplicate free_list entries
    dm_uma_pool_recycle_buffer(pool, b1);
    dm_uma_pool_recycle_buffer(pool, b1);
    dm_uma_pool_recycle_buffer(pool, b1);

    void *p_c1 = nullptr;
    void *p_c2 = nullptr;
    void *c1 = dm_uma_pool_acquire_buffer(pool, 100, &p_c1);
    void *c2 = dm_uma_pool_acquire_buffer(pool, 100, &p_c2);
    DM_CHECK(c1 == b1 && p_c1 != nullptr);
    DM_CHECK(c2 != nullptr && c2 != c1 && p_c2 != nullptr && p_c2 != p_c1);
    DM_CHECK(dm_uma_pool_telemetry(pool).reuse_hits == 1);

    // Smaller free buffer (256B) must not satisfy larger request (4096B), keeping sizing safe
    dm_uma_pool_recycle_buffer(pool, c1);
    void *p_large = nullptr;
    void *large_buf = dm_uma_pool_acquire_buffer(pool, 4096, &p_large);
    DM_CHECK(large_buf != nullptr && large_buf != c1 && p_large != nullptr);
    DM_CHECK(dm_uma_pool_telemetry(pool).reuse_hits == 1);

    // Lifecycle teardown with buffers simultaneously in free_list (c1) and in_use (c2, large_buf)
    dm_uma_pool_destroy(pool);
    dm_uma_pool_destroy(pool_other);

    printf("[dm_uma_bench] Unit tests (NULL/zero-size guards, alignment, double-recycle, lifecycle) OK\n");
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

    run_device_independent_uma_tests();

    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if ((!dev || !dev.hasUnifiedMemory) && ctest_skip_allowed()) {
            printf("[dm_uma_bench] SKIP: no Apple Silicon UMA Metal device in headless environment\n");
            return 77;
        }
        DM_CHECK(dev != nil && dev.hasUnifiedMemory);

        run_gpu_uma_edge_case_tests(dev);

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
        DM_CHECK(lib != nil);
        id<MTLFunction> fn = [lib newFunctionWithName:@"reduce4"];
        DM_CHECK(fn != nil);
        id<MTLComputePipelineState> cps = [dev newComputePipelineStateWithFunction:fn error:&err];
        DM_CHECK(cps != nil);
        id<MTLCommandQueue> queue = [dev newCommandQueue];
        DM_CHECK(queue != nil);

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
        DM_CHECK(stage_in != nil && priv_in != nil && priv_out != nil && stage_out != nil);
        DM_CHECK(stage_in.contents != nullptr && stage_out.contents != nullptr);
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
            DM_CHECK(cb != nil);
            id<MTLBlitCommandEncoder> b1 = [cb blitCommandEncoder];
            DM_CHECK(b1 != nil);
            [b1 copyFromBuffer:stage_in sourceOffset:0 toBuffer:priv_in destinationOffset:0 size:in_bytes];
            [b1 endEncoding];

            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            DM_CHECK(ce != nil);
            [ce setComputePipelineState:cps];
            [ce setBuffer:priv_in offset:0 atIndex:0];
            [ce setBuffer:priv_out offset:0 atIndex:1];
            [ce dispatchThreads:MTLSizeMake(kOutCount, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [ce endEncoding];

            id<MTLBlitCommandEncoder> b2 = [cb blitCommandEncoder];
            DM_CHECK(b2 != nil);
            [b2 copyFromBuffer:priv_out sourceOffset:0 toBuffer:stage_out destinationOffset:0 size:out_bytes];
            [b2 endEncoding];

            [cb commit];
            [cb waitUntilCompleted];
            DM_CHECK(cb.status == MTLCommandBufferStatusCompleted);
            std::memcpy(cpu_dst_discrete.data(), stage_out.contents, out_bytes);
            const double t1 = now_ms();
            if (f >= kWarmup) discrete_sum_ms += (t1 - t0);
            if (f == kWarmup + kFrames - 1) {
                for (uint32_t i = 0; i < kOutCount; ++i) discrete_checksum += cpu_dst_discrete[i];
            }
        }
        stage_in = nil;
        priv_in = nil;
        priv_out = nil;
        stage_out = nil;

        // --- Path B: DirectMetal UMA Zero-Copy (newBufferWithBytesNoCopy Shared Ring) ---
        const uint64_t gpu_alloc_before_uma = dev.currentAllocatedSize;
        dm_uma_ring_t *ring = dm_uma_ring_create(in_bytes + out_bytes + 65536u, DM_UMA_HEAP_UPLOAD);
        DM_CHECK(ring != nullptr);
        const uint64_t gpu_alloc_uma = dev.currentAllocatedSize - gpu_alloc_before_uma;
        const size_t total_footprint_uma = gpu_alloc_uma;  // Zero separate CPU heap or private copy!

        // Also test MTLHeap pool reuse + edge cases
        DM_CHECK(dm_uma_ring_create(0, DM_UMA_HEAP_UPLOAD) == nullptr);
        DM_CHECK(dm_uma_pool_create(0, DM_UMA_HEAP_DYNAMIC_CB) == nullptr);
        dm_uma_pool_t *pool = dm_uma_pool_create(2u * 1024u * 1024u, DM_UMA_HEAP_DYNAMIC_CB);
        DM_CHECK(pool != nullptr);
        void *pool_cpu = nullptr;
        void *b_a = dm_uma_pool_acquire_buffer(pool, 65536, &pool_cpu);
        DM_CHECK(b_a != nullptr && pool_cpu != nullptr);
        dm_uma_pool_recycle_buffer(pool, b_a);
        void *b_b = dm_uma_pool_acquire_buffer(pool, 65536, &pool_cpu);
        DM_CHECK(b_b == b_a);
        DM_CHECK(dm_uma_pool_telemetry(pool).reuse_hits == 1);
        dm_uma_pool_recycle_buffer(pool, b_b);
        dm_uma_pool_destroy(pool);

        double uma_sum_ms = 0.0;
        uint64_t uma_checksum = 0;
        std::vector<uint32_t> last_uma_out(kOutCount);
        for (int f = 0; f < kWarmup + kFrames; ++f) {
            dm_uma_ring_reset(ring);
            dm_uma_slice_t in_slice{}, out_slice{};
            DM_CHECK(dm_uma_ring_alloc(ring, in_bytes, 256, &in_slice));
            DM_CHECK(dm_uma_ring_alloc(ring, out_bytes, 256, &out_slice));
            uint32_t *in_ptr = static_cast<uint32_t *>(in_slice.cpu_ptr);
            const uint32_t *out_ptr = static_cast<const uint32_t *>(out_slice.cpu_ptr);

            const double t0 = now_ms();
            for (uint32_t i = 0; i < kInCount; ++i) {
                in_ptr[i] = (i * 131u) ^ (uint32_t)f;
            }
            id<MTLBuffer> mtl_buf = (__bridge id<MTLBuffer>)in_slice.metal_buffer_bridge;
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            DM_CHECK(cb != nil);
            id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
            DM_CHECK(ce != nil);
            [ce setComputePipelineState:cps];
            [ce setBuffer:mtl_buf offset:in_slice.offset atIndex:0];
            [ce setBuffer:mtl_buf offset:out_slice.offset atIndex:1];
            [ce dispatchThreads:MTLSizeMake(kOutCount, 1, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
            [ce endEncoding];
            [cb commit];
            [cb waitUntilCompleted];
            DM_CHECK(cb.status == MTLCommandBufferStatusCompleted);

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

        DM_CHECK(uma_checksum == discrete_checksum);
        DM_CHECK(std::memcmp(last_uma_out.data(), cpu_dst_discrete.data(), out_bytes) == 0);

        const double discrete_mean = discrete_sum_ms / kFrames;
        const double uma_mean = uma_sum_ms / kFrames;
        const double speedup = uma_mean > 0.0 ? (discrete_mean / uma_mean) : 0.0;
        const double payload_gb = (double)(in_bytes + out_bytes) / (1024.0 * 1024.0 * 1024.0);
        const double discrete_gbps = discrete_mean > 0.0 ? (payload_gb / (discrete_mean / 1000.0)) : 0.0;
        const double uma_gbps = uma_mean > 0.0 ? (payload_gb / (uma_mean / 1000.0)) : 0.0;
        const double mem_reduction_pct =
            total_footprint_discrete > 0
                ? (100.0 * (1.0 - (double)total_footprint_uma / (double)total_footprint_discrete))
                : 0.0;

        printf("[dm_uma_bench] Bit-exact verification PASSED (checksum=0x%llx)\n",
               (unsigned long long)uma_checksum);
        printf("[dm_uma_bench] Discrete Staging (2x copy+blit): %.3f ms/frame (%.2f GB/s, footprint=%.2f MiB)\n",
               discrete_mean, discrete_gbps, (double)total_footprint_discrete / (1024.0 * 1024.0));
        printf("[dm_uma_bench] DirectMetal UMA Zero-Copy     : %.3f ms/frame (%.2f GB/s, footprint=%.2f MiB)\n",
               uma_mean, uma_gbps, (double)total_footprint_uma / (1024.0 * 1024.0));
        printf("[dm_uma_bench] Speedup: %.2fx | Footprint Reduction: %.1f%%\n",
               speedup, mem_reduction_pct);

        if (json_path) {
            FILE *jf = fopen(json_path, "w");
            DM_CHECK(jf != nullptr);
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
