#ifndef NG_FBDEV_H
#define NG_FBDEV_H

#include "fb.h"

/* Opens /dev/fb0 for direct framebuffer access using a freeze/snapshot/restore
 * model — NOT a kill/restart of gl_screen.
 *
 * The stock display service gl_screen keeps ownership of the panel; we merely
 * suspend it while the menu is up. On open:
 *   1. find gl_screen's PID and SIGSTOP it (freeze — it stops repainting but
 *      stays alive; the USB link it shares is never bounced),
 *   2. open+mmap /dev/fb0 (confirmed 240x320 16bpp RGB565 via
 *      FBIOGET_VSCREENINFO),
 *   3. snapshot the current framebuffer (the stock UI image) into a heap
 *      buffer BEFORE the caller draws over it.
 *
 * On success, out->px/w/h are populated (see fb_t in fb.h) and 0 is returned.
 * On any failure after the SIGSTOP (open/ioctl/geometry mismatch/mmap), the
 * frozen gl_screen is resumed with SIGCONT (so a failed open never leaves the
 * panel stuck), any snapshot is freed, *out is zeroed, and -1 is returned.
 *
 * No system()/ubus/pkill/init.d shell-outs are used — only direct
 * kill(2)/mmap(2) syscalls — so this path emits no SIGCHLD/ECHILD warnings.
 *
 * Device-only: not host-testable (real syscalls against /dev/fb0).
 * Covered by on-device Task B9.
 */
int fbdev_open(fb_t *out);

/* Unmaps the framebuffer opened by fbdev_open and clears *fb. Safe to call
 * with a zeroed/never-opened fb_t (fb->px == NULL is a no-op unmap).
 *
 * restore_gl selects the exit class:
 *   nonzero (LIVE/cancel/timeout): restore the snapshot (the stock UI image)
 *     back into the panel, then SIGCONT gl_screen. It wakes over its own exact
 *     prior image, so its lazy repaint is seamless — no lingering menu frame.
 *   zero (TAKEDOWN — reboot/poweroff): leave the drawn frame up, do NOT restore
 *     the snapshot, and do NOT SIGCONT gl_screen — the device is going down and
 *     the reboot/poweroff tears it all down.
 *
 * The snapshot buffer is always freed here.
 */
void fbdev_close(fb_t *fb, int restore_gl);

#endif
