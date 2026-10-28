"""Procedural seamless textures for Lone Wolf Arena.

Usage: python3 make_textures.py [out_dir] [name ...]
Writes 1024x1024 tileable albedo/normal maps, FX sprites and _preview.png.
"""
from __future__ import annotations

import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from texlib import (WrapCanvas, ao_from_height, blur, fft_noise, lerp, norm01, normal_map, palette,
                    rgb, save, scatter_ellipses, seam_score, smoothstep, warp, worley)

N = 1024
ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT = os.path.join(ROOT, "assets", "textures")
FONT = os.path.join(ROOT, "assets", "fonts", "Rajdhani-SemiBold.ttf")


def R(seed):
    return np.random.default_rng(seed)


def mul(col, f):
    return col * np.asarray(f)[..., None]


# ----------------------------------------------------------------------------
# concrete
# ----------------------------------------------------------------------------
def concrete(seed=101):
    r = R(seed)
    large = fft_noise(N, 1.3, r, fmin=2)
    mid = fft_noise(N, 1.0, r, fmin=10)
    grain = fft_noise(N, 0.25, r, fmin=80)
    F1, _, ID, _, _ = worley(N, 120, r)
    k = 120 * 120
    rad = r.uniform(0.05, 0.2, k)[ID]
    pits = smoothstep(rad, rad * 0.45, F1) * (r.random(k) < 0.3)[ID]
    F1b, _, IDb, _, _ = worley(N, 36, r)
    kb = 36 * 36
    radb = r.uniform(0.04, 0.11, kb)[IDb]
    bubbles = smoothstep(radb, radb * 0.55, F1b) * (r.random(kb) < 0.22)[IDb]
    agg_cov, agg_dome, agg_id, _, _ = scatter_ellipses(N, 200, r, 0.22, 0.12, 0.3, amax=1.6)
    agg_tone = np.where(agg_id >= 0, (r.uniform(-1, 1, 200 * 200))[np.maximum(agg_id, 0)], 0)
    stains = smoothstep(0.8, 2.2, fft_noise(N, 1.5, r, fmin=2))
    dirt = smoothstep(0.4, 2.2, fft_noise(N, 1.1, r, fmin=4))
    wx = fft_noise(N, 1.3, r, fmin=2) * 22
    wy = fft_noise(N, 1.3, r, fmin=2) * 22
    C1, C2, _, _, _ = worley(N, 5, r, dx=wx, dy=wy)
    cmask = smoothstep(0.55, 1.2, fft_noise(N, 1.3, r, fmin=1))
    cracks = smoothstep(0.0075, 0.0015, C2 - C1) * cmask
    cracks = np.maximum(cracks, 0.5 * blur(cracks, 1.2))

    col = np.empty((N, N, 3))
    col[:] = rgb((160, 158, 152))
    tone = 1 + 0.035 * large + 0.025 * mid + 0.05 * grain + 0.09 * agg_cov * agg_tone
    col = mul(col, tone)
    warm = fft_noise(N, 1.4, r, fmin=2) * 0.008
    col[..., 0] += warm
    col[..., 2] -= warm
    col = mul(col, 1 - 0.07 * stains - 0.04 * dirt)
    col = mul(col, 1 - 0.38 * pits - 0.32 * bubbles - 0.5 * cracks)
    h = 0.35 * grain + 0.5 * mid + 0.4 * agg_dome * agg_cov - 1.4 * pits - 2.2 * bubbles - 1.8 * cracks
    return np.clip(col, 0, 1), h


# ----------------------------------------------------------------------------
# asphalt
# ----------------------------------------------------------------------------
def asphalt(seed=202):
    r = R(seed)
    base = fft_noise(N, 1.25, r, fmin=2)
    sand = fft_noise(N, 0.0, r, fmin=150)
    col = np.empty((N, N, 3))
    col[:] = rgb((44, 46, 50))
    col = mul(col, 1 + 0.07 * base + 0.08 * sand)
    h = 0.15 * sand
    for cells, pres, rmin, rmax, light_p in [(220, 0.9, 0.34, 0.52, 0.07), (96, 0.3, 0.3, 0.46, 0.12)]:
        wx = fft_noise(N, 1.5, r, fmin=2, fmax=cells * 0.6) * (N / cells) * 0.12
        wy = fft_noise(N, 1.5, r, fmin=2, fmax=cells * 0.6) * (N / cells) * 0.12
        cov, dome, ID, U, V = scatter_ellipses(N, cells, r, pres, rmin, rmax, amax=1.7, dx=wx, dy=wy)
        k = cells * cells
        light = r.random(k) < light_p
        bright = np.where(light, r.uniform(0.3, 0.4, k), r.uniform(0.14, 0.25, k))
        warmth = r.uniform(-0.015, 0.025, k)
        idc = np.maximum(ID, 0)
        b = bright[idc]
        w = warmth[idc]
        stone = np.stack([b + w, b, b - w * 0.6], -1)
        facet = 1 + 0.12 * np.sign(U + 0.3 * V) * (np.abs(U) > 0.2)
        stone = mul(stone, (0.9 + 0.14 * dome) * facet)
        col = lerp(col, stone, cov * 0.95)
        h = h + dome * cov * (N / cells) * 0.2
    wear = smoothstep(0.5, 2.0, fft_noise(N, 1.4, r, fmin=2))
    col = col + 0.045 * wear[..., None]
    oil = smoothstep(1.0, 2.3, fft_noise(N, 1.6, r, fmin=2))
    col = mul(col, 1 - 0.2 * oil)
    wx = fft_noise(N, 1.3, r, fmin=2) * 30
    wy = fft_noise(N, 1.3, r, fmin=2) * 30
    C1, C2, _, _, _ = worley(N, 4, r, dx=wx, dy=wy)
    cracks = smoothstep(0.008, 0.002, C2 - C1) * smoothstep(0.7, 1.3, fft_noise(N, 1.3, r, fmin=1))
    col = mul(col, 1 - 0.55 * cracks)
    h = h - 2.0 * cracks
    col = mul(col, ao_from_height(h, 2.0, 0.25))
    return np.clip(col, 0, 1), h


# ----------------------------------------------------------------------------
# dirt with pebbles
# ----------------------------------------------------------------------------
STONE_COLS = np.array([(132, 128, 120), (152, 146, 136), (142, 118, 92), (176, 168, 154), (104, 98, 92),
                       (160, 138, 110), (122, 114, 106), (168, 150, 124)], float) / 255.0


def pebble_layer(r, cells, pres, rmin, rmax):
    wx = fft_noise(N, 1.6, r, fmin=2, fmax=cells * 0.5) * (N / cells) * 0.1
    wy = fft_noise(N, 1.6, r, fmin=2, fmax=cells * 0.5) * (N / cells) * 0.1
    cov, dome, ID, U, V = scatter_ellipses(N, cells, r, pres, rmin, rmax, amax=1.8, dx=wx, dy=wy)
    k = cells * cells
    idc = np.maximum(ID, 0)
    cidx = r.integers(0, len(STONE_COLS), k)
    tint = r.uniform(0.85, 1.12, k)
    c = STONE_COLS[cidx[idc]] * tint[idc][..., None]
    speck = fft_noise(N, 0.2, r, fmin=100)
    shade = 0.72 + 0.3 * dome ** 0.7 + 0.04 * speck
    c = mul(c, shade)
    return cov, dome * (N / cells) * rmax * 0.6, c


def dirt(seed=303):
    r = R(seed)
    t = norm01(fft_noise(N, 1.3, r, fmin=2) + 0.45 * fft_noise(N, 0.9, r, fmin=10))
    col = palette(t, [(0.0, (90, 66, 46)), (0.45, (124, 92, 63)), (0.75, (144, 110, 77)), (1.0, (162, 128, 90))])
    sand = fft_noise(N, 0.3, r, fmin=90)
    col = mul(col, 1 + 0.07 * sand)
    damp = smoothstep(0.7, 2.0, fft_noise(N, 1.5, r, fmin=2))
    col = mul(col, 1 - 0.16 * damp)
    clods_cov, clods_dome, _, _, _ = scatter_ellipses(N, 90, r, 0.35, 0.25, 0.45, amax=1.6)
    col = mul(col, 1 + 0.08 * clods_cov * (clods_dome - 0.5))
    h = 0.3 * sand + 0.6 * fft_noise(N, 1.2, r, fmin=4) + 1.2 * clods_dome * clods_cov
    for cells, pres, rmin, rmax in [(150, 0.28, 0.22, 0.38), (64, 0.3, 0.22, 0.4), (26, 0.32, 0.18, 0.34)]:
        m, dh, c = pebble_layer(r, cells, pres, rmin, rmax)
        contact = np.clip(blur(m, max(1.0, N / cells * 0.1)) - m, 0, 1)
        col = mul(col, 1 - 0.6 * contact)
        col = lerp(col, c, m)
        h = np.where(m > 0.5, np.maximum(h, dh), h)
    return np.clip(col, 0, 1), h


# ----------------------------------------------------------------------------
# grass (stylised)
# ----------------------------------------------------------------------------
def grass(seed=404):
    r = R(seed)
    t = norm01(fft_noise(N, 1.3, r, fmin=3) + 0.5 * fft_noise(N, 1.0, r, fmin=10))
    col = palette(t, [(0.0, (60, 104, 38)), (0.4, (76, 128, 43)), (0.75, (94, 144, 50)), (1.0, (112, 158, 56))])
    dry = smoothstep(1.0, 2.4, fft_noise(N, 1.5, r, fmin=3))
    col = lerp(col, rgb((138, 152, 70)), 0.3 * dry)
    F1, _, ID, VX, VY = worley(N, 44, r)
    clump = 1 - smoothstep(0.0, 0.75, F1)
    col = mul(col, 0.9 + 0.16 * clump)
    angle_field = fft_noise(N, 1.6, r, fmin=1) * 1.2
    base_snapshot = col.copy()
    for layer, (count, alpha, lmin, lmax) in enumerate([(5200, 0.55, 7, 14), (4200, 0.62, 8, 16), (2600, 0.7, 9, 18)]):
        cv = WrapCanvas(N, ss=2, mode="RGB", bg=(0, 0, 0))
        mk = WrapCanvas(N, ss=2, mode="L", bg=0)
        xs = r.uniform(0, N, count)
        ys = r.uniform(0, N, count)
        for x, y in zip(xs, ys):
            ix, iy = int(x) % N, int(y) % N
            a = angle_field[iy, ix] + r.normal(0, 0.55)
            L = r.uniform(lmin, lmax)
            dx, dy = np.cos(a) * L, np.sin(a) * L
            bc = base_snapshot[iy, ix] * r.uniform(0.68, 0.92)
            tc = np.clip(base_snapshot[iy, ix] * r.uniform(1.12, 1.42) + np.array([0.035, 0.045, 0.0]), 0, 1)
            w = r.uniform(1.4, 2.3)
            mid = (x + dx * 0.5, y + dy * 0.5)
            cv.line([(x, y), mid], tuple(int(v * 255) for v in bc), w)
            cv.line([mid, (x + dx, y + dy)], tuple(int(v * 255) for v in tc), w * 0.75)
            mk.line([(x, y), mid], 255, w)
            mk.line([mid, (x + dx, y + dy)], 255, w * 0.75)
        strokes = cv.result()          # colour premultiplied by coverage (black background)
        cover = mk.result()
        col = col * (1 - alpha * cover[..., None]) + alpha * strokes
    col = blur(col, 0.25)
    return np.clip(col, 0, 1), None


# ----------------------------------------------------------------------------
# painted metal
# ----------------------------------------------------------------------------
def metal_painted(seed=505):
    r = R(seed)
    col = np.empty((N, N, 3))
    col[:] = rgb((204, 206, 208))
    col = mul(col, 1 + 0.022 * fft_noise(N, 1.4, r, fmin=1) + 0.01 * fft_noise(N, 0.6, r, fmin=40))
    streak = smoothstep(0.3, 2.2, fft_noise(N, 1.1, r, fmin=1, aniso=(1, 12)))
    col = mul(col, 1 - 0.06 * streak)
    grime = smoothstep(0.8, 2.4, fft_noise(N, 1.4, r, fmin=2))
    col = lerp(col, rgb((150, 146, 138)), 0.18 * grime)
    sc = WrapCanvas(N, ss=2, mode="L", bg=0)
    for _ in range(320):
        x, y = r.uniform(0, N, 2)
        a = r.normal(0, 0.3) if r.random() < 0.7 else r.uniform(0, np.pi)
        L = r.uniform(12, 95) * (0.5 if r.random() < 0.5 else 1)
        bend = r.normal(0, 0.15)
        pts = [(x + np.cos(a + bend * s) * L * s, y + np.sin(a + bend * s) * L * s) for s in np.linspace(0, 1, 5)]
        sc.line(pts, int(r.uniform(90, 255)), r.uniform(0.5, 1.3))
    scr = sc.result()
    shadow = np.roll(np.roll(scr, 1, 0), 1, 1)
    col = mul(col, 1 - 0.12 * np.clip(shadow - scr, 0, 1))
    col = lerp(col, rgb((232, 234, 236)), 0.65 * scr)
    wx = fft_noise(N, 1.0, r, fmin=8) * 6
    wy = fft_noise(N, 1.0, r, fmin=8) * 6
    F1, _, ID, _, _ = worley(N, 22, r, dx=wx, dy=wy)
    k = 22 * 22
    rad = r.uniform(0.04, 0.14, k)[ID]
    present = (r.random(k) < 0.12)[ID]
    chip = smoothstep(rad, rad * 0.75, F1) * present
    rim = np.clip(smoothstep(rad * 1.35, rad, F1) * present - chip, 0, 1)
    col = lerp(col, rgb((236, 238, 240)), 0.5 * rim)
    col = lerp(col, rgb((118, 122, 128)), chip)
    return np.clip(col, 0, 1), None


# ----------------------------------------------------------------------------
# corrugated sheet normal map
# ----------------------------------------------------------------------------
def corrugated_n(seed=606):
    r = R(seed)
    x = np.arange(N)
    ribs = 8
    period = N / ribs
    amp = period * 0.16
    prof = np.sin(2 * np.pi * x / period) * amp
    h = np.tile(prof, (N, 1))
    dents = fft_noise(N, 1.8, r, fmin=2) * 1.4
    h = h + dents
    return normal_map(h, 1.0)


# ----------------------------------------------------------------------------
# wood planks
# ----------------------------------------------------------------------------
def wood_planks(seed=707):
    r = R(seed)
    nP = 4
    ph = N // nP
    yy, xx = np.mgrid[0:N, 0:N].astype(float)
    pidx = (yy // ph).astype(int)
    ly = yy - pidx * ph
    wav = fft_noise(N, 1.5, r, fmin=1, fmax=7, aniso=(4, 1))        # smooth, long waves
    wav2 = fft_noise(N, 1.2, r, fmin=2, fmax=18, aniso=(6, 1))
    fibers = fft_noise(N, 0.6, r, fmin=24, aniso=(16, 1))
    pores = smoothstep(1.4, 2.6, fft_noise(N, 0.3, r, fmin=40, aniso=(18, 1)))
    col = np.zeros((N, N, 3))
    h = np.zeros((N, N))
    base_cols = [(186, 128, 74), (170, 114, 62), (194, 138, 82), (160, 106, 58)]
    for p in range(nP):
        sel = pidx == p
        f = r.uniform(1 / 30, 1 / 20)
        phase = ly * f + 1.4 * wav + 0.25 * wav2 + r.uniform(0, 10)
        knots = np.zeros((N, N))
        kcore = np.zeros((N, N))
        for _ in range(r.integers(1, 3)):
            kx, ky = r.uniform(0, N), p * ph + r.uniform(50, ph - 50)
            rx, ry = r.uniform(18, 34), r.uniform(9, 15)
            dxw = (xx - kx + N / 2) % N - N / 2
            e = (dxw / rx) ** 2 + ((yy - ky) / ry) ** 2
            knots += np.exp(-e * 0.3) * r.choice([-1, 1])
            kcore = np.maximum(kcore, smoothstep(1.0, 0.25, e))
        phase = phase + 1.6 * knots
        fr = phase % 1.0
        lines = np.exp(-((fr - 0.5) / 0.07) ** 2)                 # narrow late-wood lines
        band = 0.5 + 0.5 * np.cos(2 * np.pi * (fr - 0.5))          # darker band around each line
        grain = np.clip(0.7 * lines + 0.35 * band ** 3 + 0.35 * pores, 0, 1)
        c0 = rgb(base_cols[p])
        dark = c0 * np.array([0.6, 0.52, 0.45])
        pc = lerp(np.broadcast_to(c0, (N, N, 3)), np.broadcast_to(dark, (N, N, 3)), 0.75 * grain)
        streaks = fft_noise(N, 1.3, r, fmin=2, aniso=(10, 1))
        pc = mul(pc, 1 + 0.035 * fibers + 0.06 * wav + 0.06 * streaks)
        pc = lerp(pc, rgb((84, 50, 26)), 0.75 * kcore)
        col[sel] = pc[sel]
        h[sel] = (1.0 - 0.12 * grain - 0.25 * kcore + 0.03 * fibers)[sel]
        # butt joints, nails
        joints = r.uniform(0, N, r.integers(0, 2)) if p % 2 == 0 else [r.uniform(0, N)]
        for jx in joints:
            d = np.abs((xx - jx + N / 2) % N - N / 2)
            jm = (smoothstep(2.5, 1.0, d)) * sel
            bev = smoothstep(7.0, 2.0, d) * sel
            col = mul(col, 1 - 0.75 * jm - 0.18 * bev)
            h = h - 0.9 * jm - 0.25 * bev
            for side in (-1, 1):
                for ny_ in (0.18, 0.82):
                    cx, cy = jx + side * 16, p * ph + ny_ * ph
                    dd = np.hypot((xx - cx + N / 2) % N - N / 2, yy - cy)
                    nail = smoothstep(4.2, 3.0, dd)
                    ring = smoothstep(6.5, 4.2, dd) - nail
                    col = lerp(col, rgb((70, 66, 62)), nail)
                    col = mul(col, 1 - 0.25 * ring)
                    h = h - 0.4 * nail
    edge = np.minimum(ly, ph - 1 - ly)
    gap = smoothstep(3.0, 1.2, edge)
    bevel = smoothstep(9.0, 2.0, edge)
    col = mul(col, 1 - 0.8 * gap - 0.2 * bevel)
    h = h * (1 - bevel * 0.6) - gap * 1.2
    return np.clip(col, 0, 1), h * 4.0


# ----------------------------------------------------------------------------
# sandbag (woven fabric)
# ----------------------------------------------------------------------------
def sandbag(seed=808):
    r = R(seed)
    p = 16
    yy, xx = np.mgrid[0:N, 0:N].astype(float)
    nthreads = N // p
    wobble_x = fft_noise(N, 1.4, r, fmin=2) * 1.5
    wobble_y = fft_noise(N, 1.4, r, fmin=2) * 1.5
    X = xx + wobble_x
    Y = yy + wobble_y
    i = np.floor(X / p).astype(int) % nthreads
    j = np.floor(Y / p).astype(int) % nthreads
    fx = (X / p) % 1.0 - 0.5
    fy = (Y / p) % 1.0 - 0.5
    wi = (0.78 + 0.14 * r.random(nthreads))[i]
    wj = (0.78 + 0.14 * r.random(nthreads))[j]
    tw = np.sqrt(np.clip(1 - (fx / (wi / 2)) ** 2, 0, 1))
    tf = np.sqrt(np.clip(1 - (fy / (wj / 2)) ** 2, 0, 1))
    hw = tw * (0.62 + 0.38 * np.cos(np.pi * (Y / p - 0.5) + np.pi * i))
    hf = tf * (0.62 + 0.38 * np.cos(np.pi * (X / p - 0.5) + np.pi * (j + 1)))
    H = np.maximum(hw, hf)
    is_warp = hw >= hf
    fib_w = fft_noise(N, 0.7, r, fmin=16, aniso=(1, 10))
    fib_f = fft_noise(N, 0.7, r, fmin=16, aniso=(10, 1))
    fib = np.where(is_warp, fib_w, fib_f)
    tb = np.where(is_warp, (0.93 + 0.14 * r.random(nthreads))[i], (0.93 + 0.14 * r.random(nthreads))[j])
    base = rgb((182, 156, 108))
    col = np.broadcast_to(base, (N, N, 3)).copy()
    col = mul(col, tb * (1 + 0.07 * fib) * (0.55 + 0.45 * H))
    gapc = rgb((68, 56, 38))
    col = lerp(col, np.broadcast_to(gapc, (N, N, 3)), smoothstep(0.25, 0.0, H))
    dirt = smoothstep(0.5, 2.2, fft_noise(N, 1.3, r, fmin=2))
    col = mul(col, 1 - 0.09 * dirt)
    dust = smoothstep(0.8, 2.2, fft_noise(N, 1.2, r, fmin=3))
    col = lerp(col, rgb((205, 188, 150)), 0.15 * dust)
    hair = WrapCanvas(N, ss=2, mode="L", bg=0)
    for _ in range(140):
        x, y = r.uniform(0, N, 2)
        a = r.uniform(0, np.pi)
        L = r.uniform(10, 35)
        pts = [(x + np.cos(a + 0.4 * np.sin(s * 3)) * L * s, y + np.sin(a + 0.4 * np.sin(s * 3)) * L * s)
               for s in np.linspace(0, 1, 6)]
        hair.line(pts, int(r.uniform(80, 200)), 0.6)
    hm = hair.result()
    col = lerp(col, rgb((206, 182, 132)), 0.5 * hm)
    return np.clip(col, 0, 1), H * 3


# ----------------------------------------------------------------------------
# brick
# ----------------------------------------------------------------------------
def brick(seed=909):
    r = R(seed)
    rows, per_row, mortar = 16, 5, 7.0
    bh = N / rows
    bw = N / per_row
    yy, xx = np.mgrid[0:N, 0:N].astype(float)
    nx = fft_noise(N, 1.2, r, fmin=6) * 1.6
    ny = fft_noise(N, 1.2, r, fmin=6) * 1.6
    Y = yy + ny
    X = xx + nx
    row = np.floor(Y / bh).astype(int)
    fy = Y / bh - row
    off = (row % 2) * 0.5
    bx = X / bw + off
    bi = np.floor(bx).astype(int)
    fxl = bx - bi
    row %= rows
    bi %= per_row
    bid = row * per_row + bi
    dx = np.minimum(fxl, 1 - fxl) * bw
    dy = np.minimum(fy, 1 - fy) * bh
    d = np.minimum(dx, dy) - mortar / 2
    chip = fft_noise(N, 0.9, r, fmin=20) * 1.1
    d = d + chip
    inside = smoothstep(0.0, 1.2, d)
    pal = np.array([(152, 64, 44), (166, 76, 50), (134, 56, 40), (174, 92, 62), (120, 52, 40), (158, 82, 56),
                    (142, 70, 50)], float) / 255.0
    nb = rows * per_row
    bc = pal[r.integers(0, len(pal), nb)] * r.uniform(0.9, 1.1, nb)[:, None]
    bcol = bc[bid]
    surf = fft_noise(N, 0.9, r, fmin=12)
    speck = smoothstep(1.8, 2.6, fft_noise(N, 0.0, r, fmin=200))
    bcol = mul(bcol, 1 + 0.07 * surf - 0.25 * speck)
    burnt = smoothstep(0.4, 1.6, fft_noise(N, 1.2, r, fmin=3)) * (r.random(nb) < 0.3)[bid]
    bcol = mul(bcol, 1 - 0.3 * burnt)
    eff = smoothstep(1.0, 2.2, fft_noise(N, 1.3, r, fmin=3))
    bcol = lerp(bcol, rgb((196, 180, 162)), 0.25 * eff)
    edge_dark = smoothstep(6.0, 0.5, d)
    bcol = mul(bcol, 1 - 0.18 * edge_dark)
    mcol = np.broadcast_to(rgb((176, 170, 160)), (N, N, 3)) * (1 + 0.08 * fft_noise(N, 0.6, r, fmin=30))[..., None]
    mcol = mul(mcol, 1 - 0.12 * smoothstep(0.5, 2.0, fft_noise(N, 1.3, r, fmin=2)))
    col = lerp(mcol, bcol, inside)
    h = np.where(d > 0, 3.0 * smoothstep(0.0, 3.0, d) + 0.35 * surf - 0.8 * speck, -0.5 + 0.2 * fft_noise(N, 0.6, r, fmin=30))
    h = blur(h, 0.7)
    return np.clip(col, 0, 1), h


# ----------------------------------------------------------------------------
# rust / grime overlay (mostly light, for multiply)
# ----------------------------------------------------------------------------
def rust_grunge(seed=1010):
    r = R(seed)
    col = np.empty((N, N, 3))
    col[:] = rgb((250, 248, 244))
    wx = fft_noise(N, 1.3, r, fmin=2) * 40
    wy = fft_noise(N, 1.3, r, fmin=2) * 40
    base = warp(fft_noise(N, 1.25, r, fmin=2), wx, wy)
    detail = fft_noise(N, 1.0, r, fmin=10) * 0.7 + fft_noise(N, 0.6, r, fmin=60) * 0.3
    m = smoothstep(0.95, 1.4, base + 0.35 * detail)
    deep = smoothstep(1.45, 2.1, base + 0.35 * detail)
    col = lerp(col, rgb((206, 134, 82)), 0.85 * m)
    col = lerp(col, rgb((142, 76, 40)), 0.8 * deep)
    speck = smoothstep(1.6, 2.4, fft_noise(N, 0.2, r, fmin=120)) * smoothstep(0.5, 1.1, base)
    col = lerp(col, rgb((150, 86, 46)), 0.7 * speck)
    streak = fft_noise(N, 1.0, r, fmin=2, aniso=(1, 14))
    drip_src = blur(m, 2) * 0
    drips = smoothstep(0.8, 2.2, streak) * smoothstep(-0.2, 0.9, base)
    col = lerp(col, rgb((196, 150, 112)), 0.35 * drips)
    grime = smoothstep(0.3, 2.0, fft_noise(N, 1.5, r, fmin=1))
    col = lerp(col, rgb((128, 116, 100)), 0.32 * grime)
    dots = smoothstep(2.3, 3.0, fft_noise(N, 0.0, r, fmin=60))
    col = lerp(col, rgb((110, 98, 86)), 0.5 * dots)
    col = mul(col, 1 + 0.025 * fft_noise(N, 0.5, r, fmin=40))
    return np.clip(col, 0, 1), None


# ----------------------------------------------------------------------------
# floor / roof tiles
# ----------------------------------------------------------------------------
def tiles(seed=1111):
    r = R(seed)
    n_t = 8
    ts = N / n_t
    grout = 5.0
    yy, xx = np.mgrid[0:N, 0:N].astype(float)
    ti = (xx // ts).astype(int) % n_t
    tj = (yy // ts).astype(int) % n_t
    tid = tj * n_t + ti
    fx = xx / ts - np.floor(xx / ts)
    fy = yy / ts - np.floor(yy / ts)
    d = np.minimum(np.minimum(fx, 1 - fx), np.minimum(fy, 1 - fy)) * ts - grout / 2
    d = d + fft_noise(N, 1.0, r, fmin=16) * 0.3
    inside = smoothstep(0.0, 1.0, d)
    nt = n_t * n_t
    tint = r.uniform(0.88, 1.07, nt)
    hue = r.uniform(-0.03, 0.03, nt)
    base = rgb((204, 192, 172))
    tc = np.broadcast_to(base, (N, N, 3)) * tint[tid][..., None]
    tc[..., 0] += hue[tid]
    tc[..., 2] -= hue[tid]
    stone = fft_noise(N, 1.1, r, fmin=8)
    fine = fft_noise(N, 0.3, r, fmin=80)
    tc = mul(tc, 1 + 0.03 * stone + 0.025 * fine)
    worn = smoothstep(6.0, 0.0, d)
    tc = mul(tc, 1 - 0.12 * worn)
    bevel_hi = smoothstep(0.0, 1.5, d) * smoothstep(5.0, 2.0, d)
    tc = tc + 0.04 * bevel_hi[..., None]
    wx = fft_noise(N, 1.3, r, fmin=2) * 14
    wy = fft_noise(N, 1.3, r, fmin=2) * 14
    C1, C2, CID, _, _ = worley(N, 6, r, dx=wx, dy=wy)
    cracked = (r.random(nt) < 0.12)[tid]
    cracks = smoothstep(0.006, 0.0015, C2 - C1) * cracked * inside
    tc = mul(tc, 1 - 0.45 * cracks)
    gc = np.broadcast_to(rgb((104, 98, 90)), (N, N, 3)) * (1 + 0.1 * fine)[..., None]
    col = lerp(gc, tc, inside)
    dirt = smoothstep(0.8, 2.2, fft_noise(N, 1.4, r, fmin=2))
    col = mul(col, 1 - 0.07 * dirt)
    h = np.where(d > 0, 2.0 * smoothstep(0, 2.5, d) + 0.2 * stone, -0.5) - 1.0 * cracks
    return np.clip(col, 0, 1), h


# ----------------------------------------------------------------------------
# FX sprites (RGBA)
# ----------------------------------------------------------------------------
def hex_pattern(n=512, seed=1212):
    """White hexagon outlines on black.  Pointy-top hexes, 7 x 4 lattice periods
    (horizontal scale adjusted by ~1% so the lattice repeats exactly in 512 px)."""
    ss = 4
    m = n * ss
    nx, ny = 7, 4
    r_hex = m / (3 * ny)                   # circumradius in supersampled px
    w = np.sqrt(3) * r_hex
    sx = (nx * w) / m                      # horizontal stretch to fit nx hexes
    yy, xx = np.mgrid[0:m, 0:m].astype(float) + 0.5
    X = xx * sx
    Y = yy
    best = np.full((m, m), 1e9)
    lx = np.zeros((m, m))
    ly = np.zeros((m, m))
    for ox, oy in ((0.0, 0.0), (w / 2, 1.5 * r_hex)):
        cx = np.round((X - ox) / w) * w + ox
        cy = np.round((Y - oy) / (3 * r_hex)) * (3 * r_hex) + oy
        d = np.hypot(X - cx, Y - cy)
        c = d < best
        best = np.where(c, d, best)
        lx = np.where(c, X - cx, lx)
        ly = np.where(c, Y - cy, ly)
    ri = np.sqrt(3) / 2 * r_hex
    hd = np.maximum(np.abs(lx), np.maximum(np.abs(0.5 * lx + 0.8660254 * ly), np.abs(0.5 * lx - 0.8660254 * ly)))
    edge = ri - hd                          # distance to nearest hex edge (supersampled px)
    half = 1.6 * ss
    core = smoothstep(half + 0.75 * ss, half - 0.75 * ss, edge)
    glow = np.exp(-np.maximum(edge - half, 0) / (5.0 * ss)) * 0.22
    v = np.clip(np.maximum(core, glow), 0, 1)
    im = Image.fromarray((v * 255).astype(np.uint8)).resize((n, n), Image.LANCZOS)
    a = np.asarray(im).astype(float) / 255
    return np.stack([a, a, a], -1)


def glow_sprite(n=256):
    yy, xx = np.mgrid[0:n, 0:n].astype(float) + 0.5
    d = np.hypot(xx - n / 2, yy - n / 2) / (n / 2)
    a = np.clip(1 - d, 0, 1) ** 2.2 * 0.55 + np.exp(-(d / 0.22) ** 2) * 0.45
    a *= smoothstep(1.0, 0.92, d)
    a = np.clip(a / a.max(), 0, 1)
    rgbv = np.ones((n, n, 3))
    return np.concatenate([rgbv, a[..., None]], -1)


def spark_sprite(n=256):
    """Vertical streak (long axis = +Y) for velocity-aligned particles."""
    yy, xx = np.mgrid[0:n, 0:n].astype(float) + 0.5
    u = (xx - n / 2) / (n / 2)
    v = (yy - n / 2) / (n / 2)
    length = 0.86
    t = np.clip(np.abs(v) / length, 0, 1)
    taper = (1 - t ** 2) ** 1.5
    width = 0.045 * (1 - t) ** 0.7 + 0.004
    core = np.exp(-(u / width) ** 2) * taper
    halo = np.exp(-(u / (width * 3.5)) ** 2) * taper ** 2 * 0.35
    a = np.clip(core + halo, 0, 1)
    a *= smoothstep(1.0, 0.96, np.maximum(np.abs(u), np.abs(v)))
    rgbv = np.ones((n, n, 3))
    return np.concatenate([rgbv, (a / a.max())[..., None]], -1)


def muzzle_flash(n=512, seed=1313):
    """2x2 atlas of star-shaped flashes (straight alpha)."""
    r = R(seed)
    cell = n // 2
    ss = 2
    m = cell * ss
    out = np.zeros((n, n, 4))
    yy, xx = np.mgrid[0:m, 0:m].astype(float) + 0.5
    X = (xx - m / 2) / (m / 2)
    Y = (yy - m / 2) / (m / 2)
    rad = np.hypot(X, Y) * 0.92
    ang = np.arctan2(Y, X)
    for k in range(4):
        spikes = [5, 4, 7, 9][k]
        rot = r.uniform(0, 2 * np.pi)
        lens = r.uniform(0.62, 0.98, spikes) if k != 1 else r.uniform(0.85, 0.98, spikes)
        widths = r.uniform(0.13, 0.24, spikes) if k != 3 else r.uniform(0.08, 0.14, spikes)
        star = np.zeros((m, m))
        for s in range(spikes):
            a0 = rot + s * 2 * np.pi / spikes + r.normal(0, 0.12)
            da = np.angle(np.exp(1j * (ang - a0)))
            prof = np.exp(-(da / (widths[s] * (1 - 0.65 * np.clip(rad / lens[s], 0, 1)))) ** 2)
            ext = np.clip(1 - rad / lens[s], 0, 1) ** 1.0
            star = np.maximum(star, prof * ext)
        sub = r.uniform(0.25, 0.45)
        for s in range(spikes * 2):
            a0 = rot + (s + 0.5) * np.pi / spikes
            da = np.angle(np.exp(1j * (ang - a0)))
            star = np.maximum(star, np.exp(-(da / 0.1) ** 2) * np.clip(1 - rad / sub, 0, 1) ** 1.5 * 0.8)
        core = np.exp(-(rad / 0.23) ** 2)
        noise = 1 + 0.25 * fft_noise(m, 0.8, r, fmin=4)
        inten = np.clip(np.maximum(star * noise, core) + 0.32 * np.exp(-(rad / 0.45) ** 2), 0, 1)
        inten *= smoothstep(0.92, 0.82, rad)
        # colour: white-yellow core -> orange -> deep orange edges
        c = palette(inten, [(0.0, (230, 70, 10)), (0.35, (255, 130, 25)), (0.65, (255, 196, 70)),
                            (0.88, (255, 240, 170)), (1.0, (255, 255, 240))])
        a = np.clip(inten ** 0.75 * 1.25, 0, 1)
        img = np.concatenate([c, a[..., None]], -1)
        im = Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8), "RGBA").resize((cell, cell), Image.LANCZOS)
        oy, ox = (k // 2) * cell, (k % 2) * cell
        out[oy:oy + cell, ox:ox + cell] = np.asarray(im).astype(float) / 255
    return out


# ----------------------------------------------------------------------------
# driver
# ----------------------------------------------------------------------------
ALBEDO = [  # name, fn, normal map name, normal strength
    ("concrete", concrete, "concrete_n", 1.4),
    ("asphalt", asphalt, "asphalt_n", 0.9),
    ("dirt", dirt, None, 0),
    ("grass", grass, None, 0),
    ("metal_painted", metal_painted, None, 0),
    ("wood_planks", wood_planks, "wood_planks_n", 0.9),
    ("sandbag", sandbag, None, 0),
    ("brick", brick, "brick_n", 1.1),
    ("rust_grunge", rust_grunge, None, 0),
    ("tiles", tiles, None, 0),
]


def save_rgba(img, path):
    Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA").save(path, optimize=True)


def build(out, only=None):
    os.makedirs(out, exist_ok=True)
    report = []
    for name, fn, nname, strength in ALBEDO:
        if only and name not in only and (nname or "") not in only:
            continue
        col, h = fn()
        save(col, os.path.join(out, f"{name}.png"))
        report.append((name, seam_score(col)))
        if nname:
            nm = normal_map(h, strength)
            save(nm, os.path.join(out, f"{nname}.png"))
            report.append((nname, seam_score(nm)))
        print("  ", name)
    if not only or "corrugated_n" in only:
        nm = corrugated_n()
        save(nm, os.path.join(out, "corrugated_n.png"))
        report.append(("corrugated_n", seam_score(nm)))
    if not only or "hex_pattern" in only:
        hx = hex_pattern()
        save(hx, os.path.join(out, "hex_pattern.png"))
        report.append(("hex_pattern", seam_score(hx)))
    if not only or "fx" in only:
        save_rgba(glow_sprite(), os.path.join(out, "glow.png"))
        save_rgba(spark_sprite(), os.path.join(out, "spark.png"))
        save_rgba(muzzle_flash(), os.path.join(out, "muzzle_flash.png"))
    for nm_, (sx, sy) in report:
        flag = "" if max(sx, sy) < 1.6 else "  <-- SEAM?"
        print(f"   seam {nm_:16s} x {sx:5.2f}  y {sy:5.2f}{flag}")
    return report


PREVIEW_ORDER = ["concrete", "concrete_n", "asphalt", "asphalt_n", "dirt", "grass", "metal_painted",
                 "corrugated_n", "wood_planks", "wood_planks_n", "sandbag", "brick", "brick_n",
                 "rust_grunge", "tiles", "hex_pattern", "glow", "spark", "muzzle_flash"]
TILED = set(PREVIEW_ORDER[:16])


def preview(out, cell=384, cols=5):
    font = ImageFont.truetype(FONT, 22)
    names = [n for n in PREVIEW_ORDER if os.path.exists(os.path.join(out, n + ".png"))]
    rows = (len(names) + cols - 1) // cols
    lab = 30
    sheet = Image.new("RGB", (cols * (cell + 8) + 8, rows * (cell + lab + 8) + 8), (28, 30, 34))
    d = ImageDraw.Draw(sheet)
    for k, nme in enumerate(names):
        im = Image.open(os.path.join(out, nme + ".png"))
        if nme in TILED:
            im = im.convert("RGB")
            w, h = im.size
            big = Image.new("RGB", (w * 2, h * 2))
            for oy in (0, h):
                for ox in (0, w):
                    big.paste(im, (ox, oy))
            tile = big.resize((cell, cell), Image.LANCZOS)
            sub = "2x2 tiled"
        else:
            im = im.convert("RGBA")
            bg = Image.new("RGBA", im.size, (0, 0, 0, 255))
            chk = 32
            arr = np.zeros((im.size[1], im.size[0], 4), np.uint8)
            yy, xx = np.mgrid[0:im.size[1], 0:im.size[0]]
            c = (((yy // chk) + (xx // chk)) % 2) * 22 + 18
            arr[..., 0] = c
            arr[..., 1] = c
            arr[..., 2] = c + 4
            arr[..., 3] = 255
            bg = Image.fromarray(arr, "RGBA")
            tile = Image.alpha_composite(bg, im).convert("RGB").resize((cell, cell), Image.LANCZOS)
            sub = "alpha over checker"
        x0 = 8 + (k % cols) * (cell + 8)
        y0 = 8 + (k // cols) * (cell + lab + 8)
        sheet.paste(tile, (x0, y0))
        d.text((x0 + 2, y0 + cell + 2), f"{nme}.png  ({sub})", font=font, fill=(235, 235, 235))
    sheet.save(os.path.join(out, "_preview.png"), optimize=True)
    print("preview:", os.path.join(out, "_preview.png"))


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else OUT
    only = set(sys.argv[2:]) or None
    build(out, only)
    preview(out)
