// LINK: src/fb.c
#include <assert.h>
#include <stdlib.h>
#include "../../src/fb.h"

int main(void) {
    uint16_t buf[240*320];
    fb_t fb = { buf, 240, 320 };
    uint16_t red = fb_rgb565(255,0,0);
    for (int i = 0; i < 240*320; i++) buf[i] = 0;
    fb_fill_rect(&fb, 10, 20, 30, 40, red);
    assert(buf[20*240 + 10] == red);         /* inside */
    assert(buf[19*240 + 10] == 0);           /* just above */
    assert(buf[59*240 + 39] == red);         /* bottom-right inside */
    /* clipping must not crash or write out of bounds */
    fb_fill_rect(&fb, 230, 310, 100, 100, red);
    assert(buf[319*240 + 239] == red);
    /* a glyph writes at least one fg pixel in its cell */
    for (int i = 0; i < 240*320; i++) buf[i] = 0;
    fb_char(&fb, 0, 0, 'A', red, 0);
    int any = 0; for (int yy=0; yy<16; yy++) for (int xx=0; xx<8; xx++) if (buf[yy*240+xx]==red) any=1;
    assert(any == 1);

    /* rgb565 packing: known values */
    assert(fb_rgb565(255, 255, 255) == 0xFFFF);
    assert(fb_rgb565(0, 0, 0) == 0x0000);
    assert(fb_rgb565(255, 0, 0) == 0xF800);
    assert(fb_rgb565(0, 255, 0) == 0x07E0);
    assert(fb_rgb565(0, 0, 255) == 0x001F);

    /* font correctness: space (0x20) must be entirely blank */
    for (int i = 0; i < 240*320; i++) buf[i] = 0;
    fb_char(&fb, 0, 0, ' ', red, 0);
    int space_any = 0;
    for (int yy = 0; yy < 16; yy++)
        for (int xx = 0; xx < 8; xx++)
            if (buf[yy*240+xx] == red) space_any = 1;
    assert(space_any == 0);

    /* font correctness: 'A' must have a blank top row and a set crossbar row */
    for (int i = 0; i < 240*320; i++) buf[i] = 0;
    fb_char(&fb, 0, 0, 'A', red, 0);
    int top_row_blank = 1;
    for (int xx = 0; xx < 8; xx++) if (buf[0*240+xx] == red) top_row_blank = 0;
    assert(top_row_blank == 1);
    int crossbar_set = 0; /* row 7 of classic VGA 'A' is the horizontal crossbar (0xfe) */
    for (int xx = 0; xx < 8; xx++) if (buf[7*240+xx] == red) crossbar_set = 1;
    assert(crossbar_set == 1);

    /* font correctness: '.' (used by the IMEI mask) renders a low dot, not a
     * blank glyph and not something spanning the whole cell height */
    for (int i = 0; i < 240*320; i++) buf[i] = 0;
    fb_char(&fb, 0, 0, '.', red, 0);
    int dot_any = 0, dot_in_top_half = 0;
    for (int yy = 0; yy < 16; yy++)
        for (int xx = 0; xx < 8; xx++)
            if (buf[yy*240+xx] == red) {
                dot_any = 1;
                if (yy < 8) dot_in_top_half = 1;
            }
    assert(dot_any == 1);
    assert(dot_in_top_half == 0);

    /* fb_text draws consecutive glyph cells */
    for (int i = 0; i < 240*320; i++) buf[i] = 0;
    fb_text(&fb, 0, 0, "AB", red, 0);
    int col0_any = 0, col1_any = 0;
    for (int yy = 0; yy < 16; yy++) {
        for (int xx = 0; xx < 8; xx++) if (buf[yy*240+xx] == red) col0_any = 1;
        for (int xx = 8; xx < 16; xx++) if (buf[yy*240+xx] == red) col1_any = 1;
    }
    assert(col0_any == 1);
    assert(col1_any == 1);

    /* negative-origin clipping: a rect starting off the top-left must clip to the
     * visible region, never wrap or write out of bounds */
    for (int i = 0; i < 240*320; i++) buf[i] = 0;
    fb_fill_rect(&fb, -5, -5, 10, 10, red);   /* visible part is pixels (0..4, 0..4) */
    assert(buf[0] == red);                      /* (0,0) inside the clipped rect */
    assert(buf[4*240 + 4] == red);              /* (4,4) inside */
    assert(buf[5*240 + 5] == 0);                /* (5,5) outside */
    /* a fully off-screen rect must touch nothing (buf[0] stays as it was) */
    fb_fill_rect(&fb, -100, -100, 50, 50, red);
    assert(buf[0] == red);

    return 0;
}
