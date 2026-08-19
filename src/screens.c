#include "screens.h"
#include "imei.h"
#include <stdio.h>

void screen_confirm(fb_t *fb, const char *title, int yes_hi) {
    uint16_t bg = fb_rgb565(0, 0, 0), fg = fb_rgb565(0, 200, 255),
             btn = fb_rgb565(20, 20, 30), inv = fb_rgb565(0, 200, 255),
             invtx = fb_rgb565(0, 0, 0);

    fb_fill_rect(fb, 0, 0, fb->w, fb->h, bg);
    fb_text(fb, 8, 12, title, fg, bg);
    fb_text(fb, 8, 40, "Are you sure?", fg, bg);

    int yes = (yes_hi != 0);
    fb_fill_rect(fb, NG_CONFIRM_YES_X, NG_CONFIRM_YES_Y, NG_CONFIRM_YES_W, NG_CONFIRM_YES_H,
                 yes ? inv : btn);
    fb_text(fb, NG_CONFIRM_YES_X + 12, NG_CONFIRM_YES_Y + (NG_CONFIRM_YES_H - FB_GLYPH_H) / 2,
            "[ YES ]", yes ? invtx : fg, yes ? inv : btn);

    int no = !yes;
    fb_fill_rect(fb, NG_CONFIRM_NO_X, NG_CONFIRM_NO_Y, NG_CONFIRM_NO_W, NG_CONFIRM_NO_H,
                 no ? inv : btn);
    fb_text(fb, NG_CONFIRM_NO_X + 16, NG_CONFIRM_NO_Y + (NG_CONFIRM_NO_H - FB_GLYPH_H) / 2,
            "[ NO ]", no ? invtx : fg, no ? inv : btn);
}

int screen_confirm_hit(int x, int y) {
    if (x >= NG_CONFIRM_YES_X && x < NG_CONFIRM_YES_X + NG_CONFIRM_YES_W &&
        y >= NG_CONFIRM_YES_Y && y < NG_CONFIRM_YES_Y + NG_CONFIRM_YES_H)
        return 1;
    if (x >= NG_CONFIRM_NO_X && x < NG_CONFIRM_NO_X + NG_CONFIRM_NO_W &&
        y >= NG_CONFIRM_NO_Y && y < NG_CONFIRM_NO_Y + NG_CONFIRM_NO_H)
        return 0;
    return -1;
}

void screen_busy(fb_t *fb, const char *msg) {
    uint16_t bg = fb_rgb565(0, 0, 0), fg = fb_rgb565(0, 200, 255);
    fb_fill_rect(fb, 0, 0, fb->w, fb->h, bg);

    int len = 0;
    while (msg[len]) len++;
    int x = (fb->w - len * FB_GLYPH_W) / 2;
    int y = (fb->h - FB_GLYPH_H) / 2;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    fb_text(fb, x, y, msg, fg, bg);
}

void screen_imei(fb_t *fb, const char *old_imei, const char *new_imei) {
    uint16_t bg = fb_rgb565(0, 0, 0), fg = fb_rgb565(0, 200, 255);
    fb_fill_rect(fb, 0, 0, fb->w, fb->h, bg);

    char masked_old[32], masked_new[32];
    imei_mask(old_imei, masked_old, sizeof(masked_old));
    imei_mask(new_imei, masked_new, sizeof(masked_new));

    char line_old[48], line_new[48];
    snprintf(line_old, sizeof(line_old), "old %s", masked_old);
    snprintf(line_new, sizeof(line_new), "new %s", masked_new);

    fb_text(fb, 8, 100, line_old, fg, bg);
    fb_text(fb, 8, 124, line_new, fg, bg);
}
