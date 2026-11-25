#include "dm_sync.h"

#include <errno.h>
#include <os/clock.h>
#include <os/os_sync_wait_on_address.h>
#include <time.h>

static uint64_t monotonic_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_UPTIME_RAW, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void notify_observers(dm_waitable_header_t *hdr) {
    os_unfair_lock_lock(&hdr->observer_lock);
    for (size_t i = 0; i < hdr->observer_count; ++i) {
        atomic_uint *seq = hdr->observers[i];
        if (seq) {
            atomic_fetch_add_explicit(seq, 1u, memory_order_release);
            os_sync_wake_by_address_all(seq, sizeof(uint32_t), OS_SYNC_WAKE_BY_ADDRESS_NONE);
        }
    }
    os_unfair_lock_unlock(&hdr->observer_lock);
}

static bool register_observer(dm_waitable_header_t *hdr, atomic_uint *seq) {
    os_unfair_lock_lock(&hdr->observer_lock);
    for (size_t i = 0; i < hdr->observer_count; ++i) {
        if (hdr->observers[i] == seq) {
            os_unfair_lock_unlock(&hdr->observer_lock);
            return true;
        }
    }
    if (hdr->observer_count >= DM_MAX_WAIT_OBSERVERS) {
        os_unfair_lock_unlock(&hdr->observer_lock);
        return false;
    }
    hdr->observers[hdr->observer_count++] = seq;
    os_unfair_lock_unlock(&hdr->observer_lock);
    return true;
}

static void unregister_observer(dm_waitable_header_t *hdr, atomic_uint *seq) {
    os_unfair_lock_lock(&hdr->observer_lock);
    for (size_t i = 0; i < hdr->observer_count; ++i) {
        if (hdr->observers[i] == seq) {
            hdr->observers[i] = hdr->observers[hdr->observer_count - 1];
            hdr->observers[hdr->observer_count - 1] = NULL;
            hdr->observer_count--;
            break;
        }
    }
    os_unfair_lock_unlock(&hdr->observer_lock);
}

int dm_futex_wait(atomic_uint *addr, uint32_t expected, uint64_t timeout_ns) {
    if (!addr) {
        errno = EINVAL;
        return -1;
    }
    if (atomic_load_explicit(addr, memory_order_acquire) != expected) {
        return 0;
    }
    if (timeout_ns == 0) {
        errno = ETIMEDOUT;
        return -1;
    }
    int rc;
    do {
        if (timeout_ns == DM_SYNC_INFINITE) {
            rc = os_sync_wait_on_address(addr, expected, sizeof(uint32_t),
                                         OS_SYNC_WAIT_ON_ADDRESS_NONE);
        } else {
            rc = os_sync_wait_on_address_with_timeout(
                addr, expected, sizeof(uint32_t), OS_SYNC_WAIT_ON_ADDRESS_NONE,
                OS_CLOCK_MACH_ABSOLUTE_TIME, timeout_ns);
        }
    } while (rc < 0 && (errno == EINTR || errno == EFAULT) &&
             atomic_load_explicit(addr, memory_order_acquire) == expected);

    return (rc < 0) ? -1 : 0;
}

int dm_futex_wake_one(atomic_uint *addr) {
    if (!addr) {
        errno = EINVAL;
        return -1;
    }
    return os_sync_wake_by_address_any(addr, sizeof(uint32_t), OS_SYNC_WAKE_BY_ADDRESS_NONE);
}

int dm_futex_wake_all(atomic_uint *addr) {
    if (!addr) {
        errno = EINVAL;
        return -1;
    }
    return os_sync_wake_by_address_all(addr, sizeof(uint32_t), OS_SYNC_WAKE_BY_ADDRESS_NONE);
}

void dm_nt_event_init(dm_nt_event_t *ev, bool manual_reset, bool initial_state) {
    ev->header.kind = DM_WAITABLE_EVENT;
    ev->header.observer_lock = OS_UNFAIR_LOCK_INIT;
    ev->header.observer_count = 0;
    for (size_t i = 0; i < DM_MAX_WAIT_OBSERVERS; ++i) ev->header.observers[i] = NULL;
    ev->manual_reset = manual_reset;
    atomic_init(&ev->state, initial_state ? 1u : 0u);
}

void dm_nt_event_set(dm_nt_event_t *ev) {
    atomic_store_explicit(&ev->state, 1u, memory_order_release);
    if (ev->manual_reset) {
        dm_futex_wake_all(&ev->state);
    } else {
        dm_futex_wake_one(&ev->state);
    }
    notify_observers(&ev->header);
}

void dm_nt_event_reset(dm_nt_event_t *ev) {
    atomic_store_explicit(&ev->state, 0u, memory_order_release);
}

static bool try_acquire_event(dm_nt_event_t *ev) {
    if (ev->manual_reset) {
        return atomic_load_explicit(&ev->state, memory_order_acquire) != 0u;
    }
    uint32_t expected = 1u;
    return atomic_compare_exchange_strong_explicit(
        &ev->state, &expected, 0u, memory_order_acq_rel, memory_order_acquire);
}

dm_wait_status_t dm_nt_event_wait(dm_nt_event_t *ev, uint64_t timeout_ns) {
    if (!ev) return DM_WAIT_ERROR;
    const uint64_t start_ns = (timeout_ns != DM_SYNC_INFINITE && timeout_ns > 0) ? monotonic_now_ns() : 0;

    for (;;) {
        if (try_acquire_event(ev)) {
            return DM_WAIT_OBJECT_0;
        }
        if (timeout_ns == 0) {
            return DM_WAIT_TIMEOUT;
        }
        uint64_t rem_ns = DM_SYNC_INFINITE;
        if (timeout_ns != DM_SYNC_INFINITE) {
            const uint64_t elapsed = monotonic_now_ns() - start_ns;
            if (elapsed >= timeout_ns) return DM_WAIT_TIMEOUT;
            rem_ns = timeout_ns - elapsed;
        }
        if (dm_futex_wait(&ev->state, 0u, rem_ns) < 0 && errno == ETIMEDOUT) {
            return try_acquire_event(ev) ? DM_WAIT_OBJECT_0 : DM_WAIT_TIMEOUT;
        }
    }
}

void dm_nt_semaphore_init(dm_nt_semaphore_t *sem, uint32_t initial_count, uint32_t max_count) {
    sem->header.kind = DM_WAITABLE_SEMAPHORE;
    sem->header.observer_lock = OS_UNFAIR_LOCK_INIT;
    sem->header.observer_count = 0;
    for (size_t i = 0; i < DM_MAX_WAIT_OBSERVERS; ++i) sem->header.observers[i] = NULL;
    sem->max_count = max_count == 0 ? 1u : max_count;
    atomic_init(&sem->count, initial_count > sem->max_count ? sem->max_count : initial_count);
}

bool dm_nt_semaphore_release(dm_nt_semaphore_t *sem, uint32_t release_count, uint32_t *prev_count) {
    if (!sem || release_count == 0) return false;
    uint32_t cur = atomic_load_explicit(&sem->count, memory_order_acquire);
    for (;;) {
        if (release_count > sem->max_count || cur > sem->max_count - release_count) {
            return false;
        }
        const uint32_t next = cur + release_count;
        if (atomic_compare_exchange_weak_explicit(
                &sem->count, &cur, next, memory_order_acq_rel, memory_order_acquire)) {
            if (prev_count) *prev_count = cur;
            if (release_count == 1) {
                dm_futex_wake_one(&sem->count);
            } else {
                dm_futex_wake_all(&sem->count);
            }
            notify_observers(&sem->header);
            return true;
        }
    }
}

static bool try_acquire_semaphore(dm_nt_semaphore_t *sem) {
    uint32_t cur = atomic_load_explicit(&sem->count, memory_order_acquire);
    while (cur > 0u) {
        if (atomic_compare_exchange_weak_explicit(
                &sem->count, &cur, cur - 1u, memory_order_acq_rel, memory_order_acquire)) {
            return true;
        }
    }
    return false;
}

dm_wait_status_t dm_nt_semaphore_wait(dm_nt_semaphore_t *sem, uint64_t timeout_ns) {
    if (!sem) return DM_WAIT_ERROR;
    const uint64_t start_ns = (timeout_ns != DM_SYNC_INFINITE && timeout_ns > 0) ? monotonic_now_ns() : 0;

    for (;;) {
        if (try_acquire_semaphore(sem)) {
            return DM_WAIT_OBJECT_0;
        }
        if (timeout_ns == 0) {
            return DM_WAIT_TIMEOUT;
        }
        uint64_t rem_ns = DM_SYNC_INFINITE;
        if (timeout_ns != DM_SYNC_INFINITE) {
            const uint64_t elapsed = monotonic_now_ns() - start_ns;
            if (elapsed >= timeout_ns) return DM_WAIT_TIMEOUT;
            rem_ns = timeout_ns - elapsed;
        }
        if (dm_futex_wait(&sem->count, 0u, rem_ns) < 0 && errno == ETIMEDOUT) {
            return try_acquire_semaphore(sem) ? DM_WAIT_OBJECT_0 : DM_WAIT_TIMEOUT;
        }
    }
}

static bool is_signaled_peek(dm_waitable_header_t *hdr) {
    if (hdr->kind == DM_WAITABLE_EVENT) {
        dm_nt_event_t *ev = (dm_nt_event_t *)hdr;
        return atomic_load_explicit(&ev->state, memory_order_acquire) != 0u;
    }
    dm_nt_semaphore_t *sem = (dm_nt_semaphore_t *)hdr;
    return atomic_load_explicit(&sem->count, memory_order_acquire) > 0u;
}

static bool try_acquire_obj(dm_waitable_header_t *hdr) {
    if (hdr->kind == DM_WAITABLE_EVENT) {
        return try_acquire_event((dm_nt_event_t *)hdr);
    }
    return try_acquire_semaphore((dm_nt_semaphore_t *)hdr);
}

static void rollback_obj(dm_waitable_header_t *hdr) {
    if (hdr->kind == DM_WAITABLE_EVENT) {
        dm_nt_event_t *ev = (dm_nt_event_t *)hdr;
        if (!ev->manual_reset) {
            dm_nt_event_set(ev);
        }
    } else {
        dm_nt_semaphore_release((dm_nt_semaphore_t *)hdr, 1u, NULL);
    }
}

dm_wait_status_t dm_nt_wait_multiple(dm_waitable_header_t *const *objs,
                                     size_t count,
                                     bool wait_all,
                                     uint64_t timeout_ns,
                                     size_t *out_index) {
    if (!objs || count == 0 || count > 64) return DM_WAIT_ERROR;

    atomic_uint local_seq = 0;
    for (size_t i = 0; i < count; ++i) {
        if (!objs[i] || !register_observer(objs[i], &local_seq)) {
            for (size_t j = 0; j < i; ++j) unregister_observer(objs[j], &local_seq);
            return DM_WAIT_ERROR;
        }
    }

    const uint64_t start_ns = (timeout_ns != DM_SYNC_INFINITE && timeout_ns > 0) ? monotonic_now_ns() : 0;
    dm_wait_status_t result = DM_WAIT_TIMEOUT;

    for (;;) {
        const uint32_t observed_seq = atomic_load_explicit(&local_seq, memory_order_acquire);

        if (!wait_all) {
            for (size_t i = 0; i < count; ++i) {
                if (try_acquire_obj(objs[i])) {
                    if (out_index) *out_index = i;
                    result = DM_WAIT_OBJECT_0;
                    goto done;
                }
            }
        } else {
            bool all_peek = true;
            for (size_t i = 0; i < count; ++i) {
                if (!is_signaled_peek(objs[i])) {
                    all_peek = false;
                    break;
                }
            }
            if (all_peek) {
                size_t acquired = 0;
                for (; acquired < count; ++acquired) {
                    if (!try_acquire_obj(objs[acquired])) break;
                }
                if (acquired == count) {
                    if (out_index) *out_index = 0;
                    result = DM_WAIT_OBJECT_0;
                    goto done;
                }
                for (size_t j = 0; j < acquired; ++j) {
                    rollback_obj(objs[j]);
                }
            }
        }

        if (timeout_ns == 0) {
            result = DM_WAIT_TIMEOUT;
            goto done;
        }

        uint64_t rem_ns = DM_SYNC_INFINITE;
        if (timeout_ns != DM_SYNC_INFINITE) {
            const uint64_t elapsed = monotonic_now_ns() - start_ns;
            if (elapsed >= timeout_ns) {
                result = DM_WAIT_TIMEOUT;
                goto done;
            }
            rem_ns = timeout_ns - elapsed;
        }

        if (dm_futex_wait(&local_seq, observed_seq, rem_ns) < 0 && errno == ETIMEDOUT) {
            // Re-check once after timeout in case signal raced before sleep
            if (!wait_all) {
                for (size_t i = 0; i < count; ++i) {
                    if (try_acquire_obj(objs[i])) {
                        if (out_index) *out_index = i;
                        result = DM_WAIT_OBJECT_0;
                        goto done;
                    }
                }
            }
            result = DM_WAIT_TIMEOUT;
            goto done;
        }
    }

done:
    for (size_t i = 0; i < count; ++i) {
        unregister_observer(objs[i], &local_seq);
    }
    return result;
}
