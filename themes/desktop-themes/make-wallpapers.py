#!/usr/bin/env python3
"""Generates the desktop themes' wallpapers (themes/desktop-themes/README.md) into
desktop/DesktopKit/Sources/DesktopKit/Resources/Wallpapers/. Everything is drawn from
gradients, curves, noise and blur; no third-party imagery. Output is CC0 1.0.
    python3 themes/desktop-themes/make-wallpapers.py [name ...]"""
import os, sys
import numpy as np
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "desktop", "DesktopKit", "Sources", "DesktopKit", "Resources", "Wallpapers")
W, H = 2732, 2048
rng = np.random.default_rng(1998)
ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
u, v = xs / W, ys / H


def hexrgb(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], np.float32)


def vgrad(stops, t):
    """stops: [(pos, '#rrggbb'), ...] -> HxWx3 along t (HxW in 0..1)."""
    pos = np.array([p for p, _ in stops], np.float32)
    cols = np.stack([hexrgb(c) for _, c in stops])
    out = np.empty(t.shape + (3,), np.float32)
    for ch in range(3):
        out[..., ch] = np.interp(t, pos, cols[:, ch])
    return out


def blend(base, color, alpha):
    a = np.clip(alpha, 0, 1)[..., None]
    return base * (1 - a) + np.asarray(color, np.float32) * a


def blur(arr, radius):
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    return np.asarray(img.filter(ImageFilter.GaussianBlur(radius)), np.float32)


def blur_mask(mask, radius):
    img = Image.fromarray(np.clip(mask * 255, 0, 255).astype(np.uint8), "L")
    return np.asarray(img.filter(ImageFilter.GaussianBlur(radius)), np.float32) / 255


def noise(scale=1.0):
    return rng.normal(0, scale, (H, W)).astype(np.float32)


def save(name, arr, quality=86):
    Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8)).save(
        os.path.join(OUT, f"{name}.jpg"), quality=quality, optimize=True, progressive=True)
    print(name)


def meadow():
    """Luna: a clear sky over one rolling green hill."""
    img = vgrad([(0, "#1f5fcf"), (0.45, "#4f95ea"), (0.7, "#a9d2f7")], v)
    clouds = np.zeros((H, W), np.float32)
    for cx, cy, rx, ry in [(0.18, 0.18, 0.13, 0.035), (0.27, 0.16, 0.08, 0.03), (0.66, 0.11, 0.16, 0.04),
                           (0.78, 0.15, 0.09, 0.028), (0.48, 0.27, 0.1, 0.022), (0.9, 0.3, 0.07, 0.02)]:
        clouds = np.maximum(clouds, np.clip(1 - ((u - cx) / rx) ** 2 - ((v - cy) / ry) ** 2, 0, 1))
    img = blend(img, (255, 255, 255), blur_mask(clouds ** 0.6, 38) * 0.85)
    crest = 0.62 - 0.11 * np.clip(np.sin((u * 1.15 + 0.08) * np.pi), 0, 1) ** 1.4 + 0.025 * np.sin(u * 7.0 + 1.3)
    hill = (v > crest).astype(np.float32)
    depth = np.clip((v - crest) / 0.45, 0, 1)
    grass = vgrad([(0, "#7cc441"), (0.25, "#4fa12a"), (1, "#22661a")], depth)
    light = np.clip(1 - np.abs(u - 0.38) * 1.6, 0, 1) * np.clip(1 - depth * 2.2, 0, 1)
    grass = blend(grass, (178, 226, 96), light * 0.45)
    grass += noise(5)[..., None] * np.clip(depth * 2, 0.3, 1)[..., None]
    edge = blur_mask(hill, 2.5)
    img = img * (1 - edge[..., None]) + grass * edge[..., None]
    far = 0.6 - 0.06 * np.sin((u * 1.6 + 0.55) * np.pi)
    back = blur_mask(((v > far) & (v <= crest)).astype(np.float32), 3) * (1 - edge)
    farshade = vgrad([(0, "#9fd16a"), (1, "#5f9e3c")], np.clip((v - far) / 0.12, 0, 1))
    img = img * (1 - back[..., None]) + farshade * back[..., None]
    save("meadow", img)


def ribbons(img, specs, glow):
    for cy, amp, freq, phase, width, color, alpha in specs:
        center = cy + amp * np.sin(u * freq + phase) + 0.04 * np.sin(u * 2.3 + phase * 2)
        d = np.abs(v - center) / width
        band = np.exp(-d ** 2) * (0.6 + 0.4 * np.sin(u * 5 + phase))
        img = blend(img, color, blur_mask(band, glow) * alpha)
    return img


def aurora():
    """Aero: soft glass ribbons over a deep blue."""
    img = vgrad([(0, "#06286e"), (0.55, "#0f5bb5"), (1, "#2b8fe0")], v * 0.8 + u * 0.2)
    img = ribbons(img, [(0.42, 0.1, 3.2, 0.4, 0.05, (190, 235, 255), 0.55),
                        (0.5, 0.12, 2.6, 1.9, 0.03, (255, 255, 255), 0.6),
                        (0.6, 0.08, 3.8, 3.0, 0.07, (120, 210, 255), 0.4),
                        (0.35, 0.06, 4.6, 2.2, 0.02, (220, 245, 255), 0.5)], 18)
    flare = np.exp(-(((u - 0.72) / 0.12) ** 2 + ((v - 0.47) / 0.09) ** 2))
    img = blend(img, (255, 255, 255), flare * 0.5)
    img += noise(1.5)[..., None]
    save("aurora", img)


def aurora_night():
    """Aero Night: green and teal light over a black-blue sky."""
    img = vgrad([(0, "#020409"), (0.6, "#06141f"), (1, "#0b2a36")], v)
    img = ribbons(img, [(0.38, 0.09, 2.4, 0.9, 0.06, (40, 220, 170), 0.5),
                        (0.46, 0.1, 3.1, 2.6, 0.03, (150, 255, 220), 0.45),
                        (0.55, 0.07, 2.0, 4.1, 0.08, (30, 140, 200), 0.4)], 26)
    stars = (rng.random((H, W)) > 0.9993).astype(np.float32) * np.clip(1 - v * 1.4, 0, 1)
    img = blend(img, (255, 255, 255), blur_mask(stars, 1.2) * 3)
    img += noise(1.5)[..., None]
    save("aurora-night", img)


def platinum():
    """Platinum: a quiet periwinkle texture."""
    img = vgrad([(0, "#6d76bb"), (1, "#5a63a6")], v * 0.6 + u * 0.4)
    tex = blur(noise(30)[..., None].repeat(3, 2) + 128, 1.4) - 128
    img += tex * 0.35
    cell = 48
    gx, gy = (xs % cell) / cell, (ys % cell) / cell
    tile = ((np.abs(gx - 0.5) < 0.32) & (np.abs(gy - 0.5) < 0.32)).astype(np.float32)
    img = blend(img, (140, 150, 215), blur_mask(tile, 2) * 0.12)
    save("platinum", img)


def aqua():
    """Aqua: luminous blue swooshes."""
    img = vgrad([(0, "#031a52"), (0.5, "#0a3a8c"), (1, "#1062c2")], v * 0.7 + (1 - u) * 0.3)
    for k, (cy, amp, w, col, a) in enumerate([(0.55, 0.22, 0.09, (60, 170, 255), 0.55),
                                               (0.62, 0.25, 0.04, (170, 225, 255), 0.6),
                                               (0.7, 0.2, 0.12, (20, 110, 230), 0.5),
                                               (0.5, 0.18, 0.02, (235, 250, 255), 0.55)]):
        center = cy - amp * np.sin((u * 0.9 + 0.15 * k) * np.pi)
        band = np.exp(-((v - center) / w) ** 2)
        img = blend(img, col, blur_mask(band, 14) * a)
    img += noise(1.2)[..., None]
    save("aqua", img)


def sonora():
    """Modern Mac: layered warm-to-violet curves."""
    img = vgrad([(0, "#2a1a5e"), (1, "#c2416b")], v * 0.5 + u * 0.5)
    layers = [(0.35, 0.12, "#5b3fb0"), (0.5, 0.1, "#8b4ac9"), (0.62, 0.09, "#e0607e"),
              (0.74, 0.08, "#f39a6b"), (0.86, 0.06, "#ffd08a")]
    for i, (cy, amp, col) in enumerate(layers):
        crest = cy + amp * 0.6 * np.sin(u * 2.4 + 0.9 + i * 0.35)
        mask = blur_mask((v > crest).astype(np.float32), 6)
        shade = vgrad([(0, col), (1, "#1b1036")], np.clip((v - crest) * 1.2, 0, 1) * 0.5)
        img = img * (1 - mask[..., None]) + shade * mask[..., None]
        rim = np.exp(-((v - crest) / 0.006) ** 2)
        img = blend(img, (255, 236, 220), rim * 0.25)
    img += noise(1.2)[..., None]
    save("sonora", img)


def berry():
    """Berry: carbon weave under a blue arc of light."""
    cell = 14
    gx, gy = (xs // cell).astype(int), (ys // cell).astype(int)
    fx, fy = (xs % cell) / cell, (ys % cell) / cell
    weave = np.where((gx + gy) % 2 == 0, np.sin(fx * np.pi), np.sin(fy * np.pi))
    img = np.full((H, W, 3), 14, np.float32) + (weave * 14)[..., None]
    img = blend(img, (0, 0, 0), np.clip(v * 0.6 + np.abs(u - 0.5) * 0.4, 0, 0.8))
    arc = np.abs(np.sqrt(((u - 0.5) * 1.33) ** 2 + (v - 1.35) ** 2) - 0.95)
    img = blend(img, (30, 139, 255), np.exp(-(arc / 0.012) ** 2) * 0.9)
    img = blend(img, (30, 139, 255), blur_mask(np.exp(-(arc / 0.05) ** 2), 30) * 0.45)
    save("berry", img)


def dots(name, bg, dot, accent):
    """Dot Matrix: a halftone grid with one red dot."""
    img = np.zeros((H, W, 3), np.float32) + hexrgb(bg)
    pitch = 40
    cx, cy = (xs % pitch) - pitch / 2, (ys % pitch) - pitch / 2
    gu, gv = (xs // pitch) * pitch / W, (ys // pitch) * pitch / H
    size = 2.6 + 10.5 * np.clip(1 - np.sqrt(((gu - 0.32) * 1.33) ** 2 + (gv - 0.42) ** 2) / 0.55, 0, 1) ** 1.6
    r = np.sqrt(cx ** 2 + cy ** 2)
    mask = np.clip(size - r + 0.5, 0, 1)
    img = blend(img, hexrgb(dot), mask)
    red = np.clip(60 - np.sqrt((xs - W * 0.74) ** 2 + (ys - H * 0.3) ** 2) + 0.5, 0, 1)
    img = blend(img, hexrgb(accent), red)
    save(name, img, quality=90)


ALL = {"meadow": meadow, "aurora": aurora, "aurora-night": aurora_night, "platinum": platinum,
       "aqua": aqua, "sonora": sonora, "berry": berry,
       "dots-light": lambda: dots("dots-light", "#efefef", "#bcbcbc", "#d71921"),
       "dots-dark": lambda: dots("dots-dark", "#050505", "#3a3a3a", "#d71921")}

if __name__ == "__main__":
    for name in sys.argv[1:] or ALL:
        ALL[name]()
