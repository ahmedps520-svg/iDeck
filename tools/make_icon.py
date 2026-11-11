#!/usr/bin/env python3
"""Generates the iDeck app icon (1024x1024 PNG) with no dependencies.

Design: deep black-to-charcoal field, a cyan gradient "deck" (rounded
rectangle with two control dots), matching the app theme.
"""
import math
import struct
import sys
import zlib

W = H = 1024


def lerp(a, b, t):
    return a + (b - a) * t


def rounded_rect_alpha(x, y, cx, cy, hw, hh, r):
    dx = max(abs(x - cx) - (hw - r), 0)
    dy = max(abs(y - cy) - (hh - r), 0)
    d = math.hypot(dx, dy) - r
    return min(1.0, max(0.0, 0.5 - d))  # 1px anti-aliased edge


def circle_alpha(x, y, cx, cy, r):
    return min(1.0, max(0.0, 0.5 - (math.hypot(x - cx, y - cy) - r)))


def pixel(x, y):
    # Background: radial glow from top-right over near-black.
    t = min(1.0, math.hypot(x - W * 0.85, y - H * 0.1) / (W * 1.1))
    bg = (lerp(28, 7, t), lerp(34, 7, t), lerp(44, 10, t))
    # Deck body.
    a = rounded_rect_alpha(x, y, W / 2, H / 2, 360, 210, 110)
    g = (x - 150) / 724
    deck = (lerp(92, 46, g), lerp(204, 115, g), lerp(255, 242, g))
    col = [bg[i] * (1 - a) + deck[i] * a for i in range(3)]
    # Screen cut-out and two thumbsticks.
    s = rounded_rect_alpha(x, y, W / 2, H / 2, 170, 120, 36)
    col = [col[i] * (1 - s) + 10 * s for i in range(3)]
    for cx in (W / 2 - 270, W / 2 + 270):
        c = circle_alpha(x, y, cx, H / 2 + 40, 46)
        col = [col[i] * (1 - c) + 12 * c for i in range(3)]
    return bytes(int(max(0, min(255, v))) for v in col)


def main(out):
    raw = bytearray()
    for y in range(H):
        raw.append(0)
        for x in range(W):
            raw += pixel(x, y)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
    with open(out, "wb") as f:
        f.write(png)
    print(f"wrote {out} ({len(png)} bytes)")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "icon-1024.png")
