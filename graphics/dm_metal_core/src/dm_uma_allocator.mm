#include "dm_uma_allocator.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstdlib>
#include <cstring>
#include <vector>

static constexpr size_t kAppleSiliconPageSize = 16384;

static size_t align_up(size_t val, size_t align) {
    if (align == 0) return val;
    return (val + align - 1) & ~(align - 1);
}

struct dm_uma_ring {
    id<MTLDevice> device;
    id<MTLBuffer> buffer;
    uint8_t *base_ptr;
    size_t capacity;
    size_t cursor;
    dm_uma_heap_kind_t kind;
    dm_uma_telemetry_t telemetry;
};

dm_uma_ring_t *dm_uma_ring_create(size_t capacity_bytes, dm_uma_heap_kind_t kind) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev || capacity_bytes == 0) return nullptr;

        const size_t aligned_cap = align_up(capacity_bytes, kAppleSiliconPageSize);
        void *raw_mem = nullptr;
        if (posix_memalign(&raw_mem, kAppleSiliconPageSize, aligned_cap) != 0 || !raw_mem) {
            return nullptr;
        }
        memset(raw_mem, 0, aligned_cap);

        MTLResourceOptions opts = MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked;
        id<MTLBuffer> buf = [dev newBufferWithBytesNoCopy:raw_mem
                                                   length:aligned_cap
                                                  options:opts
                                              deallocator:^(void *pointer, NSUInteger) {
                                                  free(pointer);
                                              }];
        if (!buf) {
            free(raw_mem);
            return nullptr;
        }

        auto *ring = new dm_uma_ring();
        ring->device = dev;
        ring->buffer = buf;
        ring->base_ptr = static_cast<uint8_t *>(raw_mem);
        ring->capacity = aligned_cap;
        ring->cursor = 0;
        ring->kind = kind;
        memset(&ring->telemetry, 0, sizeof(ring->telemetry));
        ring->telemetry.bytes_pooled_capacity = aligned_cap;
        ring->telemetry.zero_copy_mappings = 1;
        return ring;
    }
}

void dm_uma_ring_destroy(dm_uma_ring_t *ring) {
    if (!ring) return;
    @autoreleasepool {
        ring->buffer = nil;
        ring->device = nil;
    }
    delete ring;
}

bool dm_uma_ring_alloc(dm_uma_ring_t *ring, size_t size_bytes, size_t alignment, dm_uma_slice_t *out_slice) {
    if (!ring || !out_slice || size_bytes == 0) return false;
    const size_t eff_align = alignment < 256 ? 256 : alignment;
    const size_t off = align_up(ring->cursor, eff_align);
    if (off + size_bytes > ring->capacity) {
        return false;
    }
    out_slice->cpu_ptr = ring->base_ptr + off;
    out_slice->metal_buffer_bridge = (__bridge void *)ring->buffer;
    out_slice->offset = off;
    out_slice->size = size_bytes;

    ring->cursor = off + size_bytes;
    ring->telemetry.bytes_allocated += size_bytes;
    // On discrete PCIe GPUs, each CPU->Shared->VRAM upload or readback duplicates memory
    ring->telemetry.bytes_saved_vs_discrete += size_bytes;
    ring->telemetry.alloc_count += 1;
    return true;
}

void dm_uma_ring_reset(dm_uma_ring_t *ring) {
    if (!ring) return;
    ring->cursor = 0;
}

void *dm_uma_ring_metal_buffer(dm_uma_ring_t *ring) {
    if (!ring) return nullptr;
    return (__bridge void *)ring->buffer;
}

dm_uma_telemetry_t dm_uma_ring_telemetry(const dm_uma_ring_t *ring) {
    dm_uma_telemetry_t empty{};
    return ring ? ring->telemetry : empty;
}

struct dm_uma_pool {
    id<MTLDevice> device;
    id<MTLHeap> heap;
    NSMutableArray<id<MTLBuffer>> *free_list;
    NSMutableArray<id<MTLBuffer>> *in_use;
    dm_uma_heap_kind_t kind;
    dm_uma_telemetry_t telemetry;
};

dm_uma_pool_t *dm_uma_pool_create(size_t heap_size_bytes, dm_uma_heap_kind_t kind) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev || heap_size_bytes == 0) return nullptr;

        const size_t aligned_heap = align_up(heap_size_bytes, kAppleSiliconPageSize);
        MTLHeapDescriptor *hd = [MTLHeapDescriptor new];
        hd.size = aligned_heap;
        hd.storageMode = MTLStorageModeShared;
        hd.cpuCacheMode = MTLCPUCacheModeDefaultCache;
        hd.hazardTrackingMode = MTLHazardTrackingModeUntracked;
        hd.type = MTLHeapTypeAutomatic;

        id<MTLHeap> heap = [dev newHeapWithDescriptor:hd];
        if (!heap) return nullptr;

        auto *pool = new dm_uma_pool();
        pool->device = dev;
        pool->heap = heap;
        pool->free_list = [NSMutableArray new];
        pool->in_use = [NSMutableArray new];
        pool->kind = kind;
        memset(&pool->telemetry, 0, sizeof(pool->telemetry));
        pool->telemetry.bytes_pooled_capacity = heap.size;
        return pool;
    }
}

void dm_uma_pool_destroy(dm_uma_pool_t *pool) {
    if (!pool) return;
    @autoreleasepool {
        [pool->free_list removeAllObjects];
        [pool->in_use removeAllObjects];
        pool->free_list = nil;
        pool->in_use = nil;
        pool->heap = nil;
        pool->device = nil;
    }
    delete pool;
}

void *dm_uma_pool_acquire_buffer(dm_uma_pool_t *pool, size_t size_bytes, void **out_cpu_ptr) {
    if (!pool || size_bytes == 0) return nullptr;
    @autoreleasepool {
        id<MTLBuffer> chosen = nil;
        NSUInteger chosen_idx = NSNotFound;
        for (NSUInteger i = 0; i < pool->free_list.count; ++i) {
            id<MTLBuffer> cand = pool->free_list[i];
            if (cand.length >= size_bytes) {
                chosen = cand;
                chosen_idx = i;
                break;
            }
        }
        if (chosen != nil) {
            [pool->free_list removeObjectAtIndex:chosen_idx];
            pool->telemetry.reuse_hits += 1;
        } else {
            MTLResourceOptions opts = MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked;
            chosen = [pool->heap newBufferWithLength:align_up(size_bytes, 256) options:opts];
            if (!chosen) return nullptr;
            pool->telemetry.bytes_allocated += chosen.length;
        }
        [pool->in_use addObject:chosen];
        pool->telemetry.alloc_count += 1;
        pool->telemetry.bytes_saved_vs_discrete += size_bytes;
        if (out_cpu_ptr) *out_cpu_ptr = chosen.contents;
        return (__bridge void *)chosen;
    }
}

void dm_uma_pool_recycle_buffer(dm_uma_pool_t *pool, void *metal_buffer_bridge) {
    if (!pool || !metal_buffer_bridge) return;
    @autoreleasepool {
        id<MTLBuffer> buf = (__bridge id<MTLBuffer>)metal_buffer_bridge;
        NSUInteger idx = [pool->in_use indexOfObjectIdenticalTo:buf];
        if (idx != NSNotFound) {
            [pool->in_use removeObjectAtIndex:idx];
            [pool->free_list addObject:buf];
        }
    }
}

dm_uma_telemetry_t dm_uma_pool_telemetry(const dm_uma_pool_t *pool) {
    dm_uma_telemetry_t empty{};
    return pool ? pool->telemetry : empty;
}
