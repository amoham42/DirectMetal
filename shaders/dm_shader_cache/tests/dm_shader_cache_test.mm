#include "dm_shader_cache.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <thread>
#include <time.h>
#include <unistd.h>
#include <vector>

#define DM_CHECK(expr)                                                                 \
    do {                                                                               \
        if (!(expr)) {                                                                 \
            fprintf(stderr, "[dm_shader_cache_test] CHECK FAILED (%s:%d): %s\n",       \
                    __FILE__, __LINE__, #expr);                                        \
            std::abort();                                                              \
        }                                                                              \
    } while (0)

static bool ctest_skip_allowed(void) {
    const char *v = std::getenv("DM_CTEST_ALLOW_SKIP");
    return v && v[0] && std::strcmp(v, "0") != 0;
}

struct TempDirGuard {
    std::string path;
    explicit TempDirGuard(const char *p) : path(p ? p : "") {}
    ~TempDirGuard() {
        if (!path.empty()) {
            std::error_code ec;
            std::filesystem::remove_all(path, ec);
        }
    }
};

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

static NSString *kShaderSrc = @R"(
#include <metal_stdlib>
using namespace metal;

constant int kVariant [[function_constant(0)]];

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

vertex VOut sc_vs(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(0.0f, 0.8f), float2(0.8f, -0.8f), float2(-0.8f, -0.8f) };
    VOut o;
    o.pos = float4(p[vid], 0.0f, 1.0f);
    o.uv = p[vid] * 0.5f + 0.5f;
    return o;
}

fragment float4 sc_fs(VOut in [[stage_in]]) {
    float3 acc = float3(in.uv.x, in.uv.y, 0.25f);
    for (int i = 0; i < 24 + kVariant; ++i) {
        acc = sin(acc * 3.14159f + float(i) * 0.17f) * 0.5f + 0.5f;
    }
    return float4(acc, 1.0f);
}

kernel void sc_cs(device float4* out_buf [[buffer(0)]], uint gid [[thread_position_in_grid]]) {
    float4 v = float4(float(gid) * 0.01f);
    for (int i = 0; i < 32 + kVariant; ++i) {
        v = fma(v, float4(0.97f), float4(sin(float(i + kVariant))));
    }
    out_buf[gid] = v;
}
)";

static MTLRenderPipelineDescriptor *make_single_render_desc(id<MTLLibrary> lib, int variant, MTLPixelFormat fmt) {
    NSError *err = nil;
    id<MTLFunction> vs = [lib newFunctionWithName:@"sc_vs"];
    DM_CHECK(vs != nil);
    MTLFunctionConstantValues *fcv = [MTLFunctionConstantValues new];
    DM_CHECK(fcv != nil);
    [fcv setConstantValue:&variant type:MTLDataTypeInt atIndex:0];
    id<MTLFunction> fs = [lib newFunctionWithName:@"sc_fs" constantValues:fcv error:&err];
    DM_CHECK(fs != nil);
    MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
    DM_CHECK(rpd != nil);
    rpd.vertexFunction = vs;
    rpd.fragmentFunction = fs;
    rpd.colorAttachments[0].pixelFormat = fmt;
    return rpd;
}

static MTLComputePipelineDescriptor *make_single_compute_desc(id<MTLLibrary> lib, int variant) {
    NSError *err = nil;
    MTLFunctionConstantValues *fcv = [MTLFunctionConstantValues new];
    DM_CHECK(fcv != nil);
    [fcv setConstantValue:&variant type:MTLDataTypeInt atIndex:0];
    id<MTLFunction> cs = [lib newFunctionWithName:@"sc_cs" constantValues:fcv error:&err];
    DM_CHECK(cs != nil);
    MTLComputePipelineDescriptor *cpd = [MTLComputePipelineDescriptor new];
    DM_CHECK(cpd != nil);
    cpd.computeFunction = cs;
    return cpd;
}

static std::vector<MTLRenderPipelineDescriptor *> make_render_descs(id<MTLLibrary> lib, NSError **err) {
    std::vector<MTLRenderPipelineDescriptor *> out;
    id<MTLFunction> vs = [lib newFunctionWithName:@"sc_vs"];
    DM_CHECK(vs != nil);
    const MTLPixelFormat fmts[4] = {
        MTLPixelFormatRGBA8Unorm,
        MTLPixelFormatRGBA8Unorm_sRGB,
        MTLPixelFormatBGRA8Unorm,
        MTLPixelFormatRGBA16Float,
    };
    for (int v = 0; v < 4; ++v) {
        MTLFunctionConstantValues *fcv = [MTLFunctionConstantValues new];
        DM_CHECK(fcv != nil);
        [fcv setConstantValue:&v type:MTLDataTypeInt atIndex:0];
        id<MTLFunction> fs = [lib newFunctionWithName:@"sc_fs" constantValues:fcv error:err];
        DM_CHECK(fs != nil);
        for (int b = 0; b < 4; ++b) {
            MTLRenderPipelineDescriptor *rpd = [MTLRenderPipelineDescriptor new];
            DM_CHECK(rpd != nil);
            rpd.vertexFunction = vs;
            rpd.fragmentFunction = fs;
            rpd.colorAttachments[0].pixelFormat = fmts[b];
            rpd.colorAttachments[0].blendingEnabled = (b % 2 == 1);
            out.push_back(rpd);
        }
    }
    return out;
}

static std::vector<MTLComputePipelineDescriptor *> make_compute_descs(id<MTLLibrary> lib, NSError **err) {
    std::vector<MTLComputePipelineDescriptor *> out;
    for (int v = 0; v < 8; ++v) {
        MTLFunctionConstantValues *fcv = [MTLFunctionConstantValues new];
        DM_CHECK(fcv != nil);
        [fcv setConstantValue:&v type:MTLDataTypeInt atIndex:0];
        id<MTLFunction> cs = [lib newFunctionWithName:@"sc_cs" constantValues:fcv error:err];
        DM_CHECK(cs != nil);
        MTLComputePipelineDescriptor *cpd = [MTLComputePipelineDescriptor new];
        DM_CHECK(cpd != nil);
        cpd.computeFunction = cs;
        out.push_back(cpd);
    }
    return out;
}

static void test_device_independent_contracts(const char *cache_root) {
    char err_buf[256] = {0};

    // NULL / empty inputs & error buffer boundary handling
    DM_CHECK(dm_shader_cache_open(nullptr, "demo_v1", err_buf, sizeof(err_buf)) == nullptr);
    DM_CHECK(std::strlen(err_buf) > 0);
    DM_CHECK(dm_shader_cache_open("", "demo_v1", err_buf, sizeof(err_buf)) == nullptr);
    DM_CHECK(dm_shader_cache_open(cache_root, nullptr, err_buf, sizeof(err_buf)) == nullptr);
    DM_CHECK(dm_shader_cache_open(cache_root, "", err_buf, sizeof(err_buf)) == nullptr);
    DM_CHECK(dm_shader_cache_open(nullptr, nullptr, nullptr, 0) == nullptr);

    char tiny_err[5] = {'1', '2', '3', '4', 'Z'};
    DM_CHECK(dm_shader_cache_open(nullptr, "demo_v1", tiny_err, 4) == nullptr);
    DM_CHECK(std::strlen(tiny_err) == 3 && tiny_err[4] == 'Z');

    // Path traversal & separator characters in game_build_id must be rejected
    DM_CHECK(dm_shader_cache_open(cache_root, "..", err_buf, sizeof(err_buf)) == nullptr);
    DM_CHECK(dm_shader_cache_open(cache_root, "../escape", err_buf, sizeof(err_buf)) == nullptr);
    DM_CHECK(dm_shader_cache_open(cache_root, "a..b", err_buf, sizeof(err_buf)) == nullptr);
    DM_CHECK(dm_shader_cache_open(cache_root, "nested/id", err_buf, sizeof(err_buf)) == nullptr);
    DM_CHECK(dm_shader_cache_open(cache_root, "nested\\id", err_buf, sizeof(err_buf)) == nullptr);

    // Null handle behavior across all entry points
    dm_shader_cache_close(nullptr);
    const dm_shader_cache_stats_t null_stats = dm_shader_cache_stats(nullptr);
    DM_CHECK(!null_stats.loaded_existing);
    DM_CHECK(null_stats.pipelines_cached == 0);
    DM_CHECK(null_stats.archive_bytes == 0);
    DM_CHECK(null_stats.cache_key[0] == '\0');

    int dummy = 0;
    DM_CHECK(!dm_shader_cache_add_render_pso(nullptr, &dummy, err_buf, sizeof(err_buf)));
    DM_CHECK(!dm_shader_cache_add_compute_pso(nullptr, &dummy, err_buf, sizeof(err_buf)));
    DM_CHECK(!dm_shader_cache_flush(nullptr, err_buf, sizeof(err_buf)));
    DM_CHECK(dm_shader_cache_create_render_pso(nullptr, &dummy, false, err_buf, sizeof(err_buf)) == nullptr);
    DM_CHECK(dm_shader_cache_create_compute_pso(nullptr, &dummy, true, nullptr, 0) == nullptr);

    // Isolated temporary directory creation and automatic TempDirGuard cleanup verification
    std::string sub_path;
    {
        char iso_tmpl[] = "/tmp/dm_sc_isolated_XXXXXX";
        char *iso_dir = mkdtemp(iso_tmpl);
        DM_CHECK(iso_dir != nullptr);
        sub_path = iso_dir;
        TempDirGuard iso_guard(iso_dir);
        DM_CHECK(std::filesystem::exists(sub_path));
    }
    DM_CHECK(!std::filesystem::exists(sub_path));
}

static void test_gpu_edge_cases_and_corruption(id<MTLDevice> dev, id<MTLLibrary> lib) {
    char err_buf[512] = {0};

    std::string iso_root;
    {
        char tmpl[] = "/tmp/dm_sc_edge_XXXXXX";
        char *made = mkdtemp(tmpl);
        DM_CHECK(made != nullptr);
        iso_root = made;
        TempDirGuard guard(made);

        // Overlong game_build_id (> 192 cache_key limit) and overlong cache_root (> 1024 archive_path)
        const std::string long_id(200, 'k');
        DM_CHECK(dm_shader_cache_open(made, long_id.c_str(), err_buf, sizeof(err_buf)) == nullptr);

        std::string long_root(made);
        long_root.push_back('/');
        long_root.append(1050, 'd');
        DM_CHECK(dm_shader_cache_open(long_root.c_str(), "v1", err_buf, sizeof(err_buf)) == nullptr);

        // cache_root pointing to an existing regular file must fail mkdir_p cleanly
        const std::string blocking_file = iso_root + "/regular_file_not_dir";
        FILE *bf = fopen(blocking_file.c_str(), "wb");
        DM_CHECK(bf != nullptr);
        fputs("block", bf);
        fclose(bf);
        DM_CHECK(dm_shader_cache_open(blocking_file.c_str(), "v1", err_buf, sizeof(err_buf)) == nullptr);

        // Valid cache handle with NULL descriptors must fail gracefully without crashing
        dm_shader_cache_t *c = dm_shader_cache_open(made, "edge_v1", err_buf, sizeof(err_buf));
        DM_CHECK(c != nullptr);
        DM_CHECK(!dm_shader_cache_add_render_pso(c, nullptr, err_buf, sizeof(err_buf)));
        DM_CHECK(std::strlen(err_buf) > 0);
        DM_CHECK(!dm_shader_cache_add_compute_pso(c, nullptr, err_buf, sizeof(err_buf)));
        DM_CHECK(dm_shader_cache_create_render_pso(c, nullptr, false, err_buf, sizeof(err_buf)) == nullptr);
        DM_CHECK(dm_shader_cache_create_compute_pso(c, nullptr, false, err_buf, sizeof(err_buf)) == nullptr);

        // Cache miss vs. hit behavior: populate variant 10, leave variant 999 uncached
        MTLRenderPipelineDescriptor *cached_rpd = make_single_render_desc(lib, 10, MTLPixelFormatBGRA8Unorm);
        MTLComputePipelineDescriptor *cached_cpd = make_single_compute_desc(lib, 10);
        MTLRenderPipelineDescriptor *uncached_rpd = make_single_render_desc(lib, 999, MTLPixelFormatRGBA16Float);
        MTLComputePipelineDescriptor *uncached_cpd = make_single_compute_desc(lib, 999);

        // Strict lookup on empty cold archive must miss (nullptr)
        DM_CHECK(dm_shader_cache_create_render_pso(c, (__bridge void *)cached_rpd, true, err_buf, sizeof(err_buf)) == nullptr);
        DM_CHECK(dm_shader_cache_create_compute_pso(c, (__bridge void *)cached_cpd, true, err_buf, sizeof(err_buf)) == nullptr);

        DM_CHECK(dm_shader_cache_add_render_pso(c, (__bridge void *)cached_rpd, err_buf, sizeof(err_buf)));
        DM_CHECK(dm_shader_cache_add_compute_pso(c, (__bridge void *)cached_cpd, err_buf, sizeof(err_buf)));
        DM_CHECK(dm_shader_cache_stats(c).pipelines_cached == 2);
        DM_CHECK(dm_shader_cache_flush(c, err_buf, sizeof(err_buf)));
        const dm_shader_cache_stats_t flushed_st = dm_shader_cache_stats(c);
        DM_CHECK(flushed_st.archive_bytes > 0);
        DM_CHECK(std::filesystem::exists(flushed_st.archive_path));
        DM_CHECK(std::filesystem::exists(flushed_st.manifest_path));
        dm_shader_cache_close(c);

        // Reopen with fresh MTLLibrary to test true archive hit vs. miss
        NSError *lib_err = nil;
        id<MTLLibrary> fresh_lib = [dev newLibraryWithSource:kShaderSrc options:nil error:&lib_err];
        DM_CHECK(fresh_lib != nil);
        MTLRenderPipelineDescriptor *fresh_hit_rpd = make_single_render_desc(fresh_lib, 10, MTLPixelFormatBGRA8Unorm);
        MTLComputePipelineDescriptor *fresh_hit_cpd = make_single_compute_desc(fresh_lib, 10);
        MTLRenderPipelineDescriptor *fresh_miss_rpd = make_single_render_desc(fresh_lib, 999, MTLPixelFormatRGBA16Float);
        MTLComputePipelineDescriptor *fresh_miss_cpd = make_single_compute_desc(fresh_lib, 999);

        dm_shader_cache_t *warm = dm_shader_cache_open(made, "edge_v1", err_buf, sizeof(err_buf));
        DM_CHECK(warm != nullptr);
        DM_CHECK(dm_shader_cache_stats(warm).loaded_existing);

        // Cached variant hits under strict_archive_only=true
        void *hit_r = dm_shader_cache_create_render_pso(warm, (__bridge void *)fresh_hit_rpd, true, err_buf, sizeof(err_buf));
        DM_CHECK(hit_r != nullptr);
        CFRelease(hit_r);
        void *hit_c = dm_shader_cache_create_compute_pso(warm, (__bridge void *)fresh_hit_cpd, true, err_buf, sizeof(err_buf));
        DM_CHECK(hit_c != nullptr);
        CFRelease(hit_c);

        // Uncached variant 999 misses under strict_archive_only=true, succeeds under strict_archive_only=false
        DM_CHECK(dm_shader_cache_create_render_pso(warm, (__bridge void *)fresh_miss_rpd, true, err_buf, sizeof(err_buf)) == nullptr);
        DM_CHECK(dm_shader_cache_create_compute_pso(warm, (__bridge void *)fresh_miss_cpd, true, err_buf, sizeof(err_buf)) == nullptr);
        void *jit_r = dm_shader_cache_create_render_pso(warm, (__bridge void *)fresh_miss_rpd, false, err_buf, sizeof(err_buf));
        DM_CHECK(jit_r != nullptr);
        CFRelease(jit_r);
        void *jit_c = dm_shader_cache_create_compute_pso(warm, (__bridge void *)fresh_miss_cpd, false, err_buf, sizeof(err_buf));
        DM_CHECK(jit_c != nullptr);
        CFRelease(jit_c);
        dm_shader_cache_close(warm);

        // --- Corrupted, truncated, and 0-byte archive recovery ---
        // 1) Truncated archive (12 bytes)
        DM_CHECK(truncate(flushed_st.archive_path, 12) == 0);
        dm_shader_cache_t *trunc_cache = dm_shader_cache_open(made, "edge_v1", err_buf, sizeof(err_buf));
        DM_CHECK(trunc_cache != nullptr);
        DM_CHECK(!dm_shader_cache_stats(trunc_cache).loaded_existing);
        DM_CHECK(dm_shader_cache_stats(trunc_cache).archive_bytes == 0);
        dm_shader_cache_close(trunc_cache);

        // 2) Corrupted garbage archive (256 invalid bytes) -> fallback + self-heal on flush
        {
            FILE *cf = fopen(flushed_st.archive_path, "wb");
            DM_CHECK(cf != nullptr);
            uint8_t garbage[256];
            std::memset(garbage, 0xDE, sizeof(garbage));
            DM_CHECK(fwrite(garbage, 1, sizeof(garbage), cf) == sizeof(garbage));
            fclose(cf);
        }
        dm_shader_cache_t *corrupt_cache = dm_shader_cache_open(made, "edge_v1", err_buf, sizeof(err_buf));
        DM_CHECK(corrupt_cache != nullptr);
        DM_CHECK(!dm_shader_cache_stats(corrupt_cache).loaded_existing);
        DM_CHECK(dm_shader_cache_add_render_pso(corrupt_cache, (__bridge void *)uncached_rpd, err_buf, sizeof(err_buf)));
        DM_CHECK(dm_shader_cache_add_compute_pso(corrupt_cache, (__bridge void *)uncached_cpd, err_buf, sizeof(err_buf)));
        DM_CHECK(dm_shader_cache_flush(corrupt_cache, err_buf, sizeof(err_buf)));
        dm_shader_cache_close(corrupt_cache);

        // Verify healed archive loads cleanly and hits variant 999 strictly
        dm_shader_cache_t *healed = dm_shader_cache_open(made, "edge_v1", err_buf, sizeof(err_buf));
        DM_CHECK(healed != nullptr);
        DM_CHECK(dm_shader_cache_stats(healed).loaded_existing);
        void *healed_r = dm_shader_cache_create_render_pso(healed, (__bridge void *)fresh_miss_rpd, true, err_buf, sizeof(err_buf));
        DM_CHECK(healed_r != nullptr);
        CFRelease(healed_r);
        dm_shader_cache_close(healed);

        // 3) Zero-byte empty archive file -> treated as cold
        DM_CHECK(truncate(flushed_st.archive_path, 0) == 0);
        dm_shader_cache_t *zero_cache = dm_shader_cache_open(made, "edge_v1", err_buf, sizeof(err_buf));
        DM_CHECK(zero_cache != nullptr);
        DM_CHECK(!dm_shader_cache_stats(zero_cache).loaded_existing);
        DM_CHECK(dm_shader_cache_stats(zero_cache).archive_bytes == 0);
        dm_shader_cache_close(zero_cache);
    }
    // Verify TempDirGuard removed isolated directory completely
    DM_CHECK(!std::filesystem::exists(iso_root));
}

static void test_repeated_and_concurrent_store_lookup(id<MTLDevice> dev, const char *cache_root) {
    char err_buf[512] = {0};
    NSError *err = nil;
    id<MTLLibrary> base_lib = [dev newLibraryWithSource:kShaderSrc options:nil error:&err];
    DM_CHECK(base_lib != nil);

    // 1) Repeated store -> flush -> close -> warm lookup cycles
    for (int cycle = 0; cycle < 4; ++cycle) {
        dm_shader_cache_t *sc = dm_shader_cache_open(cache_root, "repeat_cycle_v1", err_buf, sizeof(err_buf));
        DM_CHECK(sc != nullptr);
        if (cycle > 0) {
            DM_CHECK(dm_shader_cache_stats(sc).loaded_existing);
        }
        MTLRenderPipelineDescriptor *rpd = make_single_render_desc(base_lib, 100 + cycle, MTLPixelFormatBGRA8Unorm);
        MTLComputePipelineDescriptor *cpd = make_single_compute_desc(base_lib, 100 + cycle);
        DM_CHECK(dm_shader_cache_add_render_pso(sc, (__bridge void *)rpd, err_buf, sizeof(err_buf)));
        DM_CHECK(dm_shader_cache_add_compute_pso(sc, (__bridge void *)cpd, err_buf, sizeof(err_buf)));
        DM_CHECK(dm_shader_cache_flush(sc, err_buf, sizeof(err_buf)));
        dm_shader_cache_close(sc);

        dm_shader_cache_t *verify_sc = dm_shader_cache_open(cache_root, "repeat_cycle_v1", err_buf, sizeof(err_buf));
        DM_CHECK(verify_sc != nullptr);
        DM_CHECK(dm_shader_cache_stats(verify_sc).loaded_existing);
        for (int prev = 0; prev <= cycle; ++prev) {
            MTLRenderPipelineDescriptor *vr = make_single_render_desc(base_lib, 100 + prev, MTLPixelFormatBGRA8Unorm);
            MTLComputePipelineDescriptor *vc = make_single_compute_desc(base_lib, 100 + prev);
            void *pr = dm_shader_cache_create_render_pso(verify_sc, (__bridge void *)vr, true, err_buf, sizeof(err_buf));
            void *pc = dm_shader_cache_create_compute_pso(verify_sc, (__bridge void *)vc, true, err_buf, sizeof(err_buf));
            DM_CHECK(pr != nullptr && pc != nullptr);
            CFRelease(pr);
            CFRelease(pc);
        }
        dm_shader_cache_close(verify_sc);
    }

    // 2) Concurrent multi-threaded isolated store/flush + shared warm lookups
    dm_shader_cache_t *shared_warm = dm_shader_cache_open(cache_root, "repeat_cycle_v1", err_buf, sizeof(err_buf));
    DM_CHECK(shared_warm != nullptr);

    constexpr int kThreads = 4;
    std::atomic<int> failures{0};
    std::vector<std::thread> threads;
    threads.reserve(kThreads);

    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([dev, cache_root, shared_warm, t, &failures]() {
            @autoreleasepool {
                char terr[256] = {0};
                NSError *lerr = nil;
                id<MTLLibrary> tlib = [dev newLibraryWithSource:kShaderSrc options:nil error:&lerr];
                if (!tlib) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }

                // Concurrent strict lookups against shared warm binary archive
                for (int i = 0; i < 4; ++i) {
                    MTLRenderPipelineDescriptor *sr = make_single_render_desc(tlib, 100 + i, MTLPixelFormatBGRA8Unorm);
                    MTLComputePipelineDescriptor *sc = make_single_compute_desc(tlib, 100 + i);
                    void *pr = dm_shader_cache_create_render_pso(shared_warm, (__bridge void *)sr, true, terr, sizeof(terr));
                    void *pc = dm_shader_cache_create_compute_pso(shared_warm, (__bridge void *)sc, true, terr, sizeof(terr));
                    if (!pr || !pc) {
                        if (pr) CFRelease(pr);
                        if (pc) CFRelease(pc);
                        failures.fetch_add(1, std::memory_order_relaxed);
                        return;
                    }
                    CFRelease(pr);
                    CFRelease(pc);
                }

                // Concurrent per-worker open -> add -> flush -> warm reopen -> strict lookup
                char build_id[32];
                snprintf(build_id, sizeof(build_id), "mt_worker_%d", t);
                dm_shader_cache_t *wc = dm_shader_cache_open(cache_root, build_id, terr, sizeof(terr));
                if (!wc) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }
                MTLRenderPipelineDescriptor *wr = make_single_render_desc(tlib, 200 + t, MTLPixelFormatRGBA8Unorm);
                MTLComputePipelineDescriptor *wcp = make_single_compute_desc(tlib, 200 + t);
                const bool added_r = dm_shader_cache_add_render_pso(wc, (__bridge void *)wr, terr, sizeof(terr));
                const bool added_c = dm_shader_cache_add_compute_pso(wc, (__bridge void *)wcp, terr, sizeof(terr));
                const bool flushed = dm_shader_cache_flush(wc, terr, sizeof(terr));
                dm_shader_cache_close(wc);
                if (!added_r || !added_c || !flushed) {
                    failures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }

                dm_shader_cache_t *wc_warm = dm_shader_cache_open(cache_root, build_id, terr, sizeof(terr));
                if (!wc_warm || !dm_shader_cache_stats(wc_warm).loaded_existing) {
                    if (wc_warm) dm_shader_cache_close(wc_warm);
                    failures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }
                void *wpr = dm_shader_cache_create_render_pso(wc_warm, (__bridge void *)wr, true, terr, sizeof(terr));
                void *wpc = dm_shader_cache_create_compute_pso(wc_warm, (__bridge void *)wcp, true, terr, sizeof(terr));
                dm_shader_cache_close(wc_warm);
                if (!wpr || !wpc) {
                    if (wpr) CFRelease(wpr);
                    if (wpc) CFRelease(wpc);
                    failures.fetch_add(1, std::memory_order_relaxed);
                    return;
                }
                CFRelease(wpr);
                CFRelease(wpc);
            }
        });
    }
    for (auto &th : threads) {
        th.join();
    }
    dm_shader_cache_close(shared_warm);
    DM_CHECK(failures.load(std::memory_order_relaxed) == 0);
}

int main(int argc, char **argv) {
    const char *json_path = nullptr;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--json") == 0 && i + 1 < argc) {
            json_path = argv[++i];
        }
    }

    char tmpl[] = "/tmp/dm_shader_cache_XXXXXX";
    char *cache_root = mkdtemp(tmpl);
    DM_CHECK(cache_root != nullptr);
    TempDirGuard cleanup_guard(cache_root);

    @autoreleasepool {
        // Always verify device-independent NULL/empty/path-traversal & cleanup contracts first
        test_device_independent_contracts(cache_root);

        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) {
            printf("[dm_shader_cache_test] SKIP: MTLCreateSystemDefaultDevice() returned nil; non-GPU checks passed\n");
            return ctest_skip_allowed() ? 77 : 0;
        }
        if (ctest_skip_allowed()) {
            const char *dev_name = dev.name ? dev.name.UTF8String : nullptr;
            if (!dev.hasUnifiedMemory || (dev_name && std::strstr(dev_name, "Paravirtual") != nullptr)) {
                printf("[dm_shader_cache_test] SKIP: no hardware Metal GPU device available\n");
                return 77;
            }
        }

        char err_buf[512] = {0};
        NSError *err = nil;

        // --- Cold Pass ---
        const double cold_t0 = now_ms();
        dm_shader_cache_t *cold_cache = dm_shader_cache_open(cache_root, "demo_v1", err_buf, sizeof(err_buf));
        DM_CHECK(cold_cache != nullptr);
        DM_CHECK(dm_shader_cache_stats(cold_cache).loaded_existing == false);

        id<MTLLibrary> lib1 = [dev newLibraryWithSource:kShaderSrc options:nil error:&err];
        DM_CHECK(lib1 != nil);
        auto r_descs1 = make_render_descs(lib1, &err);   // 16 variants
        auto c_descs1 = make_compute_descs(lib1, &err);  // 8 variants

        for (auto *rpd : r_descs1) {
            void *pso = dm_shader_cache_create_render_pso(cold_cache, (__bridge void *)rpd, false, err_buf, sizeof(err_buf));
            DM_CHECK(pso != nullptr);
            CFRelease(pso);
            DM_CHECK(dm_shader_cache_add_render_pso(cold_cache, (__bridge void *)rpd, err_buf, sizeof(err_buf)));
        }
        for (auto *cpd : c_descs1) {
            void *pso = dm_shader_cache_create_compute_pso(cold_cache, (__bridge void *)cpd, false, err_buf, sizeof(err_buf));
            DM_CHECK(pso != nullptr);
            CFRelease(pso);
            DM_CHECK(dm_shader_cache_add_compute_pso(cold_cache, (__bridge void *)cpd, err_buf, sizeof(err_buf)));
        }
        DM_CHECK(dm_shader_cache_flush(cold_cache, err_buf, sizeof(err_buf)));
        const dm_shader_cache_stats_t cold_stats = dm_shader_cache_stats(cold_cache);
        dm_shader_cache_close(cold_cache);
        const double cold_ms = now_ms() - cold_t0;

        // --- Warm Pass (fresh library + FailOnBinaryArchiveMiss strict enforcement) ---
        const double warm_t0 = now_ms();
        dm_shader_cache_t *warm_cache = dm_shader_cache_open(cache_root, "demo_v1", err_buf, sizeof(err_buf));
        DM_CHECK(warm_cache != nullptr);
        DM_CHECK(dm_shader_cache_stats(warm_cache).loaded_existing == true);

        id<MTLLibrary> lib2 = [dev newLibraryWithSource:kShaderSrc options:nil error:&err];
        DM_CHECK(lib2 != nil);
        auto r_descs2 = make_render_descs(lib2, &err);
        auto c_descs2 = make_compute_descs(lib2, &err);

        uint32_t strict_hits = 0;
        for (auto *rpd : r_descs2) {
            void *pso = dm_shader_cache_create_render_pso(warm_cache, (__bridge void *)rpd, true, err_buf, sizeof(err_buf));
            if (!pso) {
                fprintf(stderr, "Strict render archive miss: %s\n", err_buf);
                dm_shader_cache_close(warm_cache);
                return 1;
            }
            CFRelease(pso);
            ++strict_hits;
        }
        for (auto *cpd : c_descs2) {
            void *pso = dm_shader_cache_create_compute_pso(warm_cache, (__bridge void *)cpd, true, err_buf, sizeof(err_buf));
            if (!pso) {
                fprintf(stderr, "Strict compute archive miss: %s\n", err_buf);
                dm_shader_cache_close(warm_cache);
                return 1;
            }
            CFRelease(pso);
            ++strict_hits;
        }
        dm_shader_cache_close(warm_cache);
        const double warm_ms = now_ms() - warm_t0;

        // --- Key isolation test ---
        dm_shader_cache_t *other_cache = dm_shader_cache_open(cache_root, "demo_v2", err_buf, sizeof(err_buf));
        DM_CHECK(other_cache != nullptr);
        DM_CHECK(dm_shader_cache_stats(other_cache).loaded_existing == false);
        DM_CHECK(std::strcmp(dm_shader_cache_stats(other_cache).cache_key, cold_stats.cache_key) != 0);
        dm_shader_cache_close(other_cache);

        // --- Expanded edge-case, miss/hit, archive corruption & concurrency suites ---
        test_gpu_edge_cases_and_corruption(dev, lib2);
        test_repeated_and_concurrent_store_lookup(dev, cache_root);

        const uint32_t total_psos = (uint32_t)(r_descs2.size() + c_descs2.size());
        DM_CHECK(strict_hits == total_psos);
        const double speedup = warm_ms > 0.0 ? (cold_ms / warm_ms) : 0.0;

        printf("[dm_shader_cache_test] Key: %s | Archive: %llu bytes\n",
               cold_stats.cache_key, (unsigned long long)cold_stats.archive_bytes);
        printf("[dm_shader_cache_test] Strict Archive Hits: %u / %u (100.0%%)\n", strict_hits, total_psos);
        printf("[dm_shader_cache_test] Cold Compile+Serialize: %.2f ms | Warm BinaryArchive Load: %.2f ms (%.2fx)\n",
               cold_ms, warm_ms, speedup);
        printf("[dm_shader_cache_test] PASSED: edge-case, miss/hit, corruption recovery & concurrent cache checks.\n");

        if (json_path) {
            FILE *jf = fopen(json_path, "w");
            DM_CHECK(jf != nullptr);
            fprintf(jf,
                    "{\n"
                    "  \"cache_key\": \"%s\",\n"
                    "  \"pipelines_total\": %u,\n"
                    "  \"strict_archive_hits\": %u,\n"
                    "  \"archive_bytes\": %llu,\n"
                    "  \"cold_compile_ms\": %.3f,\n"
                    "  \"warm_load_ms\": %.3f,\n"
                    "  \"speedup_x\": %.3f\n"
                    "}\n",
                    cold_stats.cache_key,
                    total_psos,
                    strict_hits,
                    (unsigned long long)cold_stats.archive_bytes,
                    cold_ms,
                    warm_ms,
                    speedup);
            fclose(jf);
        }
    }

    return 0;
}
