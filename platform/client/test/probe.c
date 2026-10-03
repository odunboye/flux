/* Test-only markers; no account credentials are accepted as command arguments. */
#include "../c/http.c"
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc != 5) return 2;
    void *p=flux_client_new("POST",argv[1],
        "Content-Type: application/json\nAuthorization: Bearer native-test-token-marker\n",
        "native-test-password-marker",1,argv[2]);
    if (!p) return 3;
    int result=flux_client_perform(p), status=flux_client_status(p);
    int expected=atoi(argv[3]), expected_status=atoi(argv[4]);
    flux_client_free(p);
    if (result!=expected || status!=expected_status) {
        fprintf(stderr,"unexpected native result/status: %d/%d\n",result,status); return 1;
    }
    return 0;
}
