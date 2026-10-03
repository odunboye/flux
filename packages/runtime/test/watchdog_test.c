#define _POSIX_C_SOURCE 200809L
#include "flux_native.h"
#include <assert.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdio.h>

int main(void) {
    assert(flux_shutdown_start(1000) == 0);
    assert(flux_shutdown_start(1000) < 0);
    raise(SIGTERM);
    assert(flux_shutdown_requested());
    flux_shutdown_stop();
    assert(flux_shutdown_start(1000) == 0);
    assert(!flux_shutdown_requested());
    flux_shutdown_stop();
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        assert(flux_shutdown_start(50) == 0);
        raise(SIGINT);
        for (;;) pause();
    }
    int status = 0;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 124);
    puts("PASS standalone signal lifecycle and independent forced exit");
    return 0;
}
