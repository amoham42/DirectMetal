#pragma once

#include <os/lock.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DM_SYNC_INFINITE UINT64_MAX
#define DM_MAX_WAIT_OBSERVERS 16

typedef enum dm_wait_status {
    DM_WAIT_OBJECT_0 = 0,
    DM_WAIT_TIMEOUT = 1,
    DM_WAIT_ERROR = -1,
} dm_wait_status_t;

typedef enum dm_waitable_kind {
    DM_WAITABLE_EVENT = 1,
    DM_WAITABLE_SEMAPHORE = 2,
} dm_waitable_kind_t;

typedef struct dm_waitable_header {
    dm_waitable_kind_t kind;
    os_unfair_lock observer_lock;
    atomic_uint *observers[DM_MAX_WAIT_OBSERVERS];
    size_t observer_count;
} dm_waitable_header_t;

typedef struct dm_nt_event {
    dm_waitable_header_t header;
    atomic_uint state;
    bool manual_reset;
} dm_nt_event_t;

typedef struct dm_nt_semaphore {
    dm_waitable_header_t header;
    atomic_uint count;
    uint32_t max_count;
} dm_nt_semaphore_t;

int dm_futex_wait(atomic_uint *addr, uint32_t expected, uint64_t timeout_ns);
int dm_futex_wake_one(atomic_uint *addr);
int dm_futex_wake_all(atomic_uint *addr);

void dm_nt_event_init(dm_nt_event_t *ev, bool manual_reset, bool initial_state);
void dm_nt_event_set(dm_nt_event_t *ev);
void dm_nt_event_reset(dm_nt_event_t *ev);
dm_wait_status_t dm_nt_event_wait(dm_nt_event_t *ev, uint64_t timeout_ns);

void dm_nt_semaphore_init(dm_nt_semaphore_t *sem, uint32_t initial_count, uint32_t max_count);
bool dm_nt_semaphore_release(dm_nt_semaphore_t *sem, uint32_t release_count, uint32_t *prev_count);
dm_wait_status_t dm_nt_semaphore_wait(dm_nt_semaphore_t *sem, uint64_t timeout_ns);

dm_wait_status_t dm_nt_wait_multiple(dm_waitable_header_t *const *objs,
                                     size_t count,
                                     bool wait_all,
                                     uint64_t timeout_ns,
                                     size_t *out_index);

#ifdef __cplusplus
}
#endif
