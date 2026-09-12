#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

extern void *flux_auth_begin(const char *, const char *, int);
extern int flux_auth_run(void *);
extern const char *flux_auth_hash(void *);
extern void flux_auth_end(void *);
extern void *flux_auth_token(void);
extern void *flux_auth_digest(const char *);
extern const char *flux_auth_string(void *);
extern void flux_auth_free_string(void *);

int main(void) {
    const char *pw = "correct horse battery staple";
    void *a = flux_auth_begin(pw, "", 0), *b = flux_auth_begin(pw, "", 0);
    assert(a && b && !flux_auth_begin(pw, "", 0));
    assert(flux_auth_run(a) == 1 && flux_auth_run(b) == 1);
    char hash[128]; strcpy(hash, flux_auth_hash(a));
    assert(strncmp(hash, "$argon2id$v=19$m=65536,t=3,p=1$", strlen("$argon2id$v=19$m=65536,t=3,p=1$")) == 0);
    assert(strcmp(hash, flux_auth_hash(b)) != 0);
    flux_auth_end(a); flux_auth_end(b);
    a = flux_auth_begin(pw, hash, 1); assert(a && flux_auth_run(a) == 1); flux_auth_end(a);
    a = flux_auth_begin("wrong password", hash, 1); assert(a && flux_auth_run(a) == 0); flux_auth_end(a);
    a = flux_auth_begin(pw, "$argon2id$v=19$m=999999999,t=99,p=1$invalid", 1);
    assert(a && flux_auth_run(a) == -1); flux_auth_end(a);
    void *token = flux_auth_token(), *other = flux_auth_token();
    assert(token && other && strlen(flux_auth_string(token)) == 43);
    assert(strcmp(flux_auth_string(token), flux_auth_string(other)) != 0);
    void *digest = flux_auth_digest(flux_auth_string(token));
    void *again = flux_auth_digest(flux_auth_string(token));
    assert(digest && again && strlen(flux_auth_string(digest)) == 64);
    assert(strcmp(flux_auth_string(digest), flux_auth_string(again)) == 0);
    flux_auth_free_string(token); flux_auth_free_string(other);
    flux_auth_free_string(digest); flux_auth_free_string(again);
    for (int i = 0; i < 55; i++) { a = flux_auth_begin(pw, "", 0); assert(a); flux_auth_end(a); }
    assert(!flux_auth_begin(pw, "", 0));
    flux_auth_end(NULL); flux_auth_free_string(NULL);
    puts("PASS Argon2id policy, salts, verification, bad cost rejection, 256-bit tokens, digests, two-job admission, released slots and 60/minute budget");
}
