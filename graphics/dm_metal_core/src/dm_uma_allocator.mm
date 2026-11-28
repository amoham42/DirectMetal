#include "dm_uma_allocator.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <new>

static constexpr size_t kAppleSiliconPageSize = 16384;
static constexpr size_t kMetalBufferOffsetAlign = 256;

static bool align_up_checked(size_t val, size_t align, size_t *out) {
    if (!out) return false;
    if (align <= 1) {
        *out = val;
        return true;
    }
    const size_t rem = val % align;
    if (rem == 0) {
        *out = val;
        return true;
    }
    const size_t add = align - rem;
    if (val > SIZE_MAX - add) {
        return false;
    }
    *out = val + add;
    return true;
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

        size_t aligned_cap = 0;
        if (!align_up_checked(capacity_bytes, kAppleSiliconPageSize, &aligned_cap)) {
            return nullptr;
        }

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

        auto *ring = new (std::nothrow) dm_uma_ring();
        if (!ring) {
            return nullptr;  // buf deallocator frees raw_mem on scope exit
        }
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
    if (out_slice) {
        memset(out_slice, 0, sizeof(*out_slice));
    }
    if (!ring || !out_slice || size_bytes == 0) return false;

    size_t eff_align = kMetalBufferOffsetAlign;
    if (alignment > kMetalBufferOffsetAlign) {
        if (!align_up_checked(alignment, kMetalBufferOffsetAlign, &eff_align)) {
            return false;
        }
    }

    size_t off = 0;
    if (!align_up_checked(ring->cursor, eff_align, &off)) {
        return false;
    }
    if (off > ring->capacity || size_bytes > ring->capacity - off) {
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

        size_t aligned_heap = 0;
        if (!align_up_checked(heap_size_bytes, kAppleSiliconPageSize, &aligned_heap)) {
            return nullptr;
        }

        MTLHeapDescriptor *hd = [MTLHeapDescriptor new];
        if (!hd) return nullptr;
        hd.size = aligned_heap;
        hd.storageMode = MTLStorageModeShared;
        hd.cpuCacheMode = MTLCPUCacheModeDefaultCache;
        hd.hazardTrackingMode = MTLHazardTrackingModeUntracked;
        hd.type = MTLHeapTypeAutomatic;

        id<MTLHeap> heap = [dev newHeapWithDescriptor:hd];
        if (!heap) return nullptr;

        auto *pool = new (std::nothrow) dm_uma_pool();
        if (!pool) return nullptr;
        pool->device = dev;
        pool->heap = heap;
        pool->free_list = [NSMutableArray new];
        pool->in_use = [NSMutableArray new];
        if (!pool->free_list || !pool->in_use) {
            delete pool;
            return nullptr;
        }
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
    if (out_cpu_ptr) {
        *out_cpu_ptr = nullptr;
    }
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
            size_t aligned_len = 0;
            if (!align_up_checked(size_bytes, kMetalBufferOffsetAlign, &aligned_len)) {
                return nullptr;
            }
            MTLResourceOptions opts = MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked;
            chosen = [pool->heap newBufferWithLength:aligned_len options:opts];
            if (!chosen || !chosen.contents) return nullptr;
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
