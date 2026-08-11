#!/usr/bin/env python3
"""
Generate 240×320 RGB565 splash frames for the Norypt Ghost fb0 display.

Palette follows the Norypt brand: violet #8900ff primary, cyan #00c2ff
secondary, near-black #07090c ground.

Output: ../files/usr/share/norypt-ghost/screens/*.rgb565  (bundled in IPK)
        previews/*.png                                   (dev reference only)

Usage: python3 generate.py
"""

import os
import struct
from PIL import Image, ImageDraw, ImageFont

W, H = 240, 320

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUT_DIR     = os.path.join(SCRIPT_DIR, "../files/usr/share/norypt-ghost/screens")
PREVIEW_DIR = os.path.join(SCRIPT_DIR, "previews")

os.makedirs(OUT_DIR,     exist_ok=True)
os.makedirs(PREVIEW_DIR, exist_ok=True)

# ── Color palette ─────────────────────────────────────────────────────────────
BG      = (7,   9,   12)   # #07090c  Norypt ground
ACCENT  = (137, 0,   255)  # #8900ff  Norypt violet — top bar
ACCENT2 = (0,   194, 255)  # #00c2ff  Norypt cyan   — bottom bar
BRAND   = (155, 140, 255)  # #9b8cff  "NORYPT GHOST" brand label
DIVIDER = (42,  22,  74)   # #2a164a  subtle violet rule
WHITE   = (233, 238, 243)  # #e9eef3  working / neutral status
GREEN   = (130, 244, 230)  # #82f4e6  success / done (brand teal)
AMBER   = (244, 183, 64)   # #f4b740  attention / sim-swap
PURPLE  = (0,   194, 255)  # #00c2ff  restore (cyan — violet is chrome)
GRAY    = (139, 152, 167)  # #8b98a7  secondary text

# ── Font paths ────────────────────────────────────────────────────────────────
_FONT_DIR  = "/usr/share/fonts/truetype/dejavu"
FONT_BOLD  = os.path.join(_FONT_DIR, "DejaVuSans-Bold.ttf")
FONT_REG   = os.path.join(_FONT_DIR, "DejaVuSans.ttf")


def load_font(path, size):
    try:
        return ImageFont.truetype(path, size)
    except Exception:
        return ImageFont.load_default()


def to_rgb565(img):
    """Convert PIL image to RGB565 little-endian bytes (153,600 bytes for 240×320)."""
    data = img.convert("RGB").tobytes()
    out = bytearray(len(data) // 3 * 2)
    j = 0
    for i in range(0, len(data), 3):
        r, g, b = data[i], data[i + 1], data[i + 2]
        v = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
        out[j]     = v & 0xFF
        out[j + 1] = (v >> 8) & 0xFF
        j += 2
    return bytes(out)


def draw_hcenter(draw, text, y, font, color):
    """Draw text horizontally centered at the given y coordinate (top of text)."""
    bbox = draw.textbbox((0, 0), text, font=font)
    w = bbox[2] - bbox[0]
    x = (W - w) / 2
    draw.text((x, y), text, fill=color, font=font)


def make_base():
    """Shared chrome: background, top/bottom bars, brand label, divider."""
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    d.rectangle([0, 0,    W, 4],    fill=ACCENT)   # top bar    — violet
    d.rectangle([0, H-4,  W, H],    fill=ACCENT2)  # bottom bar — cyan

    f_brand = load_font(FONT_REG, 15)
    draw_hcenter(d, "NORYPT GHOST", 18, f_brand, BRAND)

    d.line([20, 46, W - 20, 46], fill=DIVIDER)     # divider under brand

    return img, d


def make_frame(name, main_text, main_color, sub_lines):
    """Render one splash frame and write .rgb565 + .png preview.

    sub_lines: list of (text, font_size, color, gap_before) tuples.
    gap_before is the vertical gap above this line (pixels).
    """
    img, d = make_base()

    f_main = load_font(FONT_BOLD, 36)

    # Pre-load fonts and measure all lines
    rendered = []
    for text, size, color, gap in sub_lines:
        f = load_font(FONT_REG, size)
        bbox = d.textbbox((0, 0), text, font=f)
        h = bbox[3] - bbox[1]
        rendered.append((text, f, color, gap, h))

    main_bbox = d.textbbox((0, 0), main_text, font=f_main)
    main_h    = main_bbox[3] - main_bbox[1]

    block_h = main_h
    for _, _, _, gap, h in rendered:
        block_h += gap + h

    content_top = 55
    content_bot = 285
    main_y = content_top + (content_bot - content_top - block_h) // 2

    draw_hcenter(d, main_text, main_y, f_main, main_color)

    y = main_y + main_h
    for text, f, color, gap, h in rendered:
        y += gap
        draw_hcenter(d, text, y, f, color)
        y += h

    rgb565 = to_rgb565(img)
    assert len(rgb565) == W * H * 2, f"expected {W*H*2} bytes, got {len(rgb565)}"

    out_path     = os.path.join(OUT_DIR,     f"{name}.rgb565")
    preview_path = os.path.join(PREVIEW_DIR, f"{name}.png")

    with open(out_path, "wb") as f:
        f.write(rgb565)
    img.save(preview_path)

    print(f"  {name:<12} {len(rgb565):>7,} bytes  →  {os.path.relpath(out_path)}")


# ── Frame definitions ─────────────────────────────────────────────────────────
# sub_lines entries: (text, font_size, color, gap_before_px)
DIM    = (90,  100, 115)  # #5a6473  dimmer gray for tip lines
RED    = (255, 107, 122)  # #ff6b7a  hard-failure frame
ORANGE = (249, 115, 22)   # #f97316  soft-failure frame (warning)

FRAMES = [
    ("rotating",  "Rotating...",  WHITE,  [
        ("RF Disabled",                    14, GRAY, 14),
        ("New IMEIs Generated",            14, GRAY,  6),
        ("Writing to Modem...",            14, GRAY, 28),
        ("Waiting for Re-registration",    14, GRAY,  6),
        ("Do not power off",               11, DIM,  12),
    ]),
    ("done",      "Done",         GREEN,  [
        ("IMEIs Written to Modem",         14, GRAY, 14),
        ("Re-registering with Carrier",     14, GRAY, 28),
        ("Rotation complete.",             11, DIM,  12),
    ]),
    ("simswap",   "SIM Swap",     AMBER,  [
        ("RF Disabled, Temp IMEIs Set",    14, GRAY, 14),
        ("Automatically Powering Off",     14, GRAY,  6),
        ("Swap SIMs, then power back on",  14, GRAY,  6),
        ("Recommended: Change location",   11, DIM,  12),
        ("between SIM Swaps",              11, DIM,   4),
    ]),
    ("restoring", "Restoring...", PURPLE, [
        ("Factory IMEIs",                  14, GRAY, 14),
        ("MAC Addresses",                  14, GRAY,  6),
        ("SSIDs & WiFi Passwords",         14, GRAY,  6),
        ("Hostname",                       14, GRAY,  6),
        ("Please wait...",                 11, DIM,  12),
    ]),
    ("error",     "Error",        RED,    [
        ("Operation failed.",              14, GRAY, 14),
        ("RF left OFF for privacy.",       14, GRAY,  6),
        ("logread | grep norypt-ghost",      11, DIM,  10),
    ]),
    # warning — soft failure: IMEIs were written but the modem did not
    # re-register within the timeout; it keeps retrying in the background.
    ("warning",   "Warning",      ORANGE, [
        ("Modem did not re-register.",     14, GRAY, 14),
        ("Check connection manually.",     14, GRAY,  6),
        ("logread | grep norypt-ghost",      11, DIM,  10),
    ]),
]

print(f"Generating {len(FRAMES)} frames  ({W}×{H} RGB565, {W*H*2:,} bytes each)")
for args in FRAMES:
    make_frame(*args)

print("Done.")
