/*
 * norypt-ghost-touch — on-device touchscreen menu daemon for the GL-E5800.
 *
 * A long-press on the clock area of the stock UI opens a full-screen menu
 * drawn directly to /dev/fb0. The user picks an action, confirms it, and the
 * daemon forks the norypt-ghost CLI to carry it out. State machine:
 *
 *     IDLE ── clock long-press ──▶ MENU ── tap item ──▶ CONFIRM
 *       ▲                           │                      │
 *       │        Cancel / 15s idle ─┘        NO / 15s idle ┘
 *       │                                            │ YES
 *       └──────────── RUNNING ◀──────────────────────┘
 *
 * Reads /dev/input/event0 non-exclusively alongside gl_screen (no EVIOCGRAB),
 * so the stock UI keeps working while the menu is closed.
 *
 * The daemon owns fb0 only while a menu is on screen: fbdev_open() evicts
 * gl_screen on open, fbdev_close(.., 1) restarts it on exit. Actions that take
 * the device down (reboot / poweroff) intentionally do NOT restart gl_screen —
 * they leave the last frame up while the device goes down.
 */

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>
#include <linux/input.h>

#include "fb.h"
#include "fbdev.h"
#include "menu.h"
#include "screens.h"

/* --- TOUCH CALIBRATION (Task B1, tuned live on device) -----------------------
 * Maps a raw touch coordinate (tx,ty) to a framebuffer pixel (x,y). Applied to
 * EVERY touch point used for menu/confirm hit-testing — change the transform in
 * exactly one place here.
 *
 * Default: identity (touch coords ~= framebuffer pixels, 240x320). The
 * clock-region evidence shows touch and pixel space coincide on this panel.
 * If B1 finds an axis swap or inversion, change ONLY these two macros, e.g.
 *   #define TX_TO_FBX(tx,ty) (ty)          // axis swap
 *   #define TX_TO_FBY(tx,ty) (239 - (tx))  // swap + invert
 * -------------------------------------------------------------------------- */
#define TX_TO_FBX(tx, ty) (tx)
#define TX_TO_FBY(tx, ty) (ty)

#define EVENT_DEVICE   "/dev/input/event0"
#define STAGE_FILE     "/tmp/norypt-ghost-sim-swap.stage"
#define DISPLAY_FILE   "/tmp/norypt-ghost.rotate-display"
#define CLI_PATH       "/usr/bin/norypt-ghost"

#define HOLD_MS            2000   /* clock hold required to open the menu    */
#define COOLDOWN_SECS      10     /* min gap between menu opens              */
#define IDLE_TIMEOUT_MS    15000  /* auto-cancel MENU/CONFIRM after silence  */
#define RUNNING_WATCH_MS   4000   /* watch for the IMEI handoff file         */
#define RUNNING_POLL_MS    200    /* handoff poll granularity                */
#define IMEI_HOLD_MS       4000   /* keep the masked-IMEI frame on screen    */

/* Clock region (top-left status bar) in TOUCH coordinates — confirmed via live
 * evdev capture, tap at X=28 Y=15. This is the menu-open gesture and is NOT run
 * through the calibration transform (it is defined in touch space). */
#define X_MIN    0
#define X_MAX   80
#define Y_MIN    0
#define Y_MAX   30

/* Per-menu-item wiring, indexed by the NG_* enum from menu.h.
 * subcmd  — argv[1] passed to the norypt-ghost CLI (NULL for Cancel).
 * title   — confirm-screen heading.
 * takedown — 1 if the action takes the device down (reboot/poweroff): leave the
 *            last frame up and do NOT restart gl_screen. 0 = live, restart it. */
static const struct {
    const char *subcmd;
    const char *title;
    int takedown;
} ACTIONS[NG_ITEM_COUNT] = {
    [NG_NEW_IDENTITY]    = { "new-identity",    "New Identity (REBOOTS)", 1 },
    [NG_SIM_SWAP]        = { "sim-swap",        "SIM Swap (POWERS OFF)",  1 },
    [NG_ROTATE_IMEI]     = { "rotate",          "Rotate IMEIs",           0 },
    [NG_ROTATE_WIRELESS] = { "rotate-wireless", "Rotate Wireless",        0 },
    [NG_CANCEL]          = { NULL,              NULL,                     0 },
};

enum { ST_IDLE, ST_MENU, ST_CONFIRM };

static int in_region(int x, int y)
{
    return x >= X_MIN && x <= X_MAX && y >= Y_MIN && y <= Y_MAX;
}

static long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static void sleep_ms(int ms)
{
    struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000 };
    nanosleep(&ts, NULL);
}

/* Fork+exec the norypt-ghost CLI with one subcommand. Child detaches via
 * setsid() so it survives independently of the daemon. */
static void run_action(const char *subcmd)
{
    pid_t pid = fork();
    if (pid == 0) {
        setsid();
        execl(CLI_PATH, "norypt-ghost", subcmd, (char *)NULL);
        syslog(LOG_ERR, "execl %s %s failed", CLI_PATH, subcmd);
        _exit(1);
    } else if (pid < 0) {
        syslog(LOG_ERR, "fork failed for %s", subcmd);
    }
}

/* Parse the slot-1 old/new IMEIs out of the tmpfs handoff file. Lines are
 * "old <imei>" / "new <imei>" (optional "old2"/"new2" for the second slot,
 * which this masked display ignores). Returns 1 if both were found. */
static int read_handoff(char *old, size_t old_sz, char *new, size_t new_sz)
{
    FILE *f = fopen(DISPLAY_FILE, "r");
    if (!f)
        return 0;

    old[0] = '\0';
    new[0] = '\0';
    char key[16], val[64];
    char line[128];
    while (fgets(line, sizeof(line), f)) {
        if (sscanf(line, "%15s %63s", key, val) != 2)
            continue;
        if (strcmp(key, "old") == 0)
            snprintf(old, old_sz, "%s", val);
        else if (strcmp(key, "new") == 0)
            snprintf(new, new_sz, "%s", val);
    }
    fclose(f);
    return old[0] && new[0];
}

/* RUNNING state: show progress, watch a few seconds for the masked-IMEI handoff
 * file, render it if it appears, then hand the framebuffer back per action
 * class. Only new-identity and rotate emit the handoff; the others just show
 * "Rotating..." for the watch window and then close. */
static void run_state(fb_t *fb, int item)
{
    screen_busy(fb, "Rotating...");
    run_action(ACTIONS[item].subcmd);

    char old[64], new[64];
    int shown = 0;
    for (int waited = 0; waited < RUNNING_WATCH_MS; waited += RUNNING_POLL_MS) {
        if (access(DISPLAY_FILE, F_OK) == 0 &&
            read_handoff(old, sizeof(old), new, sizeof(new))) {
            screen_imei(fb, old, new);
            unlink(DISPLAY_FILE);
            shown = 1;
            break;
        }
        sleep_ms(RUNNING_POLL_MS);
    }

    if (shown)
        sleep_ms(IMEI_HOLD_MS);  /* hold the masked IMEIs on screen */

    if (ACTIONS[item].takedown) {
        /* Reboot / poweroff: leave the last frame up, do NOT restart gl_screen.
         * fbdev_close(.., 0) unmaps our view (leaving fb memory as drawn) so
         * the daemon can return to IDLE cleanly while the device goes down. */
        syslog(LOG_NOTICE, "%s dispatched — leaving frame up, device going down",
               ACTIONS[item].subcmd);
        fbdev_close(fb, 0);
    } else {
        /* Live action: restore the stock UI. */
        fbdev_close(fb, 1);
    }
}

int main(void)
{
    openlog("norypt-ghost-touch", LOG_PID, LOG_DAEMON);

    /* Ignore SIGCHLD so forked children are reaped automatically. */
    signal(SIGCHLD, SIG_IGN);

    int fd = open(EVENT_DEVICE, O_RDONLY);
    if (fd < 0) {
        syslog(LOG_ERR, "cannot open %s: check /proc/gl-hw-info/screen", EVENT_DEVICE);
        return 1;
    }

    syslog(LOG_INFO, "watching %s — clock region X:%d-%d Y:%d-%d opens the menu",
           EVENT_DEVICE, X_MIN, X_MAX, Y_MIN, Y_MAX);

    struct input_event ev;
    int cur_x = -1, cur_y = -1;
    int press_x = -1, press_y = -1;
    struct timeval press_time = {0, 0};
    time_t last_open = 0;

    int state = ST_IDLE;
    fb_t fb = {0};
    ng_item_t items[NG_ITEM_COUNT];
    int pending = -1;             /* selected item awaiting CONFIRM */
    long menu_activity = 0;       /* last input time in MENU/CONFIRM (ms) */

    for (;;) {
        struct pollfd pfd = { .fd = fd, .events = POLLIN, .revents = 0 };
        int timeout = -1;
        if (state == ST_MENU || state == ST_CONFIRM) {
            long rem = IDLE_TIMEOUT_MS - (now_ms() - menu_activity);
            timeout = rem > 0 ? (int)rem : 0;
        }

        int pr = poll(&pfd, 1, timeout);
        if (pr < 0) {
            if (errno == EINTR)
                continue;
            syslog(LOG_ERR, "poll failed: %s", strerror(errno));
            break;
        }
        if (pr == 0) {
            /* Idle timeout — only armed in MENU/CONFIRM. */
            if (state == ST_MENU || state == ST_CONFIRM) {
                syslog(LOG_INFO, "menu idle %dms — auto-cancel", IDLE_TIMEOUT_MS);
                fbdev_close(&fb, 1);
                state = ST_IDLE;
                pending = -1;
            }
            continue;
        }

        ssize_t n = read(fd, &ev, sizeof(ev));
        if (n != (ssize_t)sizeof(ev)) {
            if (n < 0 && errno == EINTR)
                continue;
            syslog(LOG_WARNING, "read loop ended — %s closed or error", EVENT_DEVICE);
            break;
        }

        if (state == ST_MENU || state == ST_CONFIRM)
            menu_activity = now_ms();

        if (ev.type == EV_ABS) {
            if (ev.code == ABS_MT_POSITION_X)
                cur_x = ev.value;
            else if (ev.code == ABS_MT_POSITION_Y)
                cur_y = ev.value;
            continue;
        }
        if (ev.type != EV_KEY || ev.code != BTN_TOUCH)
            continue;

        if (ev.value == 1) {
            /* Finger down — record where and when. */
            press_x = cur_x;
            press_y = cur_y;
            press_time = ev.time;
            continue;
        }
        if (ev.value != 0 || press_x < 0)
            continue;

        /* Finger up — resolve the gesture for the current state. */
        int tx = press_x, ty = press_y;
        press_x = -1;
        press_y = -1;

        if (state == ST_IDLE) {
            long hold_ms = (ev.time.tv_sec  - press_time.tv_sec)  * 1000 +
                           (ev.time.tv_usec - press_time.tv_usec) / 1000;
            time_t now = time(NULL);
            int in_zone = in_region(tx, ty) && in_region(cur_x, cur_y);
            int held    = hold_ms >= HOLD_MS;
            int cooled  = (now - last_open) >= COOLDOWN_SECS;
            int idle    = access(STAGE_FILE, F_OK) != 0;

            if (in_zone && held && cooled && idle) {
                if (fbdev_open(&fb) != 0) {
                    syslog(LOG_ERR, "fbdev_open failed — staying idle");
                    continue;
                }
                last_open = now;
                menu_layout(items);
                menu_render(&fb, items, NG_ITEM_COUNT, -1);
                state = ST_MENU;
                menu_activity = now_ms();
                syslog(LOG_NOTICE, "clock long-press (%ldms) — menu opened", hold_ms);
            } else if (in_zone && !idle) {
                syslog(LOG_NOTICE, "long-press ignored — sim-swap already staged");
            } else if (in_zone && !cooled) {
                syslog(LOG_INFO, "long-press ignored — cooldown active");
            }
            continue;
        }

        /* MENU / CONFIRM taps are mapped from touch space to pixels. */
        int fx = TX_TO_FBX(tx, ty);
        int fy = TX_TO_FBY(tx, ty);

        if (state == ST_MENU) {
            int hit = menu_hit_test(items, NG_ITEM_COUNT, fx, fy);
            if (hit < 0)
                continue;
            if (hit == NG_CANCEL) {
                syslog(LOG_INFO, "menu: Cancel");
                fbdev_close(&fb, 1);
                state = ST_IDLE;
                continue;
            }
            pending = hit;
            screen_confirm(&fb, ACTIONS[hit].title, 0);
            state = ST_CONFIRM;
            syslog(LOG_INFO, "menu: selected %s", ACTIONS[hit].subcmd);
            continue;
        }

        /* ST_CONFIRM */
        int c = screen_confirm_hit(fx, fy);
        if (c < 0)
            continue;                 /* missed both buttons — ignore */
        if (c == 0) {
            /* NO — back to the menu. */
            menu_render(&fb, items, NG_ITEM_COUNT, -1);
            state = ST_MENU;
            continue;
        }
        /* YES — run it. run_state() closes the framebuffer per action class. */
        syslog(LOG_NOTICE, "confirm: YES — running %s", ACTIONS[pending].subcmd);
        run_state(&fb, pending);
        state = ST_IDLE;
        pending = -1;
    }

    fbdev_close(&fb, 1);
    close(fd);
    closelog();
    return 0;
}
