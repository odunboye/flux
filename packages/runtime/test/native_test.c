#define _POSIX_C_SOURCE 200809L
#include "flux_native.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static void *wake_thread(void *arg) {
    struct timespec delay = {0, 10000000};
    nanosleep(&delay, NULL);
    assert(flux_poller_wake(arg) == 0);
    return NULL;
}

int main(void) {
    flux_poller *p = flux_poller_new();
    assert(p);
    int fds[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
    assert(flux_nonblocking(fds[0]) == 0);
    assert(flux_nonblocking(fds[1]) == 0);
    assert(flux_poller_add(p, fds[0], 1, 1) == 0);
    assert(flux_poller_add(p, fds[0], 1, 2) == -1);
    assert(flux_poller_wait(p, 0) == 0);
    assert(write(fds[1], "x", 1) == 1);
    assert(flux_poller_wait(p, 100) == 1);
    assert(flux_poller_token(p, 0) == 1);
    assert(flux_poller_events(p, 0) & 1);
    flux_poller_remove(p, 1);
    assert(flux_poller_wait(p, 0) == 0);
    assert(flux_poller_add(p, fds[0], 1, 2) == 0);
    assert(flux_poller_wait(p, 0) == 1);
    assert(flux_poller_token(p, 0) == 2);
    char byte;
    assert(read(fds[0], &byte, 1) == 1);
    /* Waking repeatedly must saturate/coalesce without blocking. */
    for (int i = 0; i < 100000; ++i) assert(flux_poller_wake(p) == 0);
    assert(flux_poller_wait(p, 0) == 0);
    pthread_t thread;
    assert(pthread_create(&thread, NULL, wake_thread, p) == 0);
    int64_t before = flux_monotonic_ms();
    assert(flux_poller_wait(p, 1000) == 0);
    assert(flux_monotonic_ms() - before < 500);
    assert(pthread_join(thread, NULL) == 0);
    close(fds[1]);
    assert(flux_poller_wait(p, 100) == 1);
    assert(flux_poller_events(p, 0) & (1 | 4));
    flux_poller_remove(p, 2);
    close(fds[0]);
    flux_poller_free(p);
    puts("PASS native readiness, registration tokens, EOF, wake saturation, cross-thread wake");
    return 0;
}
