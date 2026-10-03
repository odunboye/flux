#define _POSIX_C_SOURCE 200809L
#include <sodium.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* Fixed Argon2id policy: 64 MiB, three passes, two admitted jobs, no queue.
 * At most 60 starts/minute/process, including unknown-user dummy checks.
 * Acquire before scheduling on Flux's bounded, joined blocking worker pool. */
#define POLICY "$argon2id$v=19$m=65536,t=3,p=1$"
typedef struct { char password[1025], hash[crypto_pwhash_STRBYTES]; int verify; } job;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned active, starts;
static time_t window;

void *flux_auth_begin(const char *password, const char *hash, int verify) {
    if (sodium_init() < 0 || strlen(password) > 1024 || strlen(hash) >= crypto_pwhash_STRBYTES) return NULL;
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return NULL;
    pthread_mutex_lock(&lock);
    if (now.tv_sec - window >= 60) { window = now.tv_sec; starts = 0; }
    if (active >= 2 || starts >= 60) { pthread_mutex_unlock(&lock); return NULL; }
    job *j = calloc(1, sizeof(*j));
    if (j) { active++; starts++; }
    pthread_mutex_unlock(&lock);
    if (!j) return NULL;
    memcpy(j->password, password, strlen(password));
    memcpy(j->hash, hash, strlen(hash));
    j->verify = verify;
    return j;
}
int flux_auth_run(void *ptr) {
    job *j = ptr;
    if (!j->verify)
        return crypto_pwhash_str_alg(j->hash, j->password, strlen(j->password),
                                    3, 64 * 1024 * 1024, crypto_pwhash_ALG_ARGON2ID13) == 0 ? 1 : -1;
    /* Never let a corrupt/hostile stored hash request unbounded memory/work. */
    if (strncmp(j->hash, POLICY, strlen(POLICY)) != 0) return -1;
    return crypto_pwhash_str_verify(j->hash, j->password, strlen(j->password)) == 0 ? 1 : 0;
}
const char *flux_auth_hash(void *ptr) { return ((job *)ptr)->hash; }
void flux_auth_end(void *ptr) {
    if (!ptr) return;
    sodium_memzero(ptr, sizeof(job)); free(ptr);
    pthread_mutex_lock(&lock); active--; pthread_mutex_unlock(&lock);
}
/* Small cryptographic operations only. Caller owns 65 bytes of native storage. */
void *flux_auth_token(void) {
    if (sodium_init() < 0) return NULL;
    unsigned char bytes[32];
    char *out = calloc(65, 1);
    if (!out) return NULL;
    randombytes_buf(bytes, sizeof(bytes));
    sodium_bin2base64(out, 65, bytes, sizeof(bytes), sodium_base64_VARIANT_URLSAFE_NO_PADDING);
    sodium_memzero(bytes, sizeof(bytes));
    return out;
}
void *flux_auth_digest(const char *token) {
    if (sodium_init() < 0 || strlen(token) != 43) return NULL;
    unsigned char bytes[crypto_hash_sha256_BYTES];
    char *out = calloc(65, 1);
    if (!out) return NULL;
    crypto_hash_sha256(bytes, (const unsigned char *)token, 43);
    sodium_bin2hex(out, 65, bytes, sizeof(bytes));
    sodium_memzero(bytes, sizeof(bytes));
    return out;
}
const char *flux_auth_string(void *ptr) { return ptr; }
void flux_auth_free_string(void *ptr) { if (ptr) { sodium_memzero(ptr, 65); free(ptr); } }
