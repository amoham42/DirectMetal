#include "dm_sync.h"

#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static uint64_t uptime_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_UPTIME_RAW, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void test_null_safety(void) {
    errno = 0;
    assert(dm_futex_wait(NULL, 0, 0) == -1 && errno == EINVAL);
    errno = 0;
    assert(dm_futex_wake_one(NULL) == -1 && errno == EINVAL);
    errno = 0;
    assert(dm_futex_wake_all(NULL) == -1 && errno == EINVAL);

    // Event null pointer guards
    dm_nt_event_init(NULL, false, false);
    dm_nt_event_init(NULL, true, true);
    dm_nt_event_set(NULL);
    dm_nt_event_reset(NULL);
    assert(dm_nt_event_wait(NULL, 0) == DM_WAIT_ERROR);
    assert(dm_nt_event_wait(NULL, 5000000ULL) == DM_WAIT_ERROR);
    assert(dm_nt_event_wait(NULL, DM_SYNC_INFINITE) == DM_WAIT_ERROR);

    // Semaphore null pointer guards
    dm_nt_semaphore_init(NULL, 1, 2);
    uint32_t prev = 77;
    assert(!dm_nt_semaphore_release(NULL, 1, &prev) && prev == 77);
    assert(!dm_nt_semaphore_release(NULL, 1, NULL));
    assert(dm_nt_semaphore_wait(NULL, 0) == DM_WAIT_ERROR);
    assert(dm_nt_semaphore_wait(NULL, 5000000ULL) == DM_WAIT_ERROR);
    assert(dm_nt_semaphore_wait(NULL, DM_SYNC_INFINITE) == DM_WAIT_ERROR);

    // Wait-multiple null pointer guards
    size_t idx = 42;
    assert(dm_nt_wait_multiple(NULL, 1, false, 0, &idx) == DM_WAIT_ERROR && idx == 42);
    printf("[dm_sync_test] null safety OK\n");
}

static void test_events(void) {
    dm_nt_event_t auto_ev;
    dm_nt_event_init(&auto_ev, false, false);
    assert(dm_nt_event_wait(&auto_ev, 0) == DM_WAIT_TIMEOUT);
    dm_nt_event_set(&auto_ev);
    assert(dm_nt_event_wait(&auto_ev, 0) == DM_WAIT_OBJECT_0);
    assert(dm_nt_event_wait(&auto_ev, 0) == DM_WAIT_TIMEOUT);  // auto-reset consumed

    dm_nt_event_t manual_ev;
    dm_nt_event_init(&manual_ev, true, false);
    dm_nt_event_set(&manual_ev);
    assert(dm_nt_event_wait(&manual_ev, 0) == DM_WAIT_OBJECT_0);
    assert(dm_nt_event_wait(&manual_ev, 0) == DM_WAIT_OBJECT_0);
    dm_nt_event_reset(&manual_ev);
    assert(dm_nt_event_wait(&manual_ev, 5000000ULL) == DM_WAIT_TIMEOUT);  // 5ms timeout
    printf("[dm_sync_test] events OK\n");
}

static void test_semaphore(void) {
    dm_nt_semaphore_t sem;
    dm_nt_semaphore_init(&sem, 1, 3);
    assert(dm_nt_semaphore_wait(&sem, 0) == DM_WAIT_OBJECT_0);
    assert(dm_nt_semaphore_wait(&sem, 0) == DM_WAIT_TIMEOUT);

    uint32_t prev = 99;
    assert(!dm_nt_semaphore_release(&sem, 0, &prev) && prev == 99);  // zero release rejected
    assert(dm_nt_semaphore_release(&sem, 1, &prev) && prev == 0);
    assert(dm_nt_semaphore_release(&sem, 2, &prev) && prev == 1);    // count now 3 == max_count
    prev = 55;
    assert(!dm_nt_semaphore_release(&sem, 1, &prev) && prev == 55);  // exceeds max_count=3
    assert(!dm_nt_semaphore_release(&sem, 4, NULL));                 // release_count > max_count
    assert(dm_nt_semaphore_wait(&sem, 0) == DM_WAIT_OBJECT_0);
    assert(dm_nt_semaphore_wait(&sem, 0) == DM_WAIT_OBJECT_0);
    assert(dm_nt_semaphore_wait(&sem, 0) == DM_WAIT_OBJECT_0);
    assert(dm_nt_semaphore_wait(&sem, 0) == DM_WAIT_TIMEOUT);

    // Clamping: max_count=0 clamps to 1, initial_count > max_count clamps to max_count
    dm_nt_semaphore_t clamped;
    dm_nt_semaphore_init(&clamped, 5, 0);
    assert(dm_nt_semaphore_wait(&clamped, 0) == DM_WAIT_OBJECT_0);
    assert(dm_nt_semaphore_wait(&clamped, 0) == DM_WAIT_TIMEOUT);
    assert(!dm_nt_semaphore_release(&clamped, 2, NULL));
    assert(dm_nt_semaphore_release(&clamped, 1, &prev) && prev == 0);

    // UINT32_MAX overflow / wraparound protection
    dm_nt_semaphore_t max_sem;
    dm_nt_semaphore_init(&max_sem, UINT32_MAX - 1u, UINT32_MAX);
    prev = 123u;
    assert(!dm_nt_semaphore_release(&max_sem, 2u, &prev) && prev == 123u);
    assert(!dm_nt_semaphore_release(&max_sem, UINT32_MAX, &prev) && prev == 123u);
    assert(dm_nt_semaphore_release(&max_sem, 1u, &prev) && prev == UINT32_MAX - 1u);
    assert(!dm_nt_semaphore_release(&max_sem, 1u, &prev));
    assert(dm_nt_semaphore_wait(&max_sem, 0) == DM_WAIT_OBJECT_0);
    printf("[dm_sync_test] semaphore & overflow guards OK\n");
}

typedef struct multi_ctx {
    dm_nt_event_t *ev0;
    dm_nt_event_t *ev1;
} multi_ctx_t;

static void *signal_delayed_worker(void *arg) {
    multi_ctx_t *c = (multi_ctx_t *)arg;
    struct timespec ts = {0, 4000000};
    nanosleep(&ts, NULL);
    dm_nt_event_set(c->ev1);
    return NULL;
}

static void test_wait_multiple(void) {
    dm_nt_event_t ev0, ev1;
    dm_nt_event_init(&ev0, false, false);
    dm_nt_event_init(&ev1, false, false);
    dm_waitable_header_t *objs[2] = {&ev0.header, &ev1.header};

    // Validation: count == 0 and count > 64
    assert(dm_nt_wait_multiple(objs, 0, false, 0, NULL) == DM_WAIT_ERROR);
    dm_waitable_header_t *too_many[65] = {0};
    for (size_t i = 0; i < 65; ++i) too_many[i] = &ev0.header;
    assert(dm_nt_wait_multiple(too_many, 65, false, 0, NULL) == DM_WAIT_ERROR);

    // Validation: NULL handle entry
    dm_waitable_header_t *null_slot[2] = {&ev0.header, NULL};
    assert(dm_nt_wait_multiple(null_slot, 2, false, 0, NULL) == DM_WAIT_ERROR);

    // Validation: duplicate waitable handles must fail without consuming state
    dm_nt_event_set(&ev0);
    dm_waitable_header_t *dup_objs[2] = {&ev0.header, &ev0.header};
    assert(dm_nt_wait_multiple(dup_objs, 2, false, 0, NULL) == DM_WAIT_ERROR);
    assert(dm_nt_wait_multiple(dup_objs, 2, true, 0, NULL) == DM_WAIT_ERROR);
    dm_waitable_header_t *dup_nonadj[3] = {&ev0.header, &ev1.header, &ev0.header};
    assert(dm_nt_wait_multiple(dup_nonadj, 3, false, 0, NULL) == DM_WAIT_ERROR);
    assert(dm_nt_event_wait(&ev0, 0) == DM_WAIT_OBJECT_0);  // ev0 remained unconsumed

    // Validation: invalid waitable kind
    dm_waitable_header_t bad_zero;
    memset(&bad_zero, 0, sizeof(bad_zero));
    bad_zero.kind = (dm_waitable_kind_t)0;
    dm_waitable_header_t *bad_objs0[2] = {&ev0.header, &bad_zero};
    assert(dm_nt_wait_multiple(bad_objs0, 2, false, 0, NULL) == DM_WAIT_ERROR);

    dm_waitable_header_t bad_kind;
    memset(&bad_kind, 0, sizeof(bad_kind));
    bad_kind.kind = (dm_waitable_kind_t)99;
    dm_waitable_header_t *bad_objs99[2] = {&bad_kind, &ev1.header};
    assert(dm_nt_wait_multiple(bad_objs99, 2, true, 0, NULL) == DM_WAIT_ERROR);

    multi_ctx_t ctx = {&ev0, &ev1};
    pthread_t th;
    pthread_create(&th, NULL, signal_delayed_worker, &ctx);

    size_t idx = 999;
    assert(dm_nt_wait_multiple(objs, 2, false, 1000000000ULL, &idx) == DM_WAIT_OBJECT_0);
    assert(idx == 1);
    pthread_join(th, NULL);

    // Test wait_all
    dm_nt_event_set(&ev0);
    assert(dm_nt_wait_multiple(objs, 2, true, 5000000ULL, NULL) == DM_WAIT_TIMEOUT);
    // ev0 must NOT have been consumed when wait_all timed out!
    assert(dm_nt_event_wait(&ev0, 0) == DM_WAIT_OBJECT_0);

    dm_nt_event_set(&ev0);
    dm_nt_event_set(&ev1);
    assert(dm_nt_wait_multiple(objs, 2, true, 5000000ULL, NULL) == DM_WAIT_OBJECT_0);
    printf("[dm_sync_test] wait_multiple & handle validation OK\n");
}

static volatile sig_atomic_t g_sigusr1_hits = 0;

static void sigusr1_test_handler(int sig) {
    (void)sig;
    ++g_sigusr1_hits;
}

typedef struct eintr_worker_ctx {
    pthread_t target_thread;
    atomic_bool ready;
    atomic_bool done;
} eintr_worker_ctx_t;

static void *sigusr1_interrupter_thread(void *arg) {
    eintr_worker_ctx_t *ctx = (eintr_worker_ctx_t *)arg;
    while (!atomic_load_explicit(&ctx->ready, memory_order_acquire) &&
           !atomic_load_explicit(&ctx->done, memory_order_acquire)) {
        struct timespec spin_ts = {0, 500000};  // 0.5 ms
        nanosleep(&spin_ts, NULL);
    }
    for (int i = 0; i < 3; ++i) {
        struct timespec ts = {0, 8000000};  // 8 ms between signals
        nanosleep(&ts, NULL);
        if (atomic_load_explicit(&ctx->done, memory_order_acquire)) {
            break;
        }
        pthread_kill(ctx->target_thread, SIGUSR1);
    }
    return NULL;
}

static void test_sigusr1_eintr_timed_wait(void) {
    struct sigaction sa;
    struct sigaction old_sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = sigusr1_test_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;  // Deliberately omit SA_RESTART so kernel wait sees EINTR
    assert(sigaction(SIGUSR1, &sa, &old_sa) == 0);

    g_sigusr1_hits = 0;
    dm_nt_event_t ev;
    dm_nt_event_init(&ev, false, false);

    eintr_worker_ctx_t ctx;
    ctx.target_thread = pthread_self();
    atomic_init(&ctx.ready, false);
    atomic_init(&ctx.done, false);

    pthread_t sig_th;
    assert(pthread_create(&sig_th, NULL, sigusr1_interrupter_thread, &ctx) == 0);

    const uint64_t timeout_ns = 50000000ULL;  // 50 ms
    const uint64_t t0 = uptime_ns();
    atomic_store_explicit(&ctx.ready, true, memory_order_release);
    const dm_wait_status_t status = dm_nt_event_wait(&ev, timeout_ns);
    const uint64_t elapsed_ns = uptime_ns() - t0;
    atomic_store_explicit(&ctx.done, true, memory_order_release);

    pthread_join(sig_th, NULL);
    assert(sigaction(SIGUSR1, &old_sa, NULL) == 0);

    assert(status == DM_WAIT_TIMEOUT);
    assert(g_sigusr1_hits >= 1);
    // Must complete near the 50ms deadline (neither aborting at 8ms nor looping indefinitely)
    assert(elapsed_ns >= 45000000ULL && elapsed_ns < 500000000ULL);
    printf("[dm_sync_test] SIGUSR1 EINTR timed wait OK (%d signals, %.2f ms)\n",
           (int)g_sigusr1_hits, (double)elapsed_ns / 1000000.0);
}

// --- 100,000 ping-pong benchmark ---
enum { kPingPongIters = 100000 };

typedef struct dm_bench_state {
    dm_nt_event_t ping;
    dm_nt_event_t pong;
} dm_bench_state_t;

static void *dm_pong_thread(void *arg) {
    dm_bench_state_t *s = (dm_bench_state_t *)arg;
    for (int i = 0; i < kPingPongIters; ++i) {
        dm_nt_event_wait(&s->ping, DM_SYNC_INFINITE);
        dm_nt_event_set(&s->pong);
    }
    return NULL;
}

typedef struct cond_bench_state {
    pthread_mutex_t mu;
    pthread_cond_t cv;
    int turn;
} cond_bench_state_t;

static void *cond_pong_thread(void *arg) {
    cond_bench_state_t *s = (cond_bench_state_t *)arg;
    pthread_mutex_lock(&s->mu);
    for (int i = 0; i < kPingPongIters; ++i) {
        while (s->turn != 1) pthread_cond_wait(&s->cv, &s->mu);
        s->turn = 0;
        pthread_cond_signal(&s->cv);
    }
    pthread_mutex_unlock(&s->mu);
    return NULL;
}

typedef struct pipe_bench_state {
    int p2c[2];
    int c2p[2];
} pipe_bench_state_t;

static void *pipe_pong_thread(void *arg) {
    pipe_bench_state_t *s = (pipe_bench_state_t *)arg;
    char b = 0;
    for (int i = 0; i < kPingPongIters; ++i) {
        if (read(s->p2c[0], &b, 1) != 1) abort();
        if (write(s->c2p[1], &b, 1) != 1) abort();
    }
    return NULL;
}

int main(void) {
    test_null_safety();
    test_events();
    test_semaphore();
    test_wait_multiple();
    test_sigusr1_eintr_timed_wait();

    // 1. os_sync_wait_on_address ping-pong
    dm_bench_state_t dms;
    dm_nt_event_init(&dms.ping, false, false);
    dm_nt_event_init(&dms.pong, false, false);
    pthread_t th_dm;
    pthread_create(&th_dm, NULL, dm_pong_thread, &dms);
    const uint64_t t0 = now_ns();
    for (int i = 0; i < kPingPongIters; ++i) {
        dm_nt_event_set(&dms.ping);
        dm_nt_event_wait(&dms.pong, DM_SYNC_INFINITE);
    }
    const uint64_t t1 = now_ns();
    pthread_join(th_dm, NULL);
    const double dm_us = (double)(t1 - t0) / 1000.0;
    const double dm_per_op_us = dm_us / (2.0 * kPingPongIters);

    // 2. pthread_cond ping-pong
    cond_bench_state_t cs = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0};
    pthread_t th_cond;
    pthread_create(&th_cond, NULL, cond_pong_thread, &cs);
    const uint64_t c0 = now_ns();
    pthread_mutex_lock(&cs.mu);
    for (int i = 0; i < kPingPongIters; ++i) {
        cs.turn = 1;
        pthread_cond_signal(&cs.cv);
        while (cs.turn != 0) pthread_cond_wait(&cs.cv, &cs.mu);
    }
    pthread_mutex_unlock(&cs.mu);
    const uint64_t c1 = now_ns();
    pthread_join(th_cond, NULL);
    const double cond_us = (double)(c1 - c0) / 1000.0;
    const double cond_per_op_us = cond_us / (2.0 * kPingPongIters);

    // 3. Unix pipe (wineserver IPC baseline) ping-pong
    pipe_bench_state_t ps;
    assert(pipe(ps.p2c) == 0 && pipe(ps.c2p) == 0);
    pthread_t th_pipe;
    pthread_create(&th_pipe, NULL, pipe_pong_thread, &ps);
    const uint64_t p0 = now_ns();
    char b = 1;
    for (int i = 0; i < kPingPongIters; ++i) {
        if (write(ps.p2c[1], &b, 1) != 1) abort();
        if (read(ps.c2p[0], &b, 1) != 1) abort();
    }
    const uint64_t p1 = now_ns();
    pthread_join(th_pipe, NULL);
    close(ps.p2c[0]); close(ps.p2c[1]);
    close(ps.c2p[0]); close(ps.c2p[1]);
    const double pipe_us = (double)(p1 - p0) / 1000.0;
    const double pipe_per_op_us = pipe_us / (2.0 * kPingPongIters);

    printf("[dm_sync_bench] 100k ping-pong (200k wakeups):\n");
    printf("  os_sync_wait_on_address : %.2f ms total | %.3f us/wakeup\n", dm_us / 1000.0, dm_per_op_us);
    printf("  pthread_cond            : %.2f ms total | %.3f us/wakeup (%.2fx vs os_sync)\n",
           cond_us / 1000.0, cond_per_op_us, cond_per_op_us / dm_per_op_us);
    printf("  unix pipe (IPC baseline): %.2f ms total | %.3f us/wakeup (%.2fx vs os_sync)\n",
           pipe_us / 1000.0, pipe_per_op_us, pipe_per_op_us / dm_per_op_us);
    return 0;
}
