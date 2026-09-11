#ifndef FLUX_NATIVE_H
#define FLUX_NATIVE_H
#include <stdint.h>
#include <stddef.h>

/* All poller operations except wake belong to one event-loop thread.
 * Destruction requires all wake producers to have stopped. The poller owns
 * its wake pipe only; socket descriptors remain owned by their Idris scope. */
typedef struct flux_poller flux_poller;
flux_poller *flux_poller_new(void);
void flux_poller_free(flux_poller *p);
int flux_poller_wake(flux_poller *p);
int flux_poller_add(flux_poller *p, int fd, int events, int64_t token);
void flux_poller_remove(flux_poller *p, int64_t token);
int flux_poller_wait(flux_poller *p, int timeout_ms);
int64_t flux_poller_token(flux_poller *p, int index);
int flux_poller_events(flux_poller *p, int index);
int64_t flux_monotonic_ms(void);
int flux_nonblocking(int fd);
int flux_socket_listen(const char *host, int port, int backlog);
int flux_socket_accept(int fd);
int flux_socket_port(int fd);
int flux_socket_recv(int fd, unsigned char *buffer, int size);
int flux_socket_send(int fd, const unsigned char *buffer, int offset, int size);
int flux_socket_close(int fd);
int flux_socket_would_block(int result);
int flux_shutdown_start(int timeout_ms);
int flux_shutdown_requested(void);
void flux_shutdown_stop(void);
#endif
