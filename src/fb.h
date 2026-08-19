#ifndef NG_FB_H
#define NG_FB_H
#include <stdint.h>

/* A caller-provided RGB565 pixel surface. On-device, px points at the
 * mmap'd /dev/fb0 framebuffer; in host tests it points at a stack/heap
 * buffer, which is what makes drawing testable without hardware. */
typedef struct { uint16_t *px; int w, h; } fb_t;

enum { FB_GLYPH_W = 8, FB_GLYPH_H = 16 };

uint16_t fb_rgb565(uint8_t r, uint8_t g, uint8_t b);
void fb_fill_rect(fb_t *fb, int x, int y, int w, int h, uint16_t color);
void fb_char(fb_t *fb, int x, int y, char c, uint16_t fg, uint16_t bg);
void fb_text(fb_t *fb, int x, int y, const char *s, uint16_t fg, uint16_t bg);

#endif
