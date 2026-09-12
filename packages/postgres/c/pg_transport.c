#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <netdb.h>
#include <poll.h>
#include <stdio.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

/* A deadline belongs to one synchronous callback, which never migrates OS
 * threads. Nested operations inherit the earlier deadline. No helper thread
 * owns or continues a query after its caller returns. */
static _Thread_local int64_t deadline_ms = -1;
static int64_t monotonic_ms(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) return 0;
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
int64_t pg_deadline_push(int milliseconds) {
    int64_t old = deadline_ms;
    int64_t next = monotonic_ms() + milliseconds;
    if (old < 0 || next < old) deadline_ms = next;
    return old;
}
void pg_deadline_restore(int64_t previous) { deadline_ms = previous; }
int pg_deadline_expired(void) {
    return deadline_ms >= 0 && monotonic_ms() >= deadline_ms;
}
static int prepare(int fd) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK)) return -errno;
    flags = fcntl(fd, F_GETFD);
    if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC)) return -errno;
#ifdef SO_NOSIGPIPE
    int yes = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes))) return -errno;
#endif
    return 0;
}
static int wait_fd(int fd, short events) {
    for (;;) {
        int timeout = -1;
        if (deadline_ms >= 0) {
            int64_t remaining = deadline_ms - monotonic_ms();
            if (remaining <= 0) return -ETIMEDOUT;
            timeout = remaining > INT_MAX ? INT_MAX : (int)remaining;
        }
        struct pollfd p = {fd, events, 0};
        int n = poll(&p, 1, timeout);
        if (n > 0) return (p.revents & POLLNVAL) ? -EBADF : 0;
        if (n == 0) return -ETIMEDOUT;
        if (errno != EINTR) return -errno;
    }
}
int pg_socket_connect(int fd, const char *host, int port) {
    if (port < 1 || port > 65535) return -EINVAL;
    int rc = prepare(fd);
    if (rc) return rc;
    struct addrinfo hints = {0}, *addresses = NULL;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    char service[6];
    snprintf(service, sizeof(service), "%d", port);
    /* Resolver execution is synchronous and is retained by its worker. */
    if (getaddrinfo(host, service, &hints, &addresses)) return -EHOSTUNREACH;
    if (pg_deadline_expired()) { freeaddrinfo(addresses); return -ETIMEDOUT; }
    rc = connect(fd, addresses->ai_addr, addresses->ai_addrlen);
    int err = errno;
    freeaddrinfo(addresses);
    if (rc == 0) return 0;
    if (err != EINPROGRESS && err != EINTR) return -err;
    rc = wait_fd(fd, POLLOUT);
    if (rc) return rc;
    socklen_t size = sizeof(err);
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &size)) return -errno;
    return -err;
}
int pg_socket_receive(int fd, unsigned char *buffer, int size) {
    if (size <= 0) return -EINVAL;
    int rc = prepare(fd);
    if (rc) return rc;
    for (;;) {
        if (pg_deadline_expired()) return -ETIMEDOUT;
        ssize_t n = recv(fd, buffer, (size_t)size, 0);
        if (n >= 0) return (int)n;
        if (errno == EINTR) continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK) return -errno;
        rc = wait_fd(fd, POLLIN);
        if (rc) return rc;
    }
}
int pg_socket_send(int fd, const unsigned char *buffer, int size) {
    if (size <= 0) return -EINVAL;
    int rc = prepare(fd);
    if (rc) return rc;
    for (;;) {
        if (pg_deadline_expired()) return -ETIMEDOUT;
#ifdef MSG_NOSIGNAL
        ssize_t n = send(fd, buffer, (size_t)size, MSG_NOSIGNAL);
#else
        ssize_t n = send(fd, buffer, (size_t)size, 0);
#endif
        if (n >= 0) return (int)n;
        if (errno == EINTR) continue;
        if (errno != EAGAIN && errno != EWOULDBLOCK) return -errno;
        rc = wait_fd(fd, POLLOUT);
        if (rc) return rc;
    }
}

/* Copy managed strings before entering a collect-safe, potentially blocking
 * foreign call. Chez does not permit string arguments on those calls. */
#include <stdlib.h>
#include <string.h>
char *pg_copy_host(const char *host) { return strdup(host); }
void pg_free_host(char *host) { free(host); }
