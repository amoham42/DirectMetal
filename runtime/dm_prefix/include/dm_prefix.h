#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dm_prefix_result {
    bool ok;
    double elapsed_ms;
    int err_no;
    char error_msg[256];
} dm_prefix_result_t;

dm_prefix_result_t dm_prefix_create(const char *base_prefix,
                                    const char *dest_prefix,
                                    const char *game_exe,
                                    const char *dx_api,
                                    const char *shader_key);

dm_prefix_result_t dm_prefix_delete(const char *prefix_path);

dm_prefix_result_t dm_prefix_reset(const char *base_prefix,
                                   const char *dest_prefix,
                                   const char *game_exe,
                                   const char *dx_api,
                                   const char *shader_key);

int dm_prefix_list(const char *prefix_root,
                   char names_out[][256],
                   size_t max_names,
                   size_t *out_count);

#ifdef __cplusplus
}
#endif
