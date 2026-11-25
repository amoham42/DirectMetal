#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dm_shader_cache dm_shader_cache_t;

typedef struct dm_shader_cache_stats {
    char cache_key[192];
    char archive_path[1024];
    char manifest_path[1024];
    uint32_t pipelines_cached;
    uint64_t archive_bytes;
    bool loaded_existing;
} dm_shader_cache_stats_t;

dm_shader_cache_t *dm_shader_cache_open(const char *cache_root,
                                        const char *game_build_id,
                                        char *err_buf,
                                        size_t err_cap);
void dm_shader_cache_close(dm_shader_cache_t *cache);

bool dm_shader_cache_add_render_pso(dm_shader_cache_t *cache,
                                    void *mtl_render_pipeline_desc,
                                    char *err_buf,
                                    size_t err_cap);
bool dm_shader_cache_add_compute_pso(dm_shader_cache_t *cache,
                                     void *mtl_compute_pipeline_desc,
                                     char *err_buf,
                                     size_t err_cap);

bool dm_shader_cache_flush(dm_shader_cache_t *cache, char *err_buf, size_t err_cap);

void *dm_shader_cache_create_render_pso(dm_shader_cache_t *cache,
                                        void *mtl_render_pipeline_desc,
                                        bool strict_archive_only,
                                        char *err_buf,
                                        size_t err_cap);
void *dm_shader_cache_create_compute_pso(dm_shader_cache_t *cache,
                                         void *mtl_compute_pipeline_desc,
                                         bool strict_archive_only,
                                         char *err_buf,
                                         size_t err_cap);

dm_shader_cache_stats_t dm_shader_cache_stats(const dm_shader_cache_t *cache);

#ifdef __cplusplus
}
#endif
