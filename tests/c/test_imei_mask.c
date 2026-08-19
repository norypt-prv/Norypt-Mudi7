// LINK: src/imei.c
#include <assert.h>
#include <string.h>
#include "../../src/imei.h"

int main(void) {
    char out[64];
    imei_mask("358835966999572", out, sizeof out);       /* 15 digits */
    assert(strcmp(out, "358835....99572") == 0);          /* keep 6 + 5, 4 masked */
    imei_mask("12345", out, sizeof out);                  /* too short */
    assert(strcmp(out, "12345") == 0);
    imei_mask("", out, sizeof out);
    assert(strcmp(out, "") == 0);
    return 0;
}
