#ifndef NG_SCREENS_H
#define NG_SCREENS_H
#include "fb.h"

/* Fixed YES/NO button rects for the confirm screen. Shared between
 * screen_confirm() (draw) and screen_confirm_hit() (hit test) so the
 * two can never drift apart. */
enum {
    NG_CONFIRM_YES_X = 20,  NG_CONFIRM_YES_Y = 250,
    NG_CONFIRM_YES_W = 90,  NG_CONFIRM_YES_H = 44,
    NG_CONFIRM_NO_X  = 130, NG_CONFIRM_NO_Y  = 250,
    NG_CONFIRM_NO_W  = 90,  NG_CONFIRM_NO_H  = 44
};

void screen_confirm(fb_t *fb, const char *title, int yes_hi);
int screen_confirm_hit(int x, int y);
void screen_busy(fb_t *fb, const char *msg);
void screen_imei(fb_t *fb, const char *old_imei, const char *new_imei);

#endif
