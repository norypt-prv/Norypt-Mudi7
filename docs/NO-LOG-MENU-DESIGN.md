# Norypt Ghost — No-Retention Model + On-Device Menu (Design)

**Status:** Approved for planning · **Date:** 2026-08-19 · **Target:** GL-iNet GL-E5800 (Mudi 7), OpenWrt 23.05.4 / firmware 4.8.5

This spec covers two coupled changes:

- **Part A — No-retention "ghost" model.** Remove all persistence of prior/factory identity (plaintext *and* sealed). The device keeps only its current identity, changed on demand, never on a schedule.
- **Part B — On-device menu.** Long-pressing the clock opens an interactive menu drawn on the framebuffer that can trigger a full new identity (and the partial rotations) with no computer.

The two ship together because Part B is the operator-facing front-end for the model Part A defines, and both touch the same rotation entry points.

---

## 1. Goals & non-goals

### Goals
1. The device never stores any previous identity — no factory section, no sealed blob, no plaintext, no restore path.
2. Identity is **stable across reboots** and changes **only** on an explicit operator action (on-device menu or CLI).
3. From the device screen alone, the operator can: run a **Full New Identity**, **SIM Swap**, **Rotate IMEIs**, or **Rotate Wireless/System**.
4. During a rotation, the screen shows the **masked old→new IMEI** so the operator can confirm the change — rendered from RAM, never written to flash.

### Non-goals
- No passphrase, no sealing, no factory restore (all removed).
- No persisted identity history of any kind.
- The on-device menu is a **fixed** set of four actions + Cancel; it is not device-configurable.
- No rotation-on-every-boot mode.
- The masked-IMEI display is ephemeral; the device never offers to show or export a full identifier.

---

## 2. Part A — No-retention model

### 2.1 Behavioral contract
- **Capture:** none. Rotations generate new identifiers from the existing pools (`tac_pool.json`, `oui_pool.json`, `profiles.json`) and apply them. No prior value is read-and-saved for restore.
- **Persistence:** the *current* identity persists where it naturally lives — IMEIs in modem NVRAM, MACs/SSIDs/hostname/passwords in UCI (`wireless`, `system`). A plain reboot re-applies the current identity; it does **not** generate a new one.
- **Change:** a new identity appears only via `new-identity`, `rotate`, `rotate-wireless`, or `sim-swap` (from the menu or CLI). Each overwrites the current identity in place; the previous value is discarded, unrecoverable.
- **Boot rotation:** `randomize_on_boot` defaults to `0`. (The staged-apply path used by `new-identity` still runs on the *next* boot after staging, keyed off the stage file — that is how a full rotation applies cleanly across the reboot. It does not imply per-boot regeneration.)

### 2.2 Removals (by file)
| File | Change |
|---|---|
| `files/lib/norypt-ghost/seal.sh` | **Delete.** |
| `files/lib/norypt-ghost/functions.sh` | Remove `_save_factory_state`, `_seal_factory_if_requested`, and any factory-read helpers. Keep `_screen_splash`/`_screen_unsplash` and rotation helpers. |
| `files/usr/bin/norypt-ghost` | Remove the `restore` subcommand and its passphrase/blob logic; repurpose `install` to setup-only (enable services + write default options, no capture); remove the "Factory IMEIs" block from `_print_status`; remove factory/seal sourcing. |
| `files/usr/libexec/norypt-ghost` | Remove the rpcd `restore`/factory actions. |
| `files/www/luci-static/resources/view/norypt_ghost.js` | Remove the "Restore Factory" action and factory-vs-current columns; keep current-identity display and the rotation actions. |
| `build-ipk.sh` (postinst) | Remove the sealing prompt and factory-capture messaging; postinst only enables services and sets defaults. |
| `build-ipk.sh` (prerm) | Remove restore-on-uninstall; prerm only stops/disables services. The unit keeps its current ghost identity after removal. |
| `files/etc/config/*` / defaults | `randomize_on_boot` default `0`. |

### 2.3 Verification that removal is safe
Rotation logic (`identity.sh`, `_rotate`, `_rotate_wireless`) generates values from pools and does not consume factory state functionally — factory keys are read only by `restore` and status display. **Implementation gate:** before deleting, grep-confirm no rotation/apply path reads `norypt-ghost.factory.*`. If any does, that read is replaced with a live source, not the saved factory value.

### 2.4 One-time live wipe (connected unit)
The already-installed unit carries a `norypt-ghost.factory` section (sealed blob + a plaintext leak from the earlier rotation). As an explicit, operator-confirmed step:

```
uci -c /etc/config delete norypt-ghost.factory
uci -c /etc/config commit norypt-ghost
```

⚠️ Irreversible: the true original IMEIs are discarded. This is the intended no-log end state.

---

## 3. Part B — On-device menu

### 3.1 Hardware facts (probed)
- Framebuffer `/dev/fb0`: **240×320, 16bpp RGB565, 480-byte stride**, full frame 153,600 bytes.
- Touch: `chsc_cap_touch` on `event0`, multitouch type-B (`ABS_MT_POSITION_X/Y` + `BTN_TOUCH`).
- **No runtime renderers** (`fbv`/`fbi`/`qrencode`/imagemagick absent) → the daemon must draw everything itself.
- `gl_screen` (procd service, `/usr/bin/gl_screen`) owns `/dev/fb0`; evicted via the existing `ubus service delete` + init `stop` + `pkill` pattern, restarted with `/etc/init.d/gl_screen start`.

### 3.2 Interaction model / state machine
```
IDLE ──clock long-press(2s)──▶ MENU
MENU ──tap item──▶ CONFIRM(item)          MENU ──tap Cancel / 15s idle──▶ IDLE(restore gl_screen)
CONFIRM ──[No] / 15s idle──▶ MENU
CONFIRM ──[Yes]──▶ RUNNING(item)
RUNNING ──non-reboot action done──▶ (masked IMEI screen if applicable)──▶ IDLE(restore gl_screen)
RUNNING ──new-identity──▶ "Rotating…" ──▶ masked IMEI screen ──▶ reboot
```
- **Open:** the existing 2s clock long-press (region X:0–80, Y:0–30) now opens the menu instead of firing `sim-swap` directly.
- **Menu screen:** gl_screen evicted; full-screen draw: title bar `NORYPT GHOST` + five stacked button rects (~50px tall on a 320px column): `New Identity`, `SIM Swap`, `Rotate IMEIs`, `Rotate Wireless`, `Cancel`.
- **Select:** a short tap inside a button rect highlights it, then transitions to a confirm screen: `<Action>?  [Yes]  [No]`. New Identity's confirm reads `NEW IDENTITY — full rotation + reboot.  [Yes] [No]`.
- **Running:** draw `Rotating…`. For IMEI-changing actions, draw the **masked old→new** screen (§3.4) for ~4s. Then reboot (`new-identity`) or restart gl_screen (others).
- **Idle timeout:** ~15s with no touch in MENU/CONFIRM auto-cancels and restores gl_screen, so the menu never gets stranded over the normal UI.
- **Re-entrancy:** keep the current cooldown + `STAGE_FILE` idle guard so an in-flight rotation cannot be double-triggered.

### 3.3 Daemon architecture (C, in `src/`)
The daemon (`norypt-ghost-touch`) grows from a single-purpose reader into a small state machine. New pure-C modules, no external deps, built by `tools/build-touch.sh`:
- `fb.c` / `fb.h` — open+`mmap` `/dev/fb0`; primitives `fb_fill_rect`, `fb_text`, `fb_clear`, RGB565 pack; double-buffer in a heap frame, blit on present.
- `font.h` — an embedded **public-domain 8×16 bitmap font** (source-auditable static array; no opaque blob).
- `menu.c` / `menu.h` — menu/confirm model (items + rects), `menu_render`, `menu_hit_test(x,y) → item`.
- `main.c` — the evdev loop + state machine + gl_screen evict/restore + `fork` of `norypt-ghost <subcommand>`.

Actions map 1:1 to existing subcommands — **no new rotation logic**:
`New Identity → new-identity`, `SIM Swap → sim-swap`, `Rotate IMEIs → rotate`, `Rotate Wireless → rotate-wireless`.

### 3.4 Masked-IMEI ephemeral handoff
The CLI already knows both IMEIs at rotation time. It writes them to a **tmpfs** file the daemon renders and deletes:
- File: `/tmp/norypt-ghost.rotate-display` (RAM only), format `old <imei>\nnew <imei>\n`, mode 0600, written by the CLI immediately before applying, deleted by the daemon after rendering (and by the CLI on the next rotation as a safety sweep).
- Masking: show first 6 and last 5 digits, middle replaced by `•` — e.g. `old 385482••••32989 / new 485920••••28423`. Exact keep-counts finalized during on-device legibility tuning.
- Never written to flash; not logged.

### 3.5 Touch↔pixel calibration (implementation gate)
The clock region proves touch coordinates are close to pixel space, but gl_screen may render rotated relative to the framebuffer. **Before button rects are fixed**, capture `event0` while tapping the four corners + center on the live unit to establish the touch→framebuffer transform (axis order, inversion, scale). Button rects and hit-testing use that transform.

### 3.6 gl_screen coexistence
Reuse the proven evict pattern to take `/dev/fb0`; restart gl_screen on menu close and after non-reboot actions. `new-identity` reboots, so the reboot restores the normal UI.

---

## 4. Testing

### 4.1 Host tests (existing `tests/` harness)
Factor the daemon's pure logic so it compiles against an in-memory framebuffer:
- IMEI masking: exact keep/mask counts, short/odd-length inputs.
- Menu hit-testing: representative tap coordinates → expected item; misses outside all rects → none.
- Layout math: rects fit within 240×320, no overlap.
- Font table sanity: every printable ASCII maps to a glyph.
- Part A regression: existing shell/lua suite stays green after removals.

### 4.2 On-device tests (connected unit)
- Touch calibration capture (§3.5).
- Visual check of each screen (menu, each confirm, Rotating…, masked IMEI).
- End-to-end each action; Cancel and idle-timeout both restore gl_screen.
- **No-log assertion:** after a rotation, `uci show norypt-ghost` contains no `factory` section and no previous identifier anywhere on flash.

---

## 5. Rollout
1. Part A refactor + host tests green.
2. Rebuild `.ipk`; on the connected unit, wipe the factory section (§2.4), reinstall, confirm `restore` gone and status clean.
3. Part B daemon: calibrate, implement modules, host tests, then live visual + end-to-end.
4. Final live pass: full New Identity from the screen, new SIM inserted, masked old→new shown, device comes back on the new identity with nothing retained.

## 6. Open items to finalize during implementation
- Exact mask keep-counts (legibility vs. disclosure).
- Font choice (specific public-domain 8×16) and menu color palette in RGB565.
- Whether `install` is retained as a thin setup command or folded entirely into postinst.
