#include "dm_shader_cache.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <time.h>
#include <unistd.h>
#include <vector>

#define DM_CHECK(expr)                                                                 \
    do {                                                                               \
        if (!(expr)) {                                                                 \
            fprintf(stderr, "[dm_shader_cache_test] CHECK FAILED (%s:%d): %s\n",       \
                    __FILE__, __LINE__, #expr);                                        \
            std::exit(1);                                                              \
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
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (ctest_skip_allowed()) {
            const char *dev_name = (dev && dev.name) ? dev.name.UTF8String : nullptr;
            if (!dev || !dev.hasUnifiedMemory || (dev_name && std::strstr(dev_name, "Paravirtual") != nullptr)) {
                printf("[dm_shader_cache_test] SKIP: no hardware Metal GPU device available\n");
                return 77;
            }
        }
        DM_CHECK(dev != nil);

        char err_buf[512] = {0};
        NSError *err = nil;

        // Edge-case checks: reject invalid inputs cleanly
        DM_CHECK(dm_shader_cache_open(nullptr, "demo_v1", err_buf, sizeof(err_buf)) == nullptr);
        DM_CHECK(dm_shader_cache_open(cache_root, "../escape", err_buf, sizeof(err_buf)) == nullptr);

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

        const uint32_t total_psos = (uint32_t)(r_descs2.size() + c_descs2.size());
        DM_CHECK(strict_hits == total_psos);
        const double speedup = warm_ms > 0.0 ? (cold_ms / warm_ms) : 0.0;

        printf("[dm_shader_cache_test] Key: %s | Archive: %llu bytes\n",
               cold_stats.cache_key, (unsigned long long)cold_stats.archive_bytes);
        printf("[dm_shader_cache_test] Strict Archive Hits: %u / %u (100.0%%)\n", strict_hits, total_psos);
        printf("[dm_shader_cache_test] Cold Compile+Serialize: %.2f ms | Warm BinaryArchive Load: %.2f ms (%.2fx)\n",
               cold_ms, warm_ms, speedup);

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
