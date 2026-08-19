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
    return 0;
}
