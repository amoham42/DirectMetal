#include "dm_metal_core.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DM_CHECK(expr)                                                                 \
    do {                                                                               \
        if (!(expr)) {                                                                 \
            fprintf(stderr, "[dm_metal_probe] CHECK FAILED (%s:%d): %s\n",             \
                    __FILE__, __LINE__, #expr);                                        \
            return 1;                                                                  \
        }                                                                              \
    } while (0)

static bool ctest_skip_allowed(void) {
    const char *v = getenv("DM_CTEST_ALLOW_SKIP");
    return v && v[0] && strcmp(v, "0") != 0;
}

int main(void) {
    dm_metal_device_info_t info;
    if (!dm_metal_query_device(&info)) {
        if (ctest_skip_allowed()) {
            printf("[dm_metal_probe] SKIP: no Metal device available in headless environment\n");
            return 77;
        }
        fprintf(stderr, "[dm_metal_probe] FAIL: dm_metal_query_device returned false\n");
        return 1;
    }

    printf("[dm_metal_probe] GPU: %s\n", info.gpu_name);
    printf("[dm_metal_probe] Family: %s | Metal3: %s | Metal4: %s\n",
           info.gpu_family,
           info.supports_metal3 ? "yes" : "no",
           info.supports_metal4 ? "yes" : "no");
    printf("[dm_metal_probe] Unified Memory: %s | Max Working Set: %.2f GiB\n",
           info.has_unified_memory ? "yes" : "no",
           (double)info.recommended_working_set_bytes / (1024.0 * 1024.0 * 1024.0));
    printf("[dm_metal_probe] macOS: %s (%s) | Cache Key: %s\n",
           info.macos_version, info.macos_build, info.cache_key);
    printf("[dm_metal_probe] Raytracing: %s | Barycentrics: %s\n",
           info.supports_raytracing ? "yes" : "no",
           info.supports_barycentrics ? "yes" : "no");

    if ((!info.has_unified_memory || !info.supports_metal3) && ctest_skip_allowed()) {
        printf("[dm_metal_probe] SKIP: paravirtualized GPU lacks Apple Silicon UMA/Metal3\n");
        return 77;
    }

    DM_CHECK(info.has_unified_memory);
    DM_CHECK(info.supports_metal3);

    char err[256] = {0};
    if (!dm_metal_run_smoke_test(err, sizeof(err))) {
        fprintf(stderr, "Metal smoke test failed: %s\n", err);
        return 1;
    }
    printf("[dm_metal_probe] Native Metal UMA compute + render smoke test PASSED\n");
    return 0;
}
