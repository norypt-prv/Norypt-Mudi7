#include "imei.h"
#include <string.h>
#define KEEP_HEAD 6
#define KEEP_TAIL 5
void imei_mask(const char *imei, char *out, size_t outsz) {
    size_t n = strlen(imei);
    if (outsz == 0) return;
    if (n < (size_t)(KEEP_HEAD + KEEP_TAIL) + 1 || n + 1 > outsz) {
        size_t c = (n + 1 <= outsz) ? n : outsz - 1;
        memcpy(out, imei, c); out[c] = '\0'; return;
    }
    for (size_t i = 0; i < n; i++)
        out[i] = (i < KEEP_HEAD || i >= n - KEEP_TAIL) ? imei[i] : '.';
    out[n] = '\0';
}
