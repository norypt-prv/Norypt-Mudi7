// LINK: src/menu.c src/fb.c
#include <assert.h>
#include "../../src/menu.h"

int main(void) {
    ng_item_t items[NG_ITEM_COUNT];
    menu_layout(items);
    assert(items[NG_NEW_IDENTITY].y >= 40);            /* below the title band */
    for (int i = 0; i < NG_ITEM_COUNT; i++) {          /* rects fit the screen */
        assert(items[i].x >= 0 && items[i].x + items[i].w <= 240);
        assert(items[i].y >= 0 && items[i].y + items[i].h <= 320);
    }
    for (int i = 1; i < NG_ITEM_COUNT; i++)            /* no vertical overlap */
        assert(items[i].y >= items[i-1].y + items[i-1].h);
    /* a tap in the middle of button 0 hits item 0 */
    int cx = items[0].x + items[0].w/2, cy = items[0].y + items[0].h/2;
    assert(menu_hit_test(items, NG_ITEM_COUNT, cx, cy) == NG_NEW_IDENTITY);
    /* a tap in the title band hits nothing */
    assert(menu_hit_test(items, NG_ITEM_COUNT, 5, 5) == -1);
    /* the Cancel (last) button center hits Cancel */
    int qx = items[NG_CANCEL].x + items[NG_CANCEL].w/2,
        qy = items[NG_CANCEL].y + items[NG_CANCEL].h/2;
    assert(menu_hit_test(items, NG_ITEM_COUNT, qx, qy) == NG_CANCEL);
    /* the gap between button 0 and button 1 (first row after button 0) hits nothing */
    assert(menu_hit_test(items, NG_ITEM_COUNT, items[0].x + 5,
                         items[0].y + items[0].h) == -1);
    /* off-screen negative coords hit nothing */
    assert(menu_hit_test(items, NG_ITEM_COUNT, -1, -1) == -1);

    /* menu_render actually paints the buttons, and highlighting one visibly
     * changes its pixels vs. the un-highlighted render */
    static uint16_t buf[240*320];
    fb_t fb = { buf, 240, 320 };
    int bx = items[0].x + 4, by = items[0].y + 4;
    menu_render(&fb, items, NG_ITEM_COUNT, -1);   /* nothing highlighted */
    uint16_t unhi = buf[by*240 + bx];
    menu_render(&fb, items, NG_ITEM_COUNT, 0);    /* highlight item 0 */
    assert(buf[by*240 + bx] != unhi);
    return 0;
}
