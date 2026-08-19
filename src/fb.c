#include "fb.h"
#include "font8x16.h"

uint16_t fb_rgb565(uint8_t r, uint8_t g, uint8_t b) {
    return (uint16_t)(((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3));
}

void fb_fill_rect(fb_t *fb, int x, int y, int w, int h, uint16_t color) {
    for (int yy = y; yy < y + h; yy++) {
        if (yy < 0 || yy >= fb->h) continue;
        for (int xx = x; xx < x + w; xx++) {
            if (xx < 0 || xx >= fb->w) continue;
            fb->px[yy * fb->w + xx] = color;
        }
    }
}

void fb_char(fb_t *fb, int x, int y, char c, uint16_t fg, uint16_t bg) {
    unsigned uc = (unsigned char)c;
    if (uc > 127) uc = '?';
    for (int row = 0; row < FB_GLYPH_H; row++) {
        uint8_t bits = font8x16[uc][row];
        for (int col = 0; col < FB_GLYPH_W; col++) {
            uint16_t color = (bits & (0x80 >> col)) ? fg : bg;
            int px = x + col, py = y + row;
            if (px < 0 || px >= fb->w || py < 0 || py >= fb->h) continue;
            fb->px[py * fb->w + px] = color;
        }
    }
}

void fb_text(fb_t *fb, int x, int y, const char *s, uint16_t fg, uint16_t bg) {
    for (int i = 0; s[i]; i++) fb_char(fb, x + i * FB_GLYPH_W, y, s[i], fg, bg);
}
