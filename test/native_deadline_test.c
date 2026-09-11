#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
int64_t pg_deadline_push(int);
void pg_deadline_restore(int64_t);
int pg_deadline_expired(void);
int pg_socket_receive(int, unsigned char *, int);
int pg_socket_send(int, const unsigned char *, int);
static int64_t now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
int main(void) {
    int sockets[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    unsigned char bytes[4] = {0, 255, 128, 1}, result[4];
    int64_t previous = pg_deadline_push(1000);
    assert(pg_socket_send(sockets[0], bytes, 4) == 4);
    assert(pg_socket_receive(sockets[1], result, 4) == 4);
    for (int i = 0; i < 4; ++i) assert(bytes[i] == result[i]);
    int64_t outer = pg_deadline_push(30);
    int64_t inner = pg_deadline_push(5000);
    int64_t start = now();
    assert(pg_socket_receive(sockets[0], result, 4) == -ETIMEDOUT);
    assert(now() - start >= 20 && now() - start < 1000);
    assert(pg_deadline_expired());
    pg_deadline_restore(inner);
    pg_deadline_restore(outer);
    assert(!pg_deadline_expired());
    close(sockets[1]);
    assert(pg_socket_send(sockets[0], bytes, 4) < 0);
    close(sockets[0]);
    pg_deadline_restore(previous);
    puts("PASS native PG bytes, deadlines, nested deadline precedence, and closed-peer send");
    return 0;
}
