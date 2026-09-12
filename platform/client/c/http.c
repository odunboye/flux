#define _POSIX_C_SOURCE 200809L
#include <curl/curl.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdint.h>

typedef struct {
    char *method, *url, *headers, *body, *ca;
    char response[65537];
    size_t used, header_bytes;
    int has_body, status;
} request;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static int initialized;
static void init(void) { initialized = curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK; }
static void wipe_free(char *s) {
    if (!s) return;
    volatile unsigned char *p = (volatile unsigned char *)s;
    size_t n = strlen(s);
    while (n--) *p++ = 0;
    free(s);
}
void flux_client_free(void *ptr) {
    request *r = ptr;
    if (!r) return;
    wipe_free(r->method); wipe_free(r->url);
    if (r->headers) {
        volatile unsigned char *h=(volatile unsigned char *)r->headers;
        for (size_t i=0;i<r->header_bytes;i++) h[i]=0;
        free(r->headers);
    }
    wipe_free(r->body); wipe_free(r->ca);
    volatile unsigned char *p = (volatile unsigned char *)r;
    for (size_t n=0; n<sizeof(*r); n++) p[n]=0;
    free(r);
}
void *flux_client_new(const char *method, const char *url, const char *headers,
                      const char *body, int has_body, const char *ca) {
    pthread_once(&once, init);
    if (!initialized || strlen(url)>8192 || strlen(headers)>8192 || strlen(body)>65536 || strlen(ca)>4096) return NULL;
    request *r = calloc(1,sizeof(*r));
    if (!r) return NULL;
    r->method=strdup(method); r->url=strdup(url); r->headers=strdup(headers);
    r->body=strdup(body); r->ca=strdup(ca); r->has_body=has_body; r->header_bytes=strlen(headers);
    if (!r->method || !r->url || !r->headers || !r->body || !r->ca) { flux_client_free(r); return NULL; }
    return r;
}
static size_t receive(char *bytes, size_t size, size_t count, void *ptr) {
    request *r = ptr;
    if (size && count>SIZE_MAX/size) return 0;
    size_t n=size*count;
    if (n>65536-r->used || memchr(bytes,0,n)) return 0;
    memcpy(r->response+r->used,bytes,n); r->used+=n; r->response[r->used]=0;
    return n;
}
/* Validate before the FFI converts bytes to a managed UTF-8 String. */
static int valid_utf8(const char *text, size_t size) {
    const unsigned char *s=(const unsigned char *)text;
    for (size_t i=0; i<size;) {
        unsigned char b=s[i++];
        if (b<0x80) continue;
        unsigned count;
        uint32_t point, minimum;
        if (b>=0xc2 && b<=0xdf) { count=1; point=b&0x1f; minimum=0x80; }
        else if (b>=0xe0 && b<=0xef) { count=2; point=b&0x0f; minimum=0x800; }
        else if (b>=0xf0 && b<=0xf4) { count=3; point=b&0x07; minimum=0x10000; }
        else return 0;
        if (count>size-i) return 0;
        while (count--) {
            b=s[i++]; if ((b&0xc0)!=0x80) return 0;
            point=(point<<6)|(b&0x3f);
        }
        if (point<minimum || point>0x10ffff || (point>=0xd800 && point<=0xdfff)) return 0;
    }
    return 1;
}
/* No redirects, proxies, URL credentials, query/fragment secrets or plaintext
 * remote connections. Native libcurl verifies chain and hostname; no CLI,
 * shell, temporary request files, cookie store, netrc, verbose output or retries. */
static int valid_url(const char *url, const char *ca) {
    CURLU *u=curl_url();
    char *scheme=NULL,*host=NULL,*part=NULL;
    int valid=0;
    if (!u || curl_url_set(u,CURLUPART_URL,url,0)!=CURLUE_OK) goto done;
    if (curl_url_get(u,CURLUPART_SCHEME,&scheme,0)!=CURLUE_OK || curl_url_get(u,CURLUPART_HOST,&host,0)!=CURLUE_OK) goto done;
    valid=!strcasecmp(scheme,"https") || (!strcasecmp(scheme,"http") &&
        (!strcasecmp(host,"localhost") || !strcmp(host,"127.0.0.1") || !strcmp(host,"[::1]")));
    if (ca[0] && strcasecmp(scheme,"https")) valid=0;
    CURLUPart forbidden[]={CURLUPART_USER,CURLUPART_PASSWORD,CURLUPART_QUERY,CURLUPART_FRAGMENT};
    for (size_t i=0; i<sizeof(forbidden)/sizeof(forbidden[0]); i++) {
        if (curl_url_get(u,forbidden[i],&part,0)==CURLUE_OK) { valid=0; curl_free(part); part=NULL; }
    }
done:
    curl_free(scheme); curl_free(host); curl_url_cleanup(u); return valid;
}
int flux_client_perform(void *ptr) {
    request *r=ptr;
    if (!valid_url(r->url,r->ca)) return -2;
    CURL *c=curl_easy_init();
    struct curl_slist *headers=NULL;
    int result=-1;
    if (!c) return -1;
    char *save=NULL;
    for (char *line=strtok_r(r->headers,"\n",&save); line; line=strtok_r(NULL,"\n",&save)) {
        struct curl_slist *next=curl_slist_append(headers,line);
        if (!next) goto done;
        headers=next;
    }
#define SET(option,value) do { if (curl_easy_setopt(c,option,value)!=CURLE_OK) goto done; } while(0)
    SET(CURLOPT_URL,r->url); SET(CURLOPT_CUSTOMREQUEST,r->method);
    SET(CURLOPT_HTTPHEADER,headers); SET(CURLOPT_PROXY,"");
    if (!strcmp(r->method,"HEAD")) SET(CURLOPT_NOBODY,1L);
    SET(CURLOPT_NETRC,(long)CURL_NETRC_IGNORED);
    SET(CURLOPT_FOLLOWLOCATION,0L); SET(CURLOPT_PROTOCOLS_STR,"http,https");
    SET(CURLOPT_SSL_VERIFYPEER,1L); SET(CURLOPT_SSL_VERIFYHOST,2L);
    SET(CURLOPT_SSLVERSION,(long)CURL_SSLVERSION_TLSv1_2);
    SET(CURLOPT_CONNECTTIMEOUT_MS,5000L); SET(CURLOPT_TIMEOUT_MS,30000L);
    SET(CURLOPT_NOSIGNAL,1L); SET(CURLOPT_WRITEFUNCTION,receive); SET(CURLOPT_WRITEDATA,r);
    if (r->ca[0]) SET(CURLOPT_CAINFO,r->ca);
    if (r->has_body) { SET(CURLOPT_POSTFIELDS,r->body); SET(CURLOPT_POSTFIELDSIZE_LARGE,(curl_off_t)strlen(r->body)); }
    CURLcode code=curl_easy_perform(c);
    if (code==CURLE_OPERATION_TIMEDOUT) { result=-3; goto done; }
    if (code!=CURLE_OK || !valid_utf8(r->response,r->used)) goto done;
    long status=0;
    if (curl_easy_getinfo(c,CURLINFO_RESPONSE_CODE,&status)!=CURLE_OK) goto done;
    r->status=(int)status; result=0;
done:
    curl_easy_cleanup(c);
    for (struct curl_slist *h=headers; h; h=h->next) {
        volatile char *p=h->data; size_t n=strlen(h->data); while(n--) *p++=0;
    }
    curl_slist_free_all(headers); return result;
}
int flux_client_status(void *ptr) { return ((request *)ptr)->status; }
const char *flux_client_body(void *ptr) { return ((request *)ptr)->response; }
