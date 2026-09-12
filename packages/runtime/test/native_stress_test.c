#define _POSIX_C_SOURCE 200809L
#include "flux_native.h"
#include <assert.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
static atomic_int stop;
static pthread_t owner;
static void noop(int s) { (void)s; }
static void *interrupts(void *unused) {
 (void)unused;
 struct timespec d={0,1000000};
 while (!atomic_load(&stop)) { pthread_kill(owner,SIGUSR1); nanosleep(&d,0); }
 return 0;
}
static void *wakeups(void *p) {
 while (!atomic_load(&stop)) assert(flux_poller_wake(p)==0);
 return 0;
}
int main(void) {
 struct sigaction action={0}; action.sa_handler=noop; sigemptyset(&action.sa_mask);
 assert(sigaction(SIGUSR1,&action,0)==0);
 owner=pthread_self();
 flux_poller *p=flux_poller_new(); assert(p);
 pthread_t thread;
 assert(pthread_create(&thread,0,interrupts,0)==0);
 int64_t start=flux_monotonic_ms();
 assert(flux_poller_wait(p,50)==0);
 int64_t elapsed=flux_monotonic_ms()-start;
 assert(elapsed>=45 && elapsed<500);
 atomic_store(&stop,1); pthread_join(thread,0);
 printf("PASS interrupted poll retains deadline (%lld ms)\n",(long long)elapsed);
 atomic_store(&stop,0);
 pthread_t writers[4];
 for (int i=0;i<4;i++) assert(pthread_create(&writers[i],0,wakeups,p)==0);
 int fds[2]; assert(socketpair(AF_UNIX,SOCK_STREAM,0,fds)==0);
 assert(flux_nonblocking(fds[0])==0);
 for (int64_t token=1;token<=5000;token++) {
  assert(flux_poller_add(p,fds[0],1,token)==0);
  assert(write(fds[1],"x",1)==1);
  int found=0;
  for(int j=0;j<100 && !found;j++) {
   int n=flux_poller_wait(p,10); assert(n>=0);
   for(int k=0;k<n;k++) if(flux_poller_token(p,k)==token) found=1;
  }
  assert(found);
  char c; assert(read(fds[0],&c,1)==1);
  flux_poller_remove(p,token);
 }
 atomic_store(&stop,1);
 for(int i=0;i<4;i++) pthread_join(writers[i],0);
 close(fds[0]);close(fds[1]);flux_poller_free(p);
 puts("PASS 5000 registrations under four continuous wake producers");
}
