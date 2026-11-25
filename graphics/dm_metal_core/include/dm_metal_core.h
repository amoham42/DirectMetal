#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dm_metal_device_info {
    char gpu_name[256];
    char gpu_family[64];
    char macos_version[64];
    char macos_build[64];
    char cache_key[160];
    uint64_t recommended_working_set_bytes;
    uint64_t max_buffer_length;
    uint64_t registry_id;
    bool has_unified_memory;
    bool supports_metal3;
    bool supports_metal4;
    bool supports_raytracing;
    bool supports_barycentrics;
} dm_metal_device_info_t;

bool dm_metal_query_device(dm_metal_device_info_t *out);
bool dm_metal_run_smoke_test(char *error_buf, size_t error_cap);

#ifdef __cplusplus
}
#endif
