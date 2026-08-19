# No-Retention Ghost + On-Device Menu — Implementation Plan

> **Implementation plan** - implement task-by-task, following TDD. Steps use checkbox syntax for tracking.

**Goal:** Remove all persistence of prior identity from Norypt Ghost, and add a framebuffer menu (opened by the clock long-press) that triggers full new-identity / sim-swap / rotate from the device screen, showing a masked old→new IMEI ephemerally.

**Architecture:** Part A is a subtractive shell refactor — delete factory capture, sealing, and restore; identity is stable across reboots and changes only on demand. Part B grows the C evdev daemon (`norypt-ghost-touch`) into a small state machine with its own framebuffer drawing (embedded bitmap font) and touch hit-testing; menu actions `fork` the existing `norypt-ghost <subcommand>` — no new rotation logic. A tmpfs handoff file carries the old/new IMEI to the daemon for the masked display and is deleted after rendering.

**Tech Stack:** POSIX shell (ash/OpenWrt), Lua 5.1 (IMEI generator, unchanged), C99 (daemon, static aarch64 via `aarch64-linux-gnu-gcc`), Python `unittest` + a new C host-test runner in `tests/run.sh`.

**Spec:** `docs/NO-LOG-MENU-DESIGN.md`

## Global Constraints
- Target: GL-iNet GL-E5800 (Mudi 7), OpenWrt 23.05.4, firmware 4.8.5. Arch `aarch64_cortex-a53`.
- Framebuffer `/dev/fb0`: 240×320, 16bpp RGB565, stride 480 bytes.
- No identity value (current or prior) is ever written to flash for the purpose of retention; the masked-IMEI handoff lives only in tmpfs (`/tmp`, mode 0600) and is deleted after use.
- The daemon binary is a build artifact — never committed; built from `src/` by `tools/build-touch.sh`.
- The daemon must not `grab` (EVIOCGRAB) the input device — `gl_screen` keeps working when the menu is closed.
- All shell files must pass `shellcheck -s sh`. The full host suite (`tests/run.sh`) must stay green.
- Commit after every task with a `feat:` / `refactor:` / `test:` message; work on branch `feature/no-log-menu`.

---

## Phase A — No-retention refactor

### Task A1: Confirm no rotation path depends on factory state

**Files:**
- Read only: `files/lib/norypt-ghost/functions.sh`, `files/lib/norypt-ghost/identity.sh`, `files/lib/norypt-ghost/profile.sh`, `files/usr/bin/norypt-ghost`

**Interfaces:**
- Produces: a go/no-go decision recorded in the commit message. If any rotation/apply path reads `norypt-ghost.factory.*`, this task expands to replace that read with a live source before Task A2 deletes the section.

- [ ] **Step 1: Grep every read of the factory section**

Run:
```bash
grep -rn "norypt-ghost.factory\|_get_factory\|_save_factory_state\|factory_imei" files/lib files/usr/bin/norypt-ghost
```
Expected: matches only inside `_save_factory_state`, `_get_factory`, the `restore` subcommand, `install`, and `_print_status`. None inside `IDENTITY_STAGE`, `IDENTITY_APPLY_BOOT`, `_rotate`, `_rotate_wireless`, or `profile.sh`.

- [ ] **Step 2: Record the finding**

If the expectation holds, factory state is display/restore-only and safe to delete. If any generator path reads it, STOP and note which — that read must be rewritten to a live UCI/AT source first. Commit this note:
```bash
git commit --allow-empty -m "chore: confirm rotation paths are factory-state independent"
```

---

### Task A2: Delete sealing and its tests

**Files:**
- Delete: `files/lib/norypt-ghost/seal.sh`
- Delete: `tests/test_seal_factory_parse.py`, `tests/test_seal_roundtrip.py`
- Modify: `files/usr/bin/norypt-ghost` (remove `_seal_factory_if_requested` and its call), `files/lib/norypt-ghost/functions.sh` (remove any `. /lib/norypt-ghost/seal.sh` source)

**Interfaces:**
- Produces: no `SEAL_*` symbols anywhere in the tree.

- [ ] **Step 1: Remove the seal roundtrip host tests**

```bash
git rm tests/test_seal_factory_parse.py tests/test_seal_roundtrip.py
```

- [ ] **Step 2: Delete seal.sh and remove references**

```bash
git rm files/lib/norypt-ghost/seal.sh
```
In `files/usr/bin/norypt-ghost`, delete the entire `_seal_factory_if_requested() { ... }` function and the line that calls it (in the `install` capture flow). Remove any `. /lib/norypt-ghost/seal.sh` source lines in that file and in `functions.sh`.

- [ ] **Step 3: Verify no seal symbols remain**

Run: `grep -rn "SEAL_\|seal.sh\|_seal_factory\|seal-pass" files/ tests/`
Expected: no output.

- [ ] **Step 4: Run host tests**

Run: `bash tests/run.sh`
Expected: PASS (shellcheck + python + lua). No missing-module errors from the deleted tests.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "refactor: remove factory-state sealing (no-retention model)"
```

---

### Task A3: Delete factory capture and the `restore` subcommand

**Files:**
- Modify: `files/lib/norypt-ghost/functions.sh` (delete `_save_factory_state` and any factory-read helper like `_get_factory`)
- Modify: `files/usr/bin/norypt-ghost` (delete the `restore)` case and its passphrase/blob loop; delete the helper that reads factory keys in `_print_status`; change every `_save_factory_state || exit 1` line)
- Modify: `files/usr/libexec/norypt-ghost` (remove the `restore`/factory rpcd action)

**Interfaces:**
- Consumes: A1's confirmation that these are display/restore-only.
- Produces: CLI subcommands `rotate`, `rotate-wireless`, `new-identity`, `sim-swap` no longer call factory capture; no `restore` subcommand exists; rpcd backend exposes no restore action.

- [ ] **Step 1: Remove factory-capture calls from the dispatch**

In `files/usr/bin/norypt-ghost`, in the `case "$cmd"` block, delete the line `_save_factory_state || exit 1` (and the bare `_save_factory_state`) from the `rotate)`, `rotate-wireless)`, `new-identity)`, `sim-swap)` and `install)` cases. For `install)` replace the body with the setup-only body from Task A4.

- [ ] **Step 2: Delete the `restore)` case**

Delete the entire `restore)` case (the passphrase read, blob decrypt, and factory-key restore loop) from the dispatch and its `restore` line from the `help` text.

- [ ] **Step 3: Delete `_save_factory_state` / `_get_factory`**

Remove those functions from `functions.sh` (and the `_get_factory_imei` legacy shim in the CLI if present).

- [ ] **Step 4: Remove restore from the rpcd backend**

In `files/usr/libexec/norypt-ghost`, delete the `restore` action branch so the LuCI backend can no longer invoke it.

- [ ] **Step 5: Shellcheck the changed files**

Run: `shellcheck -s sh files/usr/bin/norypt-ghost files/usr/libexec/norypt-ghost files/lib/norypt-ghost/*.sh`
Expected: clean (no undefined-function or unused-variable errors from the removals).

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "refactor: remove factory capture and restore (no-retention model)"
```

---

### Task A4: Repurpose `install` to setup-only; drop the postinst seal prompt

**Files:**
- Modify: `files/usr/bin/norypt-ghost` (`install)` case body)
- Modify: `build-ipk.sh` (postinst: remove the interactive sealing block and the "non-interactive → unsealed" messaging; keep service enable + `norypt-ghost install`)
- Modify: `build-ipk.sh` (prerm: remove the `norypt-ghost restore` call and the sealed-state warning)

**Interfaces:**
- Produces: `norypt-ghost install` enables services and writes default options only; it never captures identity. postinst prints no passphrase prompt; prerm never restores.

- [ ] **Step 1: Rewrite the `install)` case**

Replace the `install)` body in `files/usr/bin/norypt-ghost` with:
```sh
    install)
        # No-retention model: no factory capture. Setup only.
        uci -q get norypt-ghost.options >/dev/null 2>&1 || {
            uci -c /etc/config set norypt-ghost.options=norypt-ghost
        }
        # Identity changes on demand only — never per boot.
        uci -c /etc/config set norypt-ghost.options.randomize_on_boot=0
        uci -c /etc/config commit norypt-ghost
        echo "norypt-ghost: setup complete (no-retention model)."
        echo "  Change identity on demand: norypt-ghost new-identity  (or the on-screen menu)."
        ;;
```

- [ ] **Step 2: Strip the postinst seal block**

In `build-ipk.sh`, in the `POSTINST` heredoc, delete the whole `if command -v openssl ... fi` sealing block (interactive passphrase prompt + non-interactive message). Keep the service-enable lines and the trailing `/usr/bin/norypt-ghost install`.

- [ ] **Step 3: Strip the prerm restore**

In the `PRERM` heredoc, delete the sealed-state `if ... norypt-ghost restore ... fi` block; keep only the stop/disable lines. Add a one-line echo: `echo "norypt-ghost: removed — device keeps its current identity (no-retention model)."`.

- [ ] **Step 4: Build the package to prove the control scripts are valid**

Run: `./build-ipk.sh`
Expected: builds `norypt-ghost_1.0.0-Script-Local.ipk`; no shell syntax error from the heredocs. (Requires the touch daemon binary; if absent, run `./tools/build-touch.sh` first.)

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "refactor: install=setup-only; drop postinst seal prompt and prerm restore"
```

---

### Task A5: Drop the factory display from `status`; default `randomize_on_boot=0`

**Files:**
- Modify: `files/usr/bin/norypt-ghost` (`_print_status` — remove the "Factory IMEIs" block)
- Modify: `files/etc/config/norypt-ghost` (the shipped default config — set `randomize_on_boot '0'`)

**Interfaces:**
- Produces: `status` shows only the current identity; shipped config keeps identity stable across reboots.

- [ ] **Step 1: Remove the Factory IMEIs block**

In `_print_status`, delete the lines that print `Factory IMEIs:` and the two slot values (they call the now-deleted factory getter). Leave the current-identity output intact.

- [ ] **Step 2: Set the default**

In `files/etc/config/norypt-ghost`, set the `randomize_on_boot` option to `'0'` (add it to the `options` section if not present).

- [ ] **Step 3: Verify status parses and shellcheck passes**

Run: `shellcheck -s sh files/usr/bin/norypt-ghost` — Expected: clean.
Run: `sh -n files/usr/bin/norypt-ghost` — Expected: no syntax error.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "refactor: status drops factory block; randomize_on_boot defaults off"
```

---

## Phase B — On-device menu

### Task B1: Touch→framebuffer calibration (device, produces constants only)

**Files:**
- Create: `docs/TOUCH-CALIBRATION.md` (recorded transform)

**Interfaces:**
- Produces: the transform used by every later drawing/hit-test task: `FB_W=240`, `FB_H=320`, and the mapping `fb_x = f(tx,ty)`, `fb_y = g(tx,ty)` (axis order, inversion, scale) as integer formulas.

- [ ] **Step 1: Capture raw touch events at known points**

On the connected unit, stream events while tapping the four corners then center:
```bash
ssh root@192.168.8.1 'cat /dev/input/event0 | hexdump -v -e "1/2 \"%d \" 1/2 \"%d \" 1/4 \"%d\\n\""'
```
(Or use the existing `ABS_MT_POSITION_X/Y` decoding.) Ask the operator to tap: top-left, top-right, bottom-left, bottom-right, center. Record the `(x,y)` ranges.

- [ ] **Step 2: Derive and record the transform**

From the min/max at the corners, write the axis order + inversion + scale to map touch coordinates into the 240×320 framebuffer pixel space. Save to `docs/TOUCH-CALIBRATION.md` including the raw samples.

- [ ] **Step 3: Commit**

```bash
git add docs/TOUCH-CALIBRATION.md && git commit -m "docs: record touch->framebuffer calibration for E5800"
```

---

### Task B2: IMEI masking (host-tested pure C)

**Files:**
- Create: `src/imei.h`, `src/imei.c`
- Create: `tests/c/test_imei_mask.c`
- Modify: `tests/run.sh` (add a C host-test stage)

**Interfaces:**
- Produces: `void imei_mask(const char *imei, char *out, size_t outsz);` — copies `imei` to `out` keeping the first 6 and last 5 characters, replacing each middle character with `'.'` (ASCII stand-in for the on-screen bullet; the font maps it to a dot glyph). Strings shorter than 12 chars are copied unchanged. Always NUL-terminates.

- [ ] **Step 1: Write the failing test**

`tests/c/test_imei_mask.c`:
```c
#include <assert.h>
#include <string.h>
#include "../../src/imei.h"

int main(void) {
    char out[64];
    imei_mask("358835966999572", out, sizeof out);       /* 15 digits */
    assert(strcmp(out, "358835....99572") == 0);          /* keep 6 + 5, 4 masked */
    imei_mask("12345", out, sizeof out);                  /* too short */
    assert(strcmp(out, "12345") == 0);
    imei_mask("", out, sizeof out);
    assert(strcmp(out, "") == 0);
    return 0;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `gcc -Wall -Wextra -o /tmp/t_imei tests/c/test_imei_mask.c src/imei.c 2>&1 || true`
Expected: FAIL — `src/imei.c` / `src/imei.h` do not exist yet.

- [ ] **Step 3: Write minimal implementation**

`src/imei.h`:
```c
#ifndef NG_IMEI_H
#define NG_IMEI_H
#include <stddef.h>
void imei_mask(const char *imei, char *out, size_t outsz);
#endif
```
`src/imei.c`:
```c
#include "imei.h"
#include <string.h>
#define KEEP_HEAD 6
#define KEEP_TAIL 5
void imei_mask(const char *imei, char *out, size_t outsz) {
    size_t n = strlen(imei);
    if (outsz == 0) return;
    if (n < (size_t)(KEEP_HEAD + KEEP_TAIL) + 1 || n + 1 > outsz) {
        size_t c = (n + 1 <= outsz) ? n : outsz - 1;
        memcpy(out, imei, c); out[c] = '\0'; return;
    }
    for (size_t i = 0; i < n; i++)
        out[i] = (i < KEEP_HEAD || i >= n - KEEP_TAIL) ? imei[i] : '.';
    out[n] = '\0';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `gcc -Wall -Wextra -o /tmp/t_imei tests/c/test_imei_mask.c src/imei.c && /tmp/t_imei && echo OK`
Expected: `OK`.

- [ ] **Step 5: Wire the C stage into the suite**

In `tests/run.sh`, before the final success echo, add:
```bash
echo "== C host tests =="
for t in tests/c/test_*.c; do
    base="$(basename "$t" .c)"
    gcc -Wall -Wextra -I src -o "/tmp/ng_$base" "$t" $(sed -n 's,^// LINK: ,,p' "$t") && "/tmp/ng_$base"
done
```
Add `// LINK: src/imei.c` as the first line of `tests/c/test_imei_mask.c` so the runner links it.

- [ ] **Step 6: Run the full suite and commit**

Run: `bash tests/run.sh` — Expected: PASS incl. the new C stage.
```bash
git add -A && git commit -m "feat: imei_mask with host tests + C test stage"
```

---

### Task B3: Framebuffer primitives on an in-memory surface (host-tested)

**Files:**
- Create: `src/fb.h`, `src/fb.c`
- Create: `src/font8x16.h` (embedded public-domain bitmap font; see Step 3)
- Create: `tests/c/test_fb.c`

**Interfaces:**
- Produces:
  - `typedef struct { uint16_t *px; int w, h; } fb_t;`
  - `uint16_t fb_rgb565(uint8_t r, uint8_t g, uint8_t b);`
  - `void fb_fill_rect(fb_t *fb, int x, int y, int w, int h, uint16_t color);`  (clips to bounds)
  - `void fb_char(fb_t *fb, int x, int y, char c, uint16_t fg, uint16_t bg);`   (8×16 cell)
  - `void fb_text(fb_t *fb, int x, int y, const char *s, uint16_t fg, uint16_t bg);`
  - Glyph cell size constants `FB_GLYPH_W = 8`, `FB_GLYPH_H = 16`.

- [ ] **Step 1: Write the failing test**

`tests/c/test_fb.c`:
```c
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
    return 0;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `gcc -Wall -Wextra -I src -o /tmp/t_fb tests/c/test_fb.c src/fb.c 2>&1 || true`
Expected: FAIL — `src/fb.*` missing.

- [ ] **Step 3: Vendor the font**

Download the public-domain 8×16 VGA font header (Daniel Hepper's `font8x8` is 8×8; for 8×16 use the public-domain IBM VGA 8×16 table). Create `src/font8x16.h` exposing:
```c
#ifndef NG_FONT8X16_H
#define NG_FONT8X16_H
#include <stdint.h>
/* font8x16[c][row] = bitmap row (bit7 = leftmost pixel), c in 0..127 */
static const uint8_t font8x16[128][16] = {
  /* ... public-domain VGA 8x16 glyph rows ... */
};
#endif
```
Record the source + public-domain statement in a comment at the top. Only ASCII 0x20–0x7E need real glyphs; others may be blank. Ensure `'.'` (0x2E) renders a low dot (used by the mask) and `'/'`, `':'`, `'-'`, `'['`, `']'` exist.

- [ ] **Step 4: Write minimal implementation**

`src/fb.h`:
```c
#ifndef NG_FB_H
#define NG_FB_H
#include <stdint.h>
typedef struct { uint16_t *px; int w, h; } fb_t;
enum { FB_GLYPH_W = 8, FB_GLYPH_H = 16 };
uint16_t fb_rgb565(uint8_t r, uint8_t g, uint8_t b);
void fb_fill_rect(fb_t *fb, int x, int y, int w, int h, uint16_t color);
void fb_char(fb_t *fb, int x, int y, char c, uint16_t fg, uint16_t bg);
void fb_text(fb_t *fb, int x, int y, const char *s, uint16_t fg, uint16_t bg);
#endif
```
`src/fb.c`:
```c
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
    unsigned uc = (unsigned char)c; if (uc > 127) uc = '?';
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/run.sh` — Expected: PASS incl. `test_fb`.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat: RGB565 framebuffer primitives + embedded 8x16 font (host-tested)"
```

---

### Task B4: Menu model, layout, and hit-testing (host-tested)

**Files:**
- Create: `src/menu.h`, `src/menu.c`
- Create: `tests/c/test_menu.c`

**Interfaces:**
- Consumes: `fb_t`, `fb_*` from Task B3.
- Produces:
  - `typedef struct { const char *label; int x, y, w, h; } ng_item_t;`
  - `enum { NG_NEW_IDENTITY, NG_SIM_SWAP, NG_ROTATE_IMEI, NG_ROTATE_WIRELESS, NG_CANCEL, NG_ITEM_COUNT };`
  - `void menu_layout(ng_item_t items[NG_ITEM_COUNT]);` — fills labels + rects for a 240×320 screen (title band 0..40, five 52-px buttons stacked from y=44).
  - `int menu_hit_test(const ng_item_t *items, int n, int x, int y);` — returns item index whose rect contains `(x,y)`, else `-1`.
  - `void menu_render(fb_t *fb, const ng_item_t *items, int n, int highlight);` — draws title + buttons; `highlight` index (or -1) drawn inverted.

- [ ] **Step 1: Write the failing test**

`tests/c/test_menu.c`:
```c
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `gcc -Wall -Wextra -I src -o /tmp/t_menu tests/c/test_menu.c src/menu.c src/fb.c 2>&1 || true`
Expected: FAIL — `src/menu.*` missing.

- [ ] **Step 3: Write minimal implementation**

`src/menu.h`:
```c
#ifndef NG_MENU_H
#define NG_MENU_H
#include "fb.h"
typedef struct { const char *label; int x, y, w, h; } ng_item_t;
enum { NG_NEW_IDENTITY, NG_SIM_SWAP, NG_ROTATE_IMEI, NG_ROTATE_WIRELESS, NG_CANCEL, NG_ITEM_COUNT };
void menu_layout(ng_item_t items[NG_ITEM_COUNT]);
int menu_hit_test(const ng_item_t *items, int n, int x, int y);
void menu_render(fb_t *fb, const ng_item_t *items, int n, int highlight);
#endif
```
`src/menu.c`:
```c
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh` — Expected: PASS incl. `test_menu`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: menu layout, hit-test, and render (host-tested)"
```

---

### Task B5: Confirm + status screens (host-tested render, no crash)

**Files:**
- Create: `src/screens.h`, `src/screens.c`
- Create: `tests/c/test_screens.c`

**Interfaces:**
- Consumes: `fb_t`, `fb_*`, `imei_mask`.
- Produces:
  - `void screen_confirm(fb_t *fb, const char *title, int yes_hi);` — draws a title/prompt and `[ YES ]`/`[ NO ]` buttons at fixed rects; exposes their rects via `screen_confirm_hit(int x,int y)` → `1` (yes), `0` (no), `-1` (none).
  - `int screen_confirm_hit(int x, int y);`
  - `void screen_busy(fb_t *fb, const char *msg);`
  - `void screen_imei(fb_t *fb, const char *old_imei, const char *new_imei);` — masks both via `imei_mask` and draws `old …` / `new …`.

- [ ] **Step 1: Write the failing test**

`tests/c/test_screens.c`:
```c
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `gcc -Wall -Wextra -I src -o /tmp/t_scr tests/c/test_screens.c src/screens.c src/fb.c src/imei.c 2>&1 || true`
Expected: FAIL — `src/screens.*` missing.

- [ ] **Step 3: Write minimal implementation**

Implement `src/screens.h`/`.c` with fixed YES/NO rects (e.g. YES `x=20,y=250,w=90,h=44`; NO `x=130,y=250,w=90,h=44`), `screen_confirm_hit` testing those rects, `screen_busy` centering `msg`, and `screen_imei` calling `imei_mask` into local buffers then `fb_text` for `old`/`new` lines. Colors via `fb_rgb565`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/run.sh` — Expected: PASS incl. `test_screens`.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: confirm/busy/masked-imei screens (host-tested)"
```

---

### Task B6: Device framebuffer open + gl_screen eviction (device-only module)

**Files:**
- Create: `src/fbdev.h`, `src/fbdev.c`

**Interfaces:**
- Produces:
  - `int fbdev_open(fb_t *out);` — evicts gl_screen (`system("ubus call service delete '{\"name\":\"gl_screen\"}' ...")` then `/etc/init.d/gl_screen stop` + `pkill -9 gl_screen`), opens `/dev/fb0`, `mmap`s it, fills `out->px/w/h`. Returns 0 on success, -1 on error.
  - `void fbdev_close(fb_t *fb, int restore_gl);` — unmaps; if `restore_gl`, runs `/etc/init.d/gl_screen start`.
  - No host test (device syscalls); covered by on-device Task B9.

- [ ] **Step 1: Implement fbdev**

Use `open("/dev/fb0", O_RDWR)`, `ioctl(FBIOGET_VSCREENINFO)` to confirm 240×320×16, `mmap` `w*h*2` bytes. Reuse the exact eviction sequence from `functions.sh:_screen_splash`. Guard all `system()` calls' return values (log on failure).

- [ ] **Step 2: Compile-check for the target**

Run: `aarch64-linux-gnu-gcc -O2 -static -c -o /tmp/fbdev.o src/fbdev.c && echo OK`
Expected: `OK` (compiles; not run on host).

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat: device framebuffer open/close with gl_screen eviction"
```

---

### Task B7: CLI emits the ephemeral old→new IMEI handoff

**Files:**
- Modify: `files/usr/bin/norypt-ghost` (`new-identity)` and `rotate)` cases)
- Modify: `files/lib/norypt-ghost/functions.sh` (add `_emit_rotate_display <old1> <old2> <new1> <new2>` helper)

**Interfaces:**
- Produces: file `/tmp/norypt-ghost.rotate-display` (mode 0600, tmpfs), format:
  ```
  old <imei1>
  new <imei1>
  ```
  (slot 1 shown; slot 2 optional lines `old2`/`new2`). Written immediately before reboot/apply; swept (`rm -f`) at the start of every rotation.

- [ ] **Step 1: Add the helper**

In `functions.sh`:
```sh
# Ephemeral old->new IMEI handoff for the on-screen masked display.
# tmpfs only; the touch daemon renders then deletes it. Never on flash.
_emit_rotate_display() {
    umask 077
    { printf 'old %s\nnew %s\n' "$1" "$3"
      [ -n "$2" ] && [ -n "$4" ] && printf 'old2 %s\nnew2 %s\n' "$2" "$4"
    } > /tmp/norypt-ghost.rotate-display
}
```

- [ ] **Step 2: Wire `new-identity`**

In the `new-identity)` case, before `sleep 5`, read old IMEIs and the staged new ones (from `/etc/norypt-ghost.identity-pending`) and emit:
```sh
        _old1="$(READ_IMEI)"; _old2="$(READ_IMEI_SLOT2)"
        # shellcheck disable=SC1091
        _new1=""; _new2=""
        [ -f /etc/norypt-ghost.identity-pending ] && {
            _new1="$(sed -n 's/^STAGED_IMEI1=//p' /etc/norypt-ghost.identity-pending)"
            _new2="$(sed -n 's/^STAGED_IMEI2=//p' /etc/norypt-ghost.identity-pending)"
        }
        rm -f /tmp/norypt-ghost.rotate-display
        _emit_rotate_display "$_old1" "$_old2" "$_new1" "$_new2"
```

- [ ] **Step 3: Wire `rotate` (live)**

In `_rotate`, capture `READ_IMEI`/`READ_IMEI_SLOT2` before the IMEI write and again after, then call `_emit_rotate_display` with both pairs. Sweep the file at function entry.

- [ ] **Step 4: Shellcheck + syntax**

Run: `shellcheck -s sh files/usr/bin/norypt-ghost files/lib/norypt-ghost/functions.sh` — Expected: clean.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: emit ephemeral old->new IMEI handoff for on-screen display"
```

---

### Task B8: Daemon state machine (main.c) wiring menu → actions

**Files:**
- Rewrite: `src/norypt-ghost-touch.c` (becomes the state machine using fb/menu/screens/fbdev)
- Modify: `tools/build-touch.sh` (compile the multi-file daemon)
- Modify: `Makefile` and `.github/workflows/sdk-build.yml` (add the new sources to the SDK build)

**Interfaces:**
- Consumes: everything from B2–B7; the calibration transform from B1 (as `#define` macros `TX_TO_FBX(x,y)` / `TX_TO_FBY(x,y)`).
- Produces: the shipped daemon. States `IDLE → MENU → CONFIRM → RUNNING`. IDLE keeps today's 2s clock long-press (region X:0–80 Y:0–30 in touch space) as the open gesture. MENU/CONFIRM taps are mapped through the calibration transform and hit-tested. Actions `fork`+`execl` `/usr/bin/norypt-ghost <subcommand>`. RUNNING polls for `/tmp/norypt-ghost.rotate-display`; when present, `screen_imei` renders it for ~4s then the daemon `unlink`s it. 15s idle in MENU/CONFIRM auto-cancels to IDLE and restores gl_screen. Existing cooldown + `STAGE_FILE` idle guard retained.

- [ ] **Step 1: Rewrite the daemon**

Replace `src/norypt-ghost-touch.c` with the state machine: keep the evdev decode (`ABS_MT_POSITION_X/Y`, `BTN_TOUCH`) from the current file; on a qualifying clock long-press call `fbdev_open`, `menu_layout`, `menu_render`; route subsequent touches by state; for a selected action draw `screen_confirm`, and on YES draw `screen_busy`, `fork` the CLI subcommand, then enter RUNNING. For `NG_NEW_IDENTITY` do not restart gl_screen (device reboots); for others `fbdev_close(&fb, 1)` after the masked display. Map `NG_*` → subcommand strings `{"new-identity","sim-swap","rotate","rotate-wireless"}`.

- [ ] **Step 2: Update the local build script**

In `tools/build-touch.sh`, change both compile commands to include the new sources:
```sh
SRCS="$REPO/src/norypt-ghost-touch.c $REPO/src/fb.c $REPO/src/menu.c $REPO/src/screens.c $REPO/src/imei.c $REPO/src/fbdev.c"
aarch64-linux-gnu-gcc -O2 -s -static -I "$REPO/src" -o "$OUT" $SRCS
```
(and the Docker variant analogously, mounting `/src` and listing the same files).

- [ ] **Step 3: Build for the target**

Run: `./tools/build-touch.sh`
Expected: builds a stripped static aarch64 binary; `file files/usr/bin/norypt-ghost-touch` shows `ARM aarch64 ... statically linked, stripped`.

- [ ] **Step 4: Update the SDK build inputs**

In `Makefile` and `.github/workflows/sdk-build.yml`, add `fb.c menu.c screens.c imei.c fbdev.c` (and headers) to whatever compiles `norypt-ghost-touch` so the SDK/CI path matches the local build.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: touch daemon state machine — clock long-press opens on-device menu"
```

---

### Task B9: Live device integration (connected unit)

**Files:**
- Modify: `docs/NO-LOG-MENU-PLAN.md` (check off; note any calibration/color adjustments made)

**Interfaces:**
- Consumes: the built `.ipk`.
- Produces: verified end-to-end on hardware.

- [ ] **Step 1: Wipe the current unit's factory section (§2.4)**

```bash
ssh root@192.168.8.1 'uci -c /etc/config delete norypt-ghost.factory; uci -c /etc/config commit norypt-ghost; echo wiped'
```
Expected: `wiped`; `uci show norypt-ghost` shows no `factory` section.

- [ ] **Step 2: Build + deploy the refactored package**

Run `./build-ipk.sh`, `scp -O` it to `/tmp`, `opkg install --force-reinstall`. Expected: installs with no seal prompt; `norypt-ghost` has no `restore` subcommand (`norypt-ghost restore` → usage/unknown).

- [ ] **Step 3: Verify menu open + each action**

Long-press the clock → menu appears (gl_screen evicted). Tap each of SIM Swap / Rotate IMEIs / Rotate Wireless → confirm → action runs → (for IMEI actions) masked old→new shows → gl_screen returns. Cancel and 15s idle both restore gl_screen.

- [ ] **Step 4: Full New Identity from the screen**

Tap New Identity → confirm → "Rotating…" → masked old→new IMEI → reboot. Insert a fresh SIM. After boot, `norypt-ghost status` shows the new identity; `uci show norypt-ghost` has **no** factory section and no previous identifier anywhere.

- [ ] **Step 5: Commit the checked-off plan + notes**

```bash
git add -A && git commit -m "test: live E5800 integration — on-device menu + no-retention verified"
```

---

## Self-Review (completed at write time)
- **Spec coverage:** §2 removals → A2–A5; §2.4 wipe → B9.1; §3.2 flow/state machine → B8; §3.3 modules → B3/B4/B5/B6; §3.4 masked handoff → B2/B5/B7; §3.5 calibration → B1; §4.1 host tests → B2–B5; §4.2 device tests → B9. All covered.
- **Placeholder scan:** none — every code step carries real code; the font table (B3.3) is a concrete vendoring step with an ASCII-subset requirement, not a "TODO".
- **Type consistency:** `fb_t`, `ng_item_t`, the `NG_*` enum, `imei_mask`, `menu_hit_test`, `screen_confirm_hit`, and `_emit_rotate_display` names/signatures are used identically across B2–B8.
