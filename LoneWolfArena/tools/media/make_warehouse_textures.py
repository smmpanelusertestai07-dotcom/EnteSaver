#!/usr/bin/env python3
"""Procedural textures for the indoor warehouse arena (all tileable, all original):
  floor_concrete.png / floor_concrete_n.png  polished slab concrete, 1 tile = one 4 m slab
  hazard_stripes.png                         worn yellow/black diagonal safety stripes (tiles in x)
  floor_hatch.png                            RGBA decal: yellow hatched floor pad with a border
  signs.png                                  RGBA 4x2 atlas of wall/floor markings (A, B, 1, 2,
                                             warning triangle, arrow, spawn chevrons, "EXIT"-free plate)
usage: python3 tools/media/make_warehouse_textures.py [out_dir]   (needs numpy, scipy, pillow)"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from texlib import blur, fft_noise, normal_map, rgb, save, smoothstep, worley  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "assets", "textures"))
FONT = os.path.normpath(os.path.join(HERE, "..", "..", "assets", "fonts", "title.ttf"))
N = 1024


def R(seed):
    return np.random.default_rng(seed)


def floor_concrete(seed=4040):
    r = R(seed)
    large = fft_noise(N, 1.4, r, fmin=2)
    mid = fft_noise(N, 1.0, r, fmin=12)
    grain = fft_noise(N, 0.3, r, fmin=90)
    stains = smoothstep(1.0, 2.6, fft_noise(N, 1.6, r, fmin=2))
    oil = smoothstep(1.4, 2.8, fft_noise(N, 1.2, r, fmin=5))
    # tyre/scuff streaks: strongly anisotropic noise along x
    scuff = smoothstep(1.2, 2.8, fft_noise(N, 1.1, r, fmin=3, aniso=(0.12, 1.0)))
    F1, F2, _, _, _ = worley(N, 9, r)
    cracks = smoothstep(0.006, 0.0015, F2 - F1) * smoothstep(0.7, 1.6, fft_noise(N, 1.3, r, fmin=1))
    col = np.empty((N, N, 3))
    col[:] = rgb((150, 153, 156))
    tone = 1 + 0.04 * large + 0.025 * mid + 0.035 * grain
    col *= tone[..., None]
    col *= (1 - 0.10 * stains - 0.22 * oil - 0.08 * scuff - 0.35 * cracks)[..., None]
    # sawn control joints on the slab edges (the texture tiles every 4 m)
    j = np.zeros((N, N))
    w = 3
    j[:w, :] = 1
    j[-w:, :] = 1
    j[:, :w] = 1
    j[:, -w:] = 1
    j = np.maximum(j, 0.5 * blur(j, 1.0))
    col *= (1 - 0.45 * j)[..., None]
    h = 0.3 * grain + 0.4 * mid - 1.5 * cracks - 2.0 * j
    return np.clip(col, 0, 1), h


def hazard_stripes(seed=4141):
    r = R(seed)
    h, w = 256, 1024
    yy, xx = np.mgrid[0:h, 0:w].astype(float)
    period = 128.0                       # 8 stripe pairs across 1024 px, 45 degrees
    phase = ((xx + yy) % period) / period
    band = smoothstep(0.49, 0.51, phase) - smoothstep(0.99, 1.0, phase)
    yellow = np.array(rgb((242, 194, 0)))
    black = np.array(rgb((27, 27, 27)))
    col = yellow * (1 - band[..., None]) + black * band[..., None]
    wear = smoothstep(1.3, 2.6, fft_noise(h, 1.0, r, fmin=3, m=w))
    scratches = smoothstep(2.0, 3.2, fft_noise(h, 0.6, r, fmin=20, aniso=(0.15, 1.0), m=w))
    concrete = np.array(rgb((120, 120, 118)))
    k = np.clip(0.75 * wear + 0.6 * scratches, 0, 1)[..., None]
    col = col * (1 - k) + concrete * k
    col *= (1 + 0.05 * fft_noise(h, 0.4, r, fmin=40, m=w))[..., None]
    return np.clip(col, 0, 1)


def floor_hatch(seed=4242):
    r = R(seed)
    yy, xx = np.mgrid[0:N, 0:N].astype(float)
    border = 46.0
    inside = (xx > border) & (xx < N - border) & (yy > border) & (yy < N - border)
    frame = ((xx < 34) | (xx > N - 34) | (yy < 34) | (yy > N - 34)).astype(float)
    period = 96.0
    lines = (((xx - yy) % period) < 22.0).astype(float) * inside
    paint = np.clip(frame + lines, 0, 1)
    paint = np.maximum(paint, 0.0)
    wear = smoothstep(0.9, 2.4, fft_noise(N, 1.0, r, fmin=4))
    chips = smoothstep(2.2, 3.0, fft_noise(N, 0.4, r, fmin=60))
    alpha = paint * (1 - 0.85 * wear) * (1 - chips)
    alpha = np.clip(blur(alpha, 0.8), 0, 1)
    rgba = np.zeros((N, N, 4))
    rgba[..., :3] = rgb((236, 188, 22))
    rgba[..., :3] *= (1 + 0.06 * fft_noise(N, 0.5, r, fmin=30))[..., None]
    rgba[..., 3] = alpha
    return np.clip(rgba, 0, 1)


def signs():
    """4x2 atlas, 256 px cells: A, B, 1, 2 area plates, warning triangle, arrow, chevrons, blank."""
    W, H = 1024, 512
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    font = ImageFont.truetype(FONT, 190) if os.path.exists(FONT) else ImageFont.load_default()
    small = ImageFont.truetype(FONT, 120) if os.path.exists(FONT) else ImageFont.load_default()

    def cell(i):
        return (i % 4) * 256, (i // 4) * 256

    def plate(i, text, bg, fg):
        x, y = cell(i)
        d.rounded_rectangle((x + 14, y + 14, x + 242, y + 242), radius=22, fill=bg, outline=(20, 20, 20, 255), width=8)
        tw = d.textlength(text, font=font)
        d.text((x + 128 - tw / 2, y + 30), text, font=font, fill=fg)

    plate(0, "A", (242, 194, 0, 255), (20, 20, 20, 255))
    plate(1, "B", (242, 194, 0, 255), (20, 20, 20, 255))
    plate(2, "1", (235, 238, 240, 255), (196, 30, 30, 255))
    plate(3, "2", (235, 238, 240, 255), (30, 80, 196, 255))
    x, y = cell(4)
    d.polygon([(x + 128, y + 20), (x + 240, y + 228), (x + 16, y + 228)], fill=(242, 194, 0, 255), outline=(20, 20, 20, 255))
    d.polygon([(x + 128, y + 44), (x + 218, y + 214), (x + 38, y + 214)], outline=(20, 20, 20, 255))
    d.rectangle((x + 117, y + 92, x + 139, y + 170), fill=(20, 20, 20, 255))
    d.ellipse((x + 116, y + 182, x + 140, y + 206), fill=(20, 20, 20, 255))
    x, y = cell(5)
    d.polygon([(x + 30, y + 98), (x + 150, y + 98), (x + 150, y + 50), (x + 232, y + 128), (x + 150, y + 206),
               (x + 150, y + 158), (x + 30, y + 158)], fill=(242, 242, 242, 255))
    x, y = cell(6)
    for k in range(3):
        o = 18 + k * 74
        d.polygon([(x + o, y + 40), (x + o + 44, y + 40), (x + o + 100, y + 128), (x + o + 44, y + 216), (x + o, y + 216),
                   (x + o + 56, y + 128)], fill=(214, 40, 40, 255))
    x, y = cell(7)
    d.rounded_rectangle((x + 14, y + 60, x + 242, y + 196), radius=16, fill=(30, 120, 60, 255), outline=(240, 240, 240, 255), width=6)
    tw = d.textlength("SAFE", font=small)
    d.text((x + 128 - tw / 2, y + 70), "SAFE", font=small, fill=(250, 250, 250, 255))
    return im


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else OUT
    os.makedirs(out, exist_ok=True)
    col, h = floor_concrete()
    save(col, os.path.join(out, "floor_concrete.png"))
    save(normal_map(blur(h, 1.0), 2.0), os.path.join(out, "floor_concrete_n.png"))
    save(hazard_stripes(), os.path.join(out, "hazard_stripes.png"))
    Image.fromarray((floor_hatch() * 255).round().astype(np.uint8), "RGBA").save(os.path.join(out, "floor_hatch.png"), optimize=True)
    signs().save(os.path.join(out, "signs.png"), optimize=True)
    print("warehouse textures written to", out)


if __name__ == "__main__":
    main()
