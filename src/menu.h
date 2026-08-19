#ifndef NG_MENU_H
#define NG_MENU_H
#include "fb.h"
typedef struct { const char *label; int x, y, w, h; } ng_item_t;
enum { NG_NEW_IDENTITY, NG_SIM_SWAP, NG_ROTATE_IMEI, NG_ROTATE_WIRELESS, NG_CANCEL, NG_ITEM_COUNT };
void menu_layout(ng_item_t items[NG_ITEM_COUNT]);
int menu_hit_test(const ng_item_t *items, int n, int x, int y);
void menu_render(fb_t *fb, const ng_item_t *items, int n, int highlight);
#endif
