// LINK: src/screens.c src/fb.c src/imei.c
#include <assert.h>
#include "../../src/screens.h"
#include "../../src/fb.h"

int main(void) {
    uint16_t buf[240*320]; fb_t fb = { buf, 240, 320 };
    screen_confirm(&fb, "NEW IDENTITY?", 1);
    assert(screen_confirm_hit(-1, -1) == -1);        /* off-screen misses */
    /* a hit somewhere returns yes or no, never crashes */
    int r = screen_confirm_hit(60, 260);
    assert(r == 0 || r == 1 || r == -1);
    screen_busy(&fb, "Rotating...");
    screen_imei(&fb, "358835966999572", "358835961953269");  /* must not crash */
    return 0;
}
