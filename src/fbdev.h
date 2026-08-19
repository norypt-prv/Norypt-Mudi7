#ifndef NG_FBDEV_H
#define NG_FBDEV_H

#include "fb.h"

/* Opens /dev/fb0 for direct framebuffer access.
 *
 * Evicts gl_screen first (procd service delete + init.d stop + pkill -9,
 * matching functions.sh's _screen_splash eviction sequence) so nothing
 * else is writing to fb0 while the on-device menu owns it. Confirms the
 * panel is 240x320 16bpp RGB565 via FBIOGET_VSCREENINFO, then mmaps it.
 *
 * On success, out->px/w/h are populated (see fb_t in fb.h) and 0 is
 * returned. On any failure (open/ioctl/geometry mismatch/mmap), *out is
 * zeroed, the failure is logged via syslog, and -1 is returned.
 *
 * Device-only: not host-testable (real syscalls against /dev/fb0).
 * Covered by on-device Task B9.
 */
int fbdev_open(fb_t *out);

/* Unmaps the framebuffer opened by fbdev_open and clears *fb. Safe to call
 * with a zeroed/never-opened fb_t (fb->px == NULL is a no-op unmap).
 *
 * If restore_gl is nonzero, restarts gl_screen (/etc/init.d/gl_screen
 * start) so the normal touchscreen UI returns. Only call restore_gl=1 from
 * user-triggered menu exits — see functions.sh:_screen_restore_display for
 * the equivalent shell-side convention.
 */
void fbdev_close(fb_t *fb, int restore_gl);

#endif
