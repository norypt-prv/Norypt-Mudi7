/*
 * fbdev — device framebuffer open/close with gl_screen eviction.
 *
 * Opens /dev/fb0 directly (240x320, 16bpp RGB565) for the on-device touch
 * menu. Mirrors the eviction sequence used by functions.sh's
 * _screen_splash exactly: procd service delete (stops respawn — gl_screen
 * runs under procd with respawn set), init.d stop, pkill -9, then a short
 * wait for the process to actually exit before touching /dev/fb0.
 *
 * Device-only: uses open/ioctl/mmap directly against /dev/fb0 and shells
 * out to ubus/init.d/pkill. Not host-testable; compiled for the target
 * only. Covered by on-device Task B9.
 */

#include "fbdev.h"

#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define FB_DEVICE     "/dev/fb0"
#define FB_EXPECT_W   240
#define FB_EXPECT_H   320
#define FB_EXPECT_BPP 16

/* Wait up to ~5s for gl_screen to actually exit after being asked to stop
 * — the same bound functions.sh:_screen_splash uses. `pidof` exits
 * nonzero once no matching process remains. */
static void wait_for_gl_screen_exit(void)
{
    int i;
    for (i = 0; i < 5; i++) {
        if (system("pidof gl_screen >/dev/null 2>&1") != 0)
            return;
        sleep(1);
    }
}

/* Restarts gl_screen (the stock touchscreen UI). Shared by fbdev_close and by
 * fbdev_open's failure paths: once eviction has run, any subsequent open error
 * must hand the framebuffer back so a failed open leaves gl_screen running as
 * it found it, rather than dead until reboot. */
static void restart_gl_screen(void)
{
    if (system("/etc/init.d/gl_screen start >/dev/null 2>&1") == -1)
        syslog(LOG_WARNING, "fbdev: exec of gl_screen init.d start failed: %s", strerror(errno));
}

/* Evicts gl_screen so nothing else writes to /dev/fb0 while the menu owns
 * it. Mirrors functions.sh:_screen_splash: procd service delete, init.d
 * stop, pkill -9, then wait for exit. system() failures (couldn't even
 * exec a shell) are logged but non-fatal — the caller still proceeds to
 * open /dev/fb0, which will simply fail on its own if eviction failed. */
static void evict_gl_screen(void)
{
    if (system("ubus call service delete '{\"name\": \"gl_screen\"}' 2>/dev/null") == -1)
        syslog(LOG_WARNING, "fbdev: exec of ubus service delete failed: %s", strerror(errno));
    if (system("/etc/init.d/gl_screen stop >/dev/null 2>&1") == -1)
        syslog(LOG_WARNING, "fbdev: exec of gl_screen init.d stop failed: %s", strerror(errno));
    if (system("pkill -9 gl_screen 2>/dev/null") == -1)
        syslog(LOG_WARNING, "fbdev: exec of pkill gl_screen failed: %s", strerror(errno));
    wait_for_gl_screen_exit();
}

int fbdev_open(fb_t *out)
{
    int fd;
    struct fb_var_screeninfo vinfo;
    size_t map_size;
    void *map;

    if (!out)
        return -1;
    memset(out, 0, sizeof(*out));

    evict_gl_screen();

    fd = open(FB_DEVICE, O_RDWR);
    if (fd < 0) {
        syslog(LOG_ERR, "fbdev: open(%s) failed: %s", FB_DEVICE, strerror(errno));
        restart_gl_screen();
        return -1;
    }

    if (ioctl(fd, FBIOGET_VSCREENINFO, &vinfo) != 0) {
        syslog(LOG_ERR, "fbdev: FBIOGET_VSCREENINFO failed: %s", strerror(errno));
        close(fd);
        restart_gl_screen();
        return -1;
    }

    if (vinfo.xres != FB_EXPECT_W || vinfo.yres != FB_EXPECT_H ||
        vinfo.bits_per_pixel != FB_EXPECT_BPP) {
        syslog(LOG_ERR, "fbdev: unexpected fb geometry %ux%ux%u (expected %dx%dx%d)",
               vinfo.xres, vinfo.yres, vinfo.bits_per_pixel,
               FB_EXPECT_W, FB_EXPECT_H, FB_EXPECT_BPP);
        close(fd);
        restart_gl_screen();
        return -1;
    }

    map_size = (size_t)FB_EXPECT_W * (size_t)FB_EXPECT_H * sizeof(uint16_t);
    map = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        syslog(LOG_ERR, "fbdev: mmap(%zu bytes) failed: %s", map_size, strerror(errno));
        close(fd);
        restart_gl_screen();
        return -1;
    }

    /* The mapping stays valid after the descriptor is closed. */
    close(fd);

    out->px = (uint16_t *)map;
    out->w = FB_EXPECT_W;
    out->h = FB_EXPECT_H;
    return 0;
}

void fbdev_close(fb_t *fb, int restore_gl)
{
    if (fb) {
        if (fb->px) {
            size_t map_size = (size_t)fb->w * (size_t)fb->h * sizeof(uint16_t);
            if (munmap(fb->px, map_size) != 0)
                syslog(LOG_WARNING, "fbdev: munmap failed: %s", strerror(errno));
        }
        fb->px = NULL;
        fb->w = 0;
        fb->h = 0;
    }

    if (restore_gl)
        restart_gl_screen();
}
