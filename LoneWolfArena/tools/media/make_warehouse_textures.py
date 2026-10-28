#!/usr/bin/env python3
"""Procedural textures for the indoor warehouse arena (all tileable, all original):
  floor_concrete.png / floor_concrete_n.png  polished slab concrete, 1 tile = one 4 m slab
  hazard_stripes.png                         worn yellow/black diagonal safety stripes (tiles in x)
  floor_hatch.png                            RGBA decal: yellow hatched floor pad with a border
  signs.png                                  RGBA 4x2 atlas of wall/floor markings (A, B, 1, 2,
                                             warning triangle, arrow, spawn chevrons, "EXIT"-free plate)
  container_paint.png                        near-white container paint (multiplied by a per-instance
                                             colour): 1 tile = 4 m wide x one container height (V=0 top
                                             edge, V=1 bottom edge), rust spots, top-edge rust streaks,
                                             dirt toward the bottom
  diamond_plate.png / diamond_plate_n.png    steel tread plate for ramps, 1 tile = 1 m
  wall_grime.png                             multiply layer for the corrugated wall bays: 1 tile = one
                                             6 x 9 m bay (V=0 top), streaks under the windows and the
                                             girt, dirty base
  crate_wood.png                             weathered brown crate boards (8 boards per tile)
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


def container_paint(seed=4343):
    """Paint layer for the shipping containers. Width = 4 m (tiles in x), height = one container
    (2.591 m, top edge at row 0). Mostly near-white so the instance colour shows through."""
    r = R(seed)
    n = 1024
    yy = np.linspace(0.0, 1.0, n)[:, None] * np.ones((1, n))      # 0 = top edge, 1 = bottom edge
    base = 0.93 + 0.025 * fft_noise(n, 1.5, r, fmin=2) + 0.012 * fft_noise(n, 0.8, r, fmin=24)
    # sun-faded chalky patches
    fade = smoothstep(0.8, 2.2, fft_noise(n, 1.4, r, fmin=2))
    base = base + 0.05 * fade
    col = np.repeat(base[..., None], 3, axis=2)
    # rust: blotches (worley cells + noise threshold), more near the bottom and the top edge
    F1, F2, _, _, _ = worley(n, 7, r)
    blotch_noise = fft_noise(n, 1.2, r, fmin=3)
    edge_bias = 0.9 * smoothstep(0.85, 1.0, yy) + 0.7 * smoothstep(0.08, 0.0, yy)
    rust_amt = smoothstep(1.55, 2.4, blotch_noise + edge_bias + 0.6 * smoothstep(0.35, 0.05, F1))
    rust_amt = np.clip(rust_amt * (0.75 + 0.25 * fft_noise(n, 0.4, r, fmin=60)), 0, 1)
    # streaks running down from the top rail (anisotropic noise, fading with height)
    streak = fft_noise(n, 1.0, r, fmin=4, aniso=(1.0, 14.0))
    streak_amt = smoothstep(0.9, 2.2, streak) * np.exp(-yy * 3.2)
    drips = smoothstep(1.7, 2.6, fft_noise(n, 0.9, r, fmin=6, aniso=(1.0, 20.0))) * smoothstep(0.75, 0.2, yy)
    rust_col = rgb((150, 82, 44))
    k = np.clip(0.85 * rust_amt + 0.55 * streak_amt + 0.45 * drips, 0, 1)[..., None]
    col = col * (1 - k) + rust_col * k
    # grime: darker toward the bottom (splashes), slightly darker under the top rail
    grime = 0.16 * smoothstep(0.7, 1.0, yy) * (0.6 + 0.4 * smoothstep(-1.0, 1.5, fft_noise(n, 1.1, r, fmin=4)))
    grime += 0.08 * smoothstep(0.035, 0.0, yy)
    col *= (1 - grime)[..., None]
    # a few light scratches
    scratches = smoothstep(2.6, 3.4, fft_noise(n, 0.5, r, fmin=40, aniso=(12.0, 1.0)))
    col = col * (1 - 0.35 * scratches[..., None]) + 0.35 * scratches[..., None] * 0.98
    return np.clip(col, 0, 1)


def diamond_plate(seed=4444):
    """Steel tread plate: raised lozenges alternating +-45 deg on a 64 px grid (1 tile = 1 m)."""
    r = R(seed)
    n = 512
    cell = 64.0
    yy, xx = np.mgrid[0:n, 0:n].astype(float)
    cx = np.floor(xx / cell)
    cy = np.floor(yy / cell)
    lx = xx - (cx + 0.5) * cell
    ly = yy - (cy + 0.5) * cell
    odd = ((cx + cy) % 2) == 1
    a = np.where(odd, 1.0, -1.0)
    u = (lx + a * ly) / np.sqrt(2.0)          # along the lozenge
    v = (lx - a * ly) / np.sqrt(2.0)          # across
    d = np.sqrt((u / 22.0) ** 2 + (v / 5.5) ** 2)
    h = smoothstep(1.0, 0.55, d)              # raised bar profile
    wear = smoothstep(0.6, 2.2, fft_noise(n, 1.2, r, fmin=2))
    grain = fft_noise(n, 0.4, r, fmin=60)
    base = 0.5 + 0.035 * fft_noise(n, 1.3, r, fmin=2) + 0.02 * grain
    col = np.repeat(base[..., None], 3, axis=2) * rgb((232, 238, 246))
    # worn bright tops of the bars, darker grime between them
    col = col * (1 + 0.55 * h[..., None] * (0.6 + 0.4 * wear[..., None]))
    col = col * (1 - 0.18 * (1 - h[..., None]) * smoothstep(-0.5, 1.5, fft_noise(n, 1.0, r, fmin=3))[..., None])
    scratches = smoothstep(2.4, 3.3, fft_noise(n, 0.5, r, fmin=30, aniso=(10.0, 1.0)))
    col = col + 0.12 * scratches[..., None]
    height = 2.2 * h + 0.15 * grain
    return np.clip(col, 0, 1), height


def wall_grime():
    """Multiply layer for one corrugated wall bay (6 m wide x 9 m tall, row 0 = top of the wall)."""
    r = R(4545)
    w, h = 512, 768
    yy = np.linspace(9.0, 0.0, h)[:, None] * np.ones((1, w))      # metres above the floor
    col = 0.95 + 0.02 * fft_noise(h, 1.4, r, fmin=2, m=w)
    streaks = fft_noise(h, 0.9, r, fmin=5, aniso=(1.0, 12.0), m=w)
    col -= 0.05 * smoothstep(0.6, 2.2, streaks)
    # runs below the window sills (6.1 m) and below the girt ledge (2.6 m)
    runs = smoothstep(1.0, 2.6, fft_noise(h, 1.0, r, fmin=8, aniso=(1.0, 16.0), m=w))
    below_sill = smoothstep(6.15, 5.9, yy) * np.exp(-np.maximum(6.1 - yy, 0) / 1.4)
    below_girt = smoothstep(2.55, 2.4, yy) * np.exp(-np.maximum(2.5 - yy, 0) / 0.9)
    col -= 0.16 * runs * (below_sill + below_girt)
    # dirty base: splash zone up to ~0.9 m, darker in the bottom 0.25 m
    splash = smoothstep(0.95, 0.0, yy) * (0.55 + 0.45 * smoothstep(-1.0, 1.5, fft_noise(h, 1.2, r, fmin=6, m=w)))
    col -= 0.2 * splash + 0.1 * smoothstep(0.3, 0.0, yy)
    # soot under the roof
    col -= 0.1 * smoothstep(8.2, 9.0, yy)
    out = np.repeat(np.clip(col, 0, 1)[..., None], 3, axis=2)
    out *= rgb((255, 252, 246))
    return np.clip(out, 0, 1)


def crate_wood(seed=4646):
    """Weathered brown crate boards (8 horizontal boards per tile), tiles in x and y."""
    r = R(seed)
    n = 512
    boards = 8
    yy, xx = np.mgrid[0:n, 0:n].astype(float)
    bh = n / boards
    idx = np.floor(yy / bh).astype(int)
    fy = (yy % bh) / bh
    tone = r.uniform(0.82, 1.12, boards)[idx]
    hue = r.uniform(-0.05, 0.05, boards)[idx]
    grain = fft_noise(n, 0.9, r, fmin=3, aniso=(14.0, 1.0))
    fine = fft_noise(n, 0.5, r, fmin=40, aniso=(10.0, 1.0))
    weather = smoothstep(0.4, 2.0, fft_noise(n, 1.3, r, fmin=2))
    base = np.empty((n, n, 3))
    base[:] = rgb((138, 98, 64))
    base[..., 0] *= 1 + hue
    base[..., 2] *= 1 - hue
    v = tone * (1 + 0.1 * grain + 0.05 * fine)
    col = base * v[..., None]
    grey = rgb((128, 120, 108))
    col = col * (1 - 0.35 * weather[..., None]) + grey * (0.35 * weather[..., None]) * v[..., None]
    # dark gaps between boards + slightly darker board edges
    gap = smoothstep(0.06, 0.0, fy) + smoothstep(0.94, 1.0, fy)
    edge = smoothstep(0.18, 0.0, fy) + smoothstep(0.82, 1.0, fy)
    col *= (1 - 0.55 * np.clip(gap, 0, 1) - 0.12 * np.clip(edge, 0, 1))[..., None]
    # a few knots
    F1, _, _, _, _ = worley(n, 5, r)
    knots = smoothstep(0.09, 0.03, F1) * (fft_noise(n, 1.0, r, fmin=2) > 0.6)
    col *= (1 - 0.35 * knots)[..., None]
    return np.clip(col, 0, 1)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else OUT
    os.makedirs(out, exist_ok=True)
    col, h = floor_concrete()
    save(col, os.path.join(out, "floor_concrete.png"))
    save(normal_map(blur(h, 1.0), 2.0), os.path.join(out, "floor_concrete_n.png"))
    save(hazard_stripes(), os.path.join(out, "hazard_stripes.png"))
    Image.fromarray((floor_hatch() * 255).round().astype(np.uint8), "RGBA").save(os.path.join(out, "floor_hatch.png"), optimize=True)
    signs().save(os.path.join(out, "signs.png"), optimize=True)
    save(container_paint(), os.path.join(out, "container_paint.png"))
    dcol, dh = diamond_plate()
    save(dcol, os.path.join(out, "diamond_plate.png"))
    save(normal_map(blur(dh, 1.2), 1.6), os.path.join(out, "diamond_plate_n.png"))
    save(wall_grime(), os.path.join(out, "wall_grime.png"))
    save(crate_wood(), os.path.join(out, "crate_wood.png"))
    print("warehouse textures written to", out)


if __name__ == "__main__":
    main()
