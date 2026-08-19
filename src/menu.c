#include "menu.h"

static const char *LABELS[NG_ITEM_COUNT] = {
    "New Identity", "SIM Swap", "Rotate IMEIs", "Rotate Wireless", "Cancel"
};

void menu_layout(ng_item_t items[NG_ITEM_COUNT]) {
    int y = 44, h = 52, gap = 2;
    for (int i = 0; i < NG_ITEM_COUNT; i++) {
        items[i].label = LABELS[i];
        items[i].x = 8; items[i].w = 240 - 16;
        items[i].y = y; items[i].h = h;
        y += h + gap;
    }
}

int menu_hit_test(const ng_item_t *items, int n, int x, int y) {
    for (int i = 0; i < n; i++)
        if (x >= items[i].x && x < items[i].x + items[i].w &&
            y >= items[i].y && y < items[i].y + items[i].h) return i;
    return -1;
}

void menu_render(fb_t *fb, const ng_item_t *items, int n, int highlight) {
    uint16_t bg = fb_rgb565(0,0,0), fg = fb_rgb565(0,200,255),
             btn = fb_rgb565(20,20,30), inv = fb_rgb565(0,200,255), invtx = fb_rgb565(0,0,0);
    fb_fill_rect(fb, 0, 0, fb->w, fb->h, bg);
    fb_text(fb, 8, 12, "NORYPT GHOST", fg, bg);
    for (int i = 0; i < n; i++) {
        int hi = (i == highlight);
        fb_fill_rect(fb, items[i].x, items[i].y, items[i].w, items[i].h, hi ? inv : btn);
        int ty = items[i].y + (items[i].h - FB_GLYPH_H)/2;
        fb_text(fb, items[i].x + 10, ty, items[i].label, hi ? invtx : fg, hi ? inv : btn);
    }
}
