#!/usr/bin/env python3
"""Checks a frame grabbed from the ISH_FAKECAM test pattern (fs/dev_video_fake.c).

usage: check_pattern.py IMAGE [--mirrored]

Samples the centre of each of the eight colour bars and fails if any is more
than TOLERANCE away (per RGB channel) from the expected colour.
"""
import sys

from PIL import Image

BARS = [(255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
        (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0)]
TOLERANCE = 40


def main():
    path = sys.argv[1]
    bars = list(reversed(BARS)) if "--mirrored" in sys.argv else BARS
    image = Image.open(path).convert("RGB")
    width, height = image.size
    worst = 0
    for i, expected in enumerate(bars):
        x = int((i + 0.5) * width / 8)
        y = height * 7 // 16
        got = image.getpixel((x, y))
        diff = max(abs(a - b) for a, b in zip(got, expected))
        worst = max(worst, diff)
        status = "ok" if diff <= TOLERANCE else "MISMATCH"
        if diff > TOLERANCE:
            print(f"bar {i}: expected {expected} got {got} diff {diff} {status}")
    print(f"{path}: {width}x{height} worst channel diff {worst}")
    sys.exit(0 if worst <= TOLERANCE else 1)


if __name__ == "__main__":
    main()
