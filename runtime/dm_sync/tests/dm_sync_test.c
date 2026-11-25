#include "dm_sync.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
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
    assert(dm_nt_semaphore_release(&sem, 2, &prev) && prev == 0);
    assert(!dm_nt_semaphore_release(&sem, 2, NULL));  // exceeds max_count=3
    assert(dm_nt_semaphore_wait(&sem, 0) == DM_WAIT_OBJECT_0);
    assert(dm_nt_semaphore_wait(&sem, 0) == DM_WAIT_OBJECT_0);
    assert(dm_nt_semaphore_wait(&sem, 0) == DM_WAIT_TIMEOUT);
    printf("[dm_sync_test] semaphore OK\n");
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
    printf("[dm_sync_test] wait_multiple OK\n");
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
    test_events();
    test_semaphore();
    test_wait_multiple();

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
