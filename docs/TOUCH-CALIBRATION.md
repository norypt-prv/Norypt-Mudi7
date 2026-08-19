# Touch → Framebuffer Calibration (GL-E5800 / Mudi 7)

Task B1. Establishes the transform the on-device menu daemon
(`src/norypt-ghost-touch.c`, macros `TX_TO_FBX`/`TX_TO_FBY`) uses to map a
raw `/dev/input/event0` touch coordinate to a framebuffer pixel.

## Panel
- Framebuffer `/dev/fb0`: **240 × 320**, 16bpp RGB565 (X = 0..239, Y = 0..319).
- Touch device: `chsc_cap_touch` on `event0`, multitouch type-B
  (`ABS_MT_POSITION_X` = 0x35, `ABS_MT_POSITION_Y` = 0x36, `BTN_TOUCH` = 0x14a).
- `struct input_event` is 24 bytes on this aarch64 build (64-bit time fields).

## Live capture (raw `event0`, decoded tap-down points)
| Tapped corner | Touch (x, y) |
|---|---|
| Top-left      | (19, 15)  |
| Top-right     | (213, 21) |
| Bottom-left   | (14, 311) |

## Conclusion — IDENTITY transform
- **X increases left→right** (19 → 213) and **Y increases top→bottom** (15 → 311):
  no axis swap, no inversion.
- Scale is ~1:1 (a right-edge tap read 213 of 239, a bottom-edge tap read 311 of
  319 — the digitizer reports slightly inside the physical edge). Menu targets are
  large full-width buttons (x 8..232, 52 px tall), so the small edge shortfall is
  well within hit tolerance.

Therefore the daemon keeps the identity mapping:
```c
#define TX_TO_FBX(tx, ty) (tx)
#define TX_TO_FBY(tx, ty) (ty)
```
If a future panel revision swaps/inverts axes, change only those two macros
(see the comment block in `src/norypt-ghost-touch.c`).

## Note
The menu-open gesture (2 s long-press of the clock region, touch X:0–80 Y:0–30)
is defined in touch space and is deliberately NOT run through this transform.
