#define _POSIX_C_SOURCE 200809L
#include "flux_native.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <sys/socket.h>

struct flux_poller {
    int wake[2];
    struct pollfd *fds;
    int64_t *tokens;
    int64_t *ready_tokens;
    int *ready_events;
    size_t count, capacity;
    int ready_count;
};

int64_t flux_monotonic_ms(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) return -1;
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

int flux_nonblocking(int fd) {
    int f = fcntl(fd, F_GETFL);
    if (f < 0 || fcntl(fd, F_SETFL, f | O_NONBLOCK) < 0) return -1;
    f = fcntl(fd, F_GETFD);
    if (f < 0 || fcntl(fd, F_SETFD, f | FD_CLOEXEC) < 0) return -1;
    return 0;
}

static int reserve(flux_poller *p, size_t n) {
    if (n <= p->capacity) return 0;
    if (n > INT_MAX / 2) { errno = ENOMEM; return -1; }
    size_t cap = n < 16 ? 16 : n * 2;
    struct pollfd *fds = calloc(cap, sizeof(*fds));
    int64_t *tokens = calloc(cap, sizeof(*tokens));
    int64_t *ready = calloc(cap, sizeof(*ready));
    int *events = calloc(cap, sizeof(*events));
    if (!fds || !tokens || !ready || !events) {
        free(fds); free(tokens); free(ready); free(events);
        errno = ENOMEM;
        return -1;
    }
    for (size_t i = 0; i < p->count; ++i) {
        fds[i] = p->fds[i]; tokens[i] = p->tokens[i];
    }
    for (int i = 0; i < p->ready_count; ++i) {
        ready[i] = p->ready_tokens[i]; events[i] = p->ready_events[i];
    }
    free(p->fds); free(p->tokens); free(p->ready_tokens); free(p->ready_events);
    p->fds = fds; p->tokens = tokens; p->ready_tokens = ready;
    p->ready_events = events; p->capacity = cap;
    return 0;
}

flux_poller *flux_poller_new(void) {
    flux_poller *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    if (pipe(p->wake)) { free(p); return NULL; }
    if (flux_nonblocking(p->wake[0]) || flux_nonblocking(p->wake[1]) || reserve(p, 1)) {
        close(p->wake[0]); close(p->wake[1]); free(p); return NULL;
    }
    p->fds[0] = (struct pollfd){p->wake[0], POLLIN, 0};
    p->count = 1;
    return p;
}

void flux_poller_free(flux_poller *p) {
    if (!p) return;
    close(p->wake[0]); close(p->wake[1]);
    free(p->fds); free(p->tokens); free(p->ready_tokens); free(p->ready_events);
    free(p);
}

int flux_poller_wake(flux_poller *p) {
    char byte = 1;
    ssize_t n;
    do { n = write(p->wake[1], &byte, 1); } while (n < 0 && errno == EINTR);
    /* A full pipe is already readable. Never block a completion producer. */
    return n == 1 || (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) ? 0 : -1;
}

int flux_poller_add(flux_poller *p, int fd, int events, int64_t token) {
    if (fd < 0 || token <= 0 || events < 1 || events > 3) { errno = EINVAL; return -1; }
    for (size_t i = 1; i < p->count; ++i) {
        short requested = (events & 1 ? POLLIN : 0) | (events & 2 ? POLLOUT : 0);
        if (p->tokens[i] == token || (p->fds[i].fd == fd && (p->fds[i].events & requested))) {
            errno = EEXIST; return -1;
        }
    }
    if (reserve(p, p->count + 1)) return -1;
    short ev = (events & 1 ? POLLIN : 0) | (events & 2 ? POLLOUT : 0);
    p->fds[p->count] = (struct pollfd){fd, ev, 0};
    p->tokens[p->count++] = token;
    return 0;
}

void flux_poller_remove(flux_poller *p, int64_t token) {
    for (size_t i = 1; i < p->count; ++i) {
        if (p->tokens[i] == token) {
            --p->count;
            p->fds[i] = p->fds[p->count]; p->tokens[i] = p->tokens[p->count];
            return;
        }
    }
}

int flux_poller_wait(flux_poller *p, int timeout_ms) {
    if (timeout_ms < -1) { errno = EINVAL; return -1; }
    p->ready_count = 0;
    int64_t deadline = timeout_ms < 0 ? 0 : flux_monotonic_ms() + timeout_ms;
    int remaining = timeout_ms;
    int n;
    for (;;) {
        n = poll(p->fds, p->count, remaining);
        if (n >= 0 || errno != EINTR) break;
        if (timeout_ms >= 0) {
            int64_t delta = deadline - flux_monotonic_ms();
            remaining = delta <= 0 ? 0 : (int)delta;
        }
    }
    if (n <= 0) return n;
    if (p->fds[0].revents & POLLIN) {
        /* Bounded draining: continuous producers must not starve socket IO. */
        char buf[4096];
        for (int i = 0; i < 16; ++i) {
            ssize_t r = read(p->wake[0], buf, sizeof(buf));
            if (r <= 0) break;
        }
    }
    for (size_t i = 1; i < p->count; ++i) {
        short ev = p->fds[i].revents;
        if (!ev) continue;
        int flags = (ev & POLLIN ? 1 : 0) | (ev & POLLOUT ? 2 : 0)
                  | (ev & POLLHUP ? 4 : 0) | (ev & (POLLERR | POLLNVAL) ? 8 : 0);
        int out = p->ready_count++;
        p->ready_tokens[out] = p->tokens[i]; p->ready_events[out] = flags;
    }
    return p->ready_count;
}

int64_t flux_poller_token(flux_poller *p, int index) {
    return index >= 0 && index < p->ready_count ? p->ready_tokens[index] : -1;
}
int flux_poller_events(flux_poller *p, int index) {
    return index >= 0 && index < p->ready_count ? p->ready_events[index] : 0;
}

int flux_socket_would_block(int result) {
    return result == -EAGAIN || result == -EWOULDBLOCK;
}

static int prepare_socket(int fd) {
    if (flux_nonblocking(fd)) return -errno;
#ifdef SO_NOSIGPIPE
    int enabled = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled))) return -errno;
#endif
    return 0;
}

int flux_socket_listen(const char *host, int port, int backlog) {
    if (port < 0 || port > 65535 || backlog < 1) return -EINVAL;
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) return -EINVAL;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -errno;
    int enabled = 1;
    int err = prepare_socket(fd);
    if (!err && setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled))) err = -errno;
    if (!err && bind(fd, (struct sockaddr *)&addr, sizeof(addr))) err = -errno;
    if (!err && listen(fd, backlog)) err = -errno;
    if (err) { close(fd); return err; }
    return fd;
}

int flux_socket_accept(int fd) {
    int client;
    do { client = accept(fd, NULL, NULL); } while (client < 0 && errno == EINTR);
    if (client < 0) return -errno;
    int err = prepare_socket(client);
    int enabled = 1;
    if (!err && setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &enabled, sizeof(enabled))) err = -errno;
    if (err) { close(client); return err; }
    return client;
}

int flux_socket_port(int fd) {
    struct sockaddr_in addr;
    socklen_t size = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &size)) return -errno;
    return ntohs(addr.sin_port);
}

int flux_socket_recv(int fd, unsigned char *buffer, int size) {
    if (size < 1) return -EINVAL;
    ssize_t n;
    do { n = recv(fd, buffer, (size_t)size, 0); } while (n < 0 && errno == EINTR);
    return n < 0 ? -errno : (int)n;
}

int flux_socket_send(int fd, const unsigned char *buffer, int offset, int size) {
    if (offset < 0 || size < 0) return -EINVAL;
    int flags = 0;
#ifdef MSG_NOSIGNAL
    flags = MSG_NOSIGNAL;
#endif
    ssize_t n;
    do { n = send(fd, buffer + offset, (size_t)size, flags); } while (n < 0 && errno == EINTR);
    return n < 0 ? -errno : (int)n;
}

int flux_socket_close(int fd) {
    /* Never retry close after EINTR: the descriptor may already be released. */
    return close(fd) < 0 ? -errno : 0;
}

/* Standalone runner only: explicit opt-in process signal supervision.
 * No Idris callback, runtime mutex, or owner-loop progress is needed to enforce
 * the outer shutdown deadline. Embedders use the task-level stop API instead. */
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "signal flags must be lock-free");
static atomic_int shutdown_requested;
static atomic_int watchdog_stop;
static pthread_mutex_t watchdog_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_t watchdog_thread;
static int watchdog_active;
static int watchdog_timeout;
static struct sigaction previous_int, previous_term;

static void shutdown_signal(int signo) {
    (void)signo;
    atomic_store_explicit(&shutdown_requested, 1, memory_order_relaxed);
}

static void *watch_shutdown(void *unused) {
    (void)unused;
    int64_t deadline = -1;
    while (!atomic_load_explicit(&watchdog_stop, memory_order_relaxed)) {
        if (atomic_load_explicit(&shutdown_requested, memory_order_relaxed)) {
            int64_t now = flux_monotonic_ms();
            if (deadline < 0) deadline = now + watchdog_timeout;
            if (now >= deadline) _exit(124);
        }
        struct timespec pause = {0, 10000000};
        nanosleep(&pause, NULL);
    }
    return NULL;
}

int flux_shutdown_start(int timeout_ms) {
    if (timeout_ms <= 0) return -EINVAL;
    pthread_mutex_lock(&watchdog_lock);
    if (watchdog_active) {
        pthread_mutex_unlock(&watchdog_lock);
        return -EBUSY;
    }
    atomic_store(&shutdown_requested, 0);
    atomic_store(&watchdog_stop, 0);
    watchdog_timeout = timeout_ms;
    struct sigaction action = {0};
    action.sa_handler = shutdown_signal;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESTART;
    if (sigaction(SIGINT, &action, &previous_int)) {
        int err = errno;
        pthread_mutex_unlock(&watchdog_lock);
        return -err;
    }
    if (sigaction(SIGTERM, &action, &previous_term)) {
        int err = errno;
        sigaction(SIGINT, &previous_int, NULL);
        pthread_mutex_unlock(&watchdog_lock);
        return -err;
    }
    int err = pthread_create(&watchdog_thread, NULL, watch_shutdown, NULL);
    if (err) {
        sigaction(SIGINT, &previous_int, NULL);
        sigaction(SIGTERM, &previous_term, NULL);
        pthread_mutex_unlock(&watchdog_lock);
        return -err;
    }
    watchdog_active = 1;
    pthread_mutex_unlock(&watchdog_lock);
    return 0;
}

int flux_shutdown_requested(void) {
    return atomic_load_explicit(&shutdown_requested, memory_order_relaxed);
}

void flux_shutdown_stop(void) {
    pthread_mutex_lock(&watchdog_lock);
    if (watchdog_active) {
        atomic_store(&watchdog_stop, 1);
        pthread_join(watchdog_thread, NULL);
        sigaction(SIGINT, &previous_int, NULL);
        sigaction(SIGTERM, &previous_term, NULL);
        watchdog_active = 0;
    }
    pthread_mutex_unlock(&watchdog_lock);
}
