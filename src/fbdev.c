/*
 * fbdev — device framebuffer open/close with gl_screen freeze/snapshot/restore.
 *
 * Opens /dev/fb0 directly (240x320, 16bpp RGB565) for the on-device touch
 * menu. Instead of killing and restarting the stock display service
 * gl_screen (which bounced the shared USB link and left the menu frame
 * lingering on gl_screen's lazy repaint), we FREEZE it:
 *
 *   open  — find gl_screen's PID, SIGSTOP it, mmap fb0, snapshot the current
 *           (stock UI) frame into a heap buffer before the caller draws.
 *   close — for a LIVE/cancel/timeout exit: memcpy the snapshot back into the
 *           panel, then SIGCONT gl_screen (it wakes over its own prior image,
 *           so its lazy repaint is seamless). For a TAKEDOWN exit: leave the
 *           drawn frame up, do NOT restore, do NOT SIGCONT — the device is
 *           going down.
 *
 * PID discovery scans the numeric /proc/PID/comm entries directly (open+read,
 * no fork/system),
 * and gl_screen is suspended/resumed with direct kill(2) syscalls. No
 * system()/ubus/pkill/init.d shell-outs anywhere in this module, so this path
 * never trips the daemon's SIGCHLD handling (no ECHILD "No child processes").
 *
 * Device-only: uses open/ioctl/mmap and kill against real processes and
 * /dev/fb0. Not host-testable; compiled for the target only. Covered by
 * on-device Task B9.
 */

#include "fbdev.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>

#define FB_DEVICE     "/dev/fb0"
#define FB_EXPECT_W   240
#define FB_EXPECT_H   320
#define FB_EXPECT_BPP 16

/* Module-static state. The daemon is single-threaded and runs one menu at a
 * time, so a single frozen PID / snapshot / size is sufficient. */
static pid_t    g_gl_pid;    /* gl_screen PID we SIGSTOP'd (0 = none frozen) */
static uint16_t *g_snapshot; /* heap copy of the stock UI frame (NULL = none) */
static size_t   g_fb_bytes;  /* byte size of the mapped framebuffer/snapshot  */

/* Find the gl_screen process by scanning the numeric /proc/PID/comm entries.
 * No fork/system:
 * just readdir over /proc and read each numeric entry's comm. Returns the PID,
 * or 0 if gl_screen is not running (or /proc can't be read). */
static pid_t find_gl_screen_pid(void)
{
    DIR *proc = opendir("/proc");
    if (!proc)
        return 0;

    pid_t found = 0;
    struct dirent *de;
    while ((de = readdir(proc)) != NULL) {
        const char *p = de->d_name;
        int numeric = 1;
        for (const char *c = p; *c; c++) {
            if (!isdigit((unsigned char)*c)) { numeric = 0; break; }
        }
        if (!numeric || p[0] == '\0')
            continue;

        char path[6 + 256 + 6]; /* "/proc/" + NAME_MAX + "/comm" + NUL */
        snprintf(path, sizeof(path), "/proc/%s/comm", p);
        int fd = open(path, O_RDONLY);
        if (fd < 0)
            continue;

        char comm[64];
        ssize_t n = read(fd, comm, sizeof(comm) - 1);
        close(fd);
        if (n <= 0)
            continue;

        /* comm ends in a trailing newline; trim it before comparing. */
        comm[n] = '\0';
        if (comm[n - 1] == '\n')
            comm[n - 1] = '\0';

        if (strcmp(comm, "gl_screen") == 0) {
            found = (pid_t)strtol(p, NULL, 10);
            break;
        }
    }

    closedir(proc);
    return found;
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

    /* Freeze gl_screen so it stops repainting the panel while we own it. It
     * stays alive (no kill/restart), so the shared USB link is never bounced. */
    g_gl_pid = find_gl_screen_pid();
    if (g_gl_pid > 0 && kill(g_gl_pid, SIGSTOP) != 0) {
        syslog(LOG_WARNING, "fbdev: SIGSTOP gl_screen (pid %d) failed: %s",
               (int)g_gl_pid, strerror(errno));
        g_gl_pid = 0;   /* don't try to SIGCONT something we didn't stop */
    }

    fd = open(FB_DEVICE, O_RDWR);
    if (fd < 0) {
        syslog(LOG_ERR, "fbdev: open(%s) failed: %s", FB_DEVICE, strerror(errno));
        goto fail;
    }

    if (ioctl(fd, FBIOGET_VSCREENINFO, &vinfo) != 0) {
        syslog(LOG_ERR, "fbdev: FBIOGET_VSCREENINFO failed: %s", strerror(errno));
        close(fd);
        goto fail;
    }

    if (vinfo.xres != FB_EXPECT_W || vinfo.yres != FB_EXPECT_H ||
        vinfo.bits_per_pixel != FB_EXPECT_BPP) {
        syslog(LOG_ERR, "fbdev: unexpected fb geometry %ux%ux%u (expected %dx%dx%d)",
               vinfo.xres, vinfo.yres, vinfo.bits_per_pixel,
               FB_EXPECT_W, FB_EXPECT_H, FB_EXPECT_BPP);
        close(fd);
        goto fail;
    }

    map_size = (size_t)FB_EXPECT_W * (size_t)FB_EXPECT_H * sizeof(uint16_t);
    map = mmap(NULL, map_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        syslog(LOG_ERR, "fbdev: mmap(%zu bytes) failed: %s", map_size, strerror(errno));
        close(fd);
        goto fail;
    }

    /* The mapping stays valid after the descriptor is closed. */
    close(fd);

    g_fb_bytes = map_size;

    /* Snapshot the frozen stock UI frame before the caller draws over it, so
     * a live/cancel/timeout close can restore it exactly. A malloc failure is
     * non-fatal — the menu still works; restore is simply skipped on close. */
    g_snapshot = malloc(g_fb_bytes);
    if (g_snapshot)
        memcpy(g_snapshot, map, g_fb_bytes);
    else
        syslog(LOG_WARNING, "fbdev: snapshot malloc(%zu) failed: %s — restore disabled",
               g_fb_bytes, strerror(errno));

    out->px = (uint16_t *)map;
    out->w = FB_EXPECT_W;
    out->h = FB_EXPECT_H;
    return 0;

fail:
    /* Any failure after the SIGSTOP must unfreeze gl_screen — never leave the
     * panel stuck. (With STOP/CONT the failure recovery is simply a SIGCONT.) */
    if (g_gl_pid > 0) {
        kill(g_gl_pid, SIGCONT);
        g_gl_pid = 0;
    }
    free(g_snapshot);
    g_snapshot = NULL;
    g_fb_bytes = 0;
    memset(out, 0, sizeof(*out));
    return -1;
}

void fbdev_close(fb_t *fb, int restore_gl)
{
    if (fb && fb->px) {
        /* LIVE/cancel/timeout: paint the stock UI image back into the panel so
         * gl_screen wakes over its own exact prior frame (seamless lazy
         * repaint). TAKEDOWN: leave the drawn frame up. */
        if (restore_gl && g_snapshot)
            memcpy(fb->px, g_snapshot, g_fb_bytes);

        size_t map_size = (size_t)fb->w * (size_t)fb->h * sizeof(uint16_t);
        if (munmap(fb->px, map_size) != 0)
            syslog(LOG_WARNING, "fbdev: munmap failed: %s", strerror(errno));
    }

    free(g_snapshot);
    g_snapshot = NULL;
    g_fb_bytes = 0;

    /* LIVE: resume gl_screen. TAKEDOWN: leave it frozen and the drawn frame up
     * — the reboot/poweroff tears it all down. */
    if (restore_gl && g_gl_pid > 0)
        kill(g_gl_pid, SIGCONT);
    g_gl_pid = 0;

    if (fb) {
        fb->px = NULL;
        fb->w = 0;
        fb->h = 0;
    }
}
