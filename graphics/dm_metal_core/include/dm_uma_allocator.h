#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum dm_uma_heap_kind {
    DM_UMA_HEAP_UPLOAD = 0,
    DM_UMA_HEAP_READBACK = 1,
    DM_UMA_HEAP_DYNAMIC_CB = 2,
    DM_UMA_HEAP_DEFAULT_SHARED = 3,
} dm_uma_heap_kind_t;

typedef struct dm_uma_telemetry {
    uint64_t bytes_allocated;
    uint64_t bytes_pooled_capacity;
    uint64_t bytes_saved_vs_discrete;
    uint64_t alloc_count;
    uint64_t reuse_hits;
    uint64_t zero_copy_mappings;
} dm_uma_telemetry_t;

typedef struct dm_uma_ring dm_uma_ring_t;
typedef struct dm_uma_pool dm_uma_pool_t;

typedef struct dm_uma_slice {
    void *cpu_ptr;
    void *metal_buffer_bridge;  // __unsafe_unretained id<MTLBuffer>
    size_t offset;
    size_t size;
} dm_uma_slice_t;

dm_uma_ring_t *dm_uma_ring_create(size_t capacity_bytes, dm_uma_heap_kind_t kind);
void dm_uma_ring_destroy(dm_uma_ring_t *ring);
bool dm_uma_ring_alloc(dm_uma_ring_t *ring, size_t size_bytes, size_t alignment, dm_uma_slice_t *out_slice);
void dm_uma_ring_reset(dm_uma_ring_t *ring);
void *dm_uma_ring_metal_buffer(dm_uma_ring_t *ring);
dm_uma_telemetry_t dm_uma_ring_telemetry(const dm_uma_ring_t *ring);

dm_uma_pool_t *dm_uma_pool_create(size_t heap_size_bytes, dm_uma_heap_kind_t kind);
void dm_uma_pool_destroy(dm_uma_pool_t *pool);
void *dm_uma_pool_acquire_buffer(dm_uma_pool_t *pool, size_t size_bytes, void **out_cpu_ptr);
void dm_uma_pool_recycle_buffer(dm_uma_pool_t *pool, void *metal_buffer_bridge);
dm_uma_telemetry_t dm_uma_pool_telemetry(const dm_uma_pool_t *pool);

#ifdef __cplusplus
}
#endif
