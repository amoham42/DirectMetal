#include "dm_metal_core.h"

#include <assert.h>
#include <stdio.h>

int main(void) {
    dm_metal_device_info_t info;
    assert(dm_metal_query_device(&info));

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

    assert(info.has_unified_memory);
    assert(info.supports_metal3);

    char err[256] = {0};
    if (!dm_metal_run_smoke_test(err, sizeof(err))) {
        fprintf(stderr, "Metal smoke test failed: %s\n", err);
        return 1;
    }
    printf("[dm_metal_probe] Native Metal UMA compute + render smoke test PASSED\n");
    return 0;
}
