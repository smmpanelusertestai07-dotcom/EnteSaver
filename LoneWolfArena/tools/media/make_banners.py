#!/usr/bin/env python3
"""Profile banners for LONE WOLF ARENA: six original abstract cards in the game's palette (dark
charcoal / navy grounds, gold and amber light, steel, a little ember red), drawn procedurally with
numpy + Pillow at 2x and box-downsampled. Deterministic (fixed seeds).

  banner_1  EMBER RIDGE   low-poly mountain ridges backlit by a low sun, haze and embers
  banner_2  GOLD RUSH     slanted gold light streaks and sparks over a dark ground
  banner_3  HIVE          a hex grid whose cells light up amber toward the right
  banner_4  CONTOUR       a topographic map: amber contour lines, a map grid, a drop marker
  banner_5  SHARDS        a low-poly steel surface split by a molten amber seam
  banner_6  SCOPE         range rings, ticks and a radar sweep with contacts (navy and gold)

The profile page draws the avatar and the name over the left third, so every banner keeps that
side darker and calmer and puts its motif on the right. 600x200 px each, written to
assets/ui/banners/banner_<n>.png with their Godot .import (2D art: lossless, mipmaps for the
smaller banner picker, never turned into VRAM-compressed 3D textures), then run
`godot --headless --path . --import`.
usage: python3 tools/media/make_banners.py [out_dir] [--preview sheet.png]"""
from __future__ import annotations

import math
import os
import re
import sys

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "assets", "ui", "banners")
W, H = 600, 200
SS = 2                                    # supersampling factor
GOLD = np.array([255, 194, 14], np.float32)       # the UI accent (#FFC20E)
AMBER = np.array([240, 150, 44], np.float32)
EMBER = np.array([255, 110, 30], np.float32)
NAMES = ["EMBER RIDGE", "GOLD RUSH", "HIVE", "CONTOUR", "SHARDS", "SCOPE"]


# ---------------------------------------------------------------- helpers (1x pixel units)
def grid():
    yy, xx = np.mgrid[0:H * SS, 0:W * SS].astype(np.float32) + 0.5
    return xx / SS, yy / SS


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def blur(a, sigma):
    """Gaussian blur, sigma in 1x pixels; colour images are blurred per channel."""
    s = sigma * SS
    return ndimage.gaussian_filter(a, (s, s, 0) if a.ndim == 3 else s)


def vgrad(stops, t):
    """Piecewise-linear colour ramp: stops = [(pos, (r, g, b)), ...], t any shape -> t.shape + (3,)."""
    pos = np.array([p for p, _ in stops], np.float32)
    cols = np.array([c for _, c in stops], np.float32)
    t = np.clip(t, pos[0], pos[-1])
    out = np.empty(t.shape + (3,), np.float32)
    for ch in range(3):
        out[..., ch] = np.interp(t, pos, cols[:, ch])
    return out


def noise(rng, cells_x, cells_y):
    """Smooth value noise over the canvas, roughly in [-1, 1]."""
    g = rng.standard_normal((cells_y + 3, cells_x + 3)).astype(np.float32)
    z = ndimage.zoom(g, ((H * SS + 2) / (cells_y + 3), (W * SS + 2) / (cells_x + 3)), order=3)
    z = z[1:H * SS + 1, 1:W * SS + 1]
    return z / (np.abs(z).max() + 1e-6)


def sample(field, x, y):
    """Value of a canvas-sized field at 1x coordinates (clamped)."""
    i = int(np.clip(y * SS, 0, H * SS - 1))
    j = int(np.clip(x * SS, 0, W * SS - 1))
    return float(field[i, j])


def layer():
    return Image.new("L", (W * SS, H * SS), 0)


def to_f(im):
    return np.asarray(im).astype(np.float32) / 255.0


def sc(pts):
    return [(x * SS, y * SS) for x, y in pts]


def add(col, mask, color, k=1.0):
    col += (mask * k)[..., None] * np.asarray(color, np.float32)
    return col


def mix(col, mask, color):
    m = np.clip(mask, 0, 1)[..., None]
    return col * (1 - m) + np.asarray(color, np.float32) * m


def finish(col, seed):
    """Readability and framing (the left third and the bottom edge a little darker, a soft
    vignette), 2x box downsample, a 1-LSB triangular dither against banding."""
    xs, ys = grid()
    u, v = xs / W, ys / H
    k = 0.6 + 0.4 * smoothstep(0.02, 0.5, u)
    k *= 1.0 - 0.22 * smoothstep(0.6, 1.0, v)
    r = np.hypot(u - 0.55, (v - 0.5) * 1.4)
    k *= 1.0 - 0.3 * smoothstep(0.5, 1.05, r)
    col = col * k[..., None]
    col = col.reshape(H, SS, W, SS, 3).mean(axis=(1, 3))
    rng = np.random.default_rng(seed)
    col += rng.random((H, W, 1)) - rng.random((H, W, 1))
    return Image.fromarray(np.clip(col + 0.5, 0, 255).astype(np.uint8), "RGB")


# ---------------------------------------------------------------- 1 EMBER RIDGE
def ember_ridge(rng):
    xs, ys = grid()
    sun = (0.8 * W, 0.6 * H)
    col = vgrad([(0.0, (12, 12, 28)), (0.38, (40, 20, 50)), (0.62, (160, 66, 34)), (1.0, (60, 24, 30))], ys / H)
    d = np.hypot((xs - sun[0]) / W * 3.0, (ys - sun[1]) / H)
    add(col, np.exp(-(d / 0.42) ** 2), (255, 128, 48), 0.5)
    add(col, np.exp(-(d / 0.06) ** 2), (255, 224, 170), 1.0)
    add(col, np.exp(-((ys - sun[1]) / 1.6) ** 2) * np.exp(-((xs - sun[0]) / 150) ** 2), (255, 200, 140), 0.6)
    # far -> near ridge layers: (base y, amplitude, vertices, colour, light mix, rim strength)
    layers = [(0.52, 26, 15, (92, 48, 74), 0.32, 0.5), (0.62, 30, 13, (60, 32, 58), 0.24, 0.65),
              (0.74, 34, 11, (34, 20, 40), 0.16, 0.85), (0.88, 30, 9, (16, 12, 22), 0.08, 1.0)]
    rim = np.zeros((H * SS, W * SS), np.float32)
    for li, (base, amp, nv, c, light, rim_k) in enumerate(layers):
        x_pts = np.linspace(-30, W + 30, nv + 1) + rng.uniform(-14, 14, nv + 1)
        y_pts = base * H + amp * (rng.uniform(-1, 1, nv + 1) + 0.6 * np.sin(np.arange(nv + 1) * 1.7 + li))
        if li == 0:                       # a taller far peak just left of the sun
            k = int(np.argmin(np.abs(x_pts - 0.68 * W)))
            y_pts[k] -= 34
        top = list(zip(x_pts, y_pts))
        low = [(x + rng.uniform(-10, 10), y + rng.uniform(26, 44)) for x, y in top]
        img = Image.new("RGB", (W * SS, H * SS), (0, 0, 0))
        msk = layer()
        dr, dm = ImageDraw.Draw(img), ImageDraw.Draw(msk)
        base_c = np.array(c, np.float32)
        warm = np.array([255, 150, 80], np.float32)

        def facet(pts, lit):
            shade = base_c * (0.75 + 0.5 * lit) + (warm - base_c) * light * lit
            shade = shade * (1 + rng.uniform(-0.05, 0.05))
            dr.polygon(sc(pts), fill=tuple(int(v) for v in np.clip(shade, 0, 255)))
            dm.polygon(sc(pts), fill=255)

        for i in range(nv):
            (x0, y0), (x1, y1) = top[i], top[i + 1]
            slope = (y1 - y0) / (abs(x1 - x0) + 1e-6) * (1 if (x0 + x1) / 2 < sun[0] else -1)
            facing = float(np.clip(slope * 1.4 + 0.5, 0, 1))         # the slope turned to the sun
            near_sun = math.exp(-(((x0 + x1) / 2 - sun[0]) / (0.45 * W)) ** 2)
            facet([top[i], top[i + 1], low[i]], facing * (0.4 + 0.6 * near_sun))
            facet([top[i + 1], low[i + 1], low[i]], 0.35 * facing * near_sun)
        dr.polygon(sc(low + [(W + 40, H + 10), (-40, H + 10)]), fill=tuple(int(v * 0.8) for v in base_c))
        dm.polygon(sc(low + [(W + 40, H + 10), (-40, H + 10)]), fill=255)
        m = to_f(msk)
        col = col * (1 - m[..., None]) + np.asarray(img).astype(np.float32) * m[..., None]
        line = layer()
        ImageDraw.Draw(line).line(sc(top), fill=255, width=max(1, int(1.4 * SS)))
        near = np.exp(-((xs - sun[0]) / (0.5 * W)) ** 2)
        rim = np.maximum(rim * (1 - m), to_f(line) * near * rim_k)
    add(col, rim, (255, 170, 90), 0.9)
    add(col, blur(rim, 3.0), (255, 120, 50), 0.6)
    emb = layer()
    de = ImageDraw.Draw(emb)
    for _ in range(46):
        x = W * (0.35 + 0.65 * rng.random() ** 0.7)
        y = H * rng.uniform(0.08, 0.8)
        r = rng.uniform(0.5, 1.5)
        de.ellipse(sc([(x - r, y - r), (x + r, y + r)]), fill=int(255 * rng.uniform(0.4, 1.0)))
    e = to_f(emb)
    add(col, e, (255, 180, 90), 1.0)
    add(col, blur(e, 2.5), (255, 110, 30), 1.6)
    return col


# ---------------------------------------------------------------- 2 GOLD RUSH
def gold_rush(rng):
    xs, ys = grid()
    u, v = xs / W, ys / H
    col = vgrad([(0.0, (14, 13, 13)), (0.55, (26, 21, 17)), (1.0, (40, 28, 18))], u)
    add(col, np.exp(-(np.hypot((u - 0.74) * 2.4, v - 0.45) / 0.45) ** 2), (255, 140, 40), 0.22)
    ang = math.radians(-24)
    ux, uy = math.cos(ang), math.sin(ang)
    light = np.zeros_like(col)
    for i in range(52):
        wide = i < 7
        cx = W * (0.18 + 0.9 * rng.beta(2.4, 1.2))
        cy = H * rng.uniform(-0.15, 1.15)
        length = rng.uniform(140, 420) if wide else rng.uniform(50, 300)
        width = rng.uniform(5, 13) if wide else rng.uniform(0.45, 2.2) ** 1.4
        dx, dy = xs - cx, ys - cy
        s = dx * ux + dy * uy
        dd = -dx * uy + dy * ux
        along = smoothstep(-length / 2, length * 0.25, s) * (1 - smoothstep(length * 0.38, length / 2, s))
        prof = np.exp(-(dd / width) ** 2) * along
        c = [GOLD, AMBER, np.array([255, 236, 190], np.float32), EMBER][int(rng.integers(4)) if not wide else 1]
        light += prof[..., None] * c * ((0.14 if wide else rng.uniform(0.35, 1.0)) * smoothstep(0.1, 0.5, cx / W))
    col += light + blur(light, 4.0) * 0.8
    for _ in range(3):                    # flares with a short horizontal streak
        fx, fy = W * rng.uniform(0.62, 0.95), H * rng.uniform(0.2, 0.8)
        d = np.hypot(xs - fx, ys - fy)
        add(col, np.exp(-(d / 3.0) ** 2), (255, 244, 210), 1.0)
        add(col, np.exp(-(d / 18.0) ** 2), (255, 170, 60), 0.35)
        add(col, np.exp(-((ys - fy) / 0.9) ** 2) * np.exp(-((xs - fx) / 70) ** 2), (255, 200, 120), 0.7)
    sp = layer()
    ds = ImageDraw.Draw(sp)
    for _ in range(70):
        x, y, r = W * (0.3 + 0.7 * rng.random() ** 0.6), H * rng.random(), rng.uniform(0.4, 1.1)
        ds.ellipse(sc([(x - r, y - r), (x + r, y + r)]), fill=int(255 * rng.uniform(0.3, 1.0)))
    s = to_f(sp)
    add(col, s, (255, 214, 140), 1.0)
    add(col, blur(s, 2.0), (255, 140, 40), 1.2)
    return col


# ---------------------------------------------------------------- 3 HIVE
def hive(rng):
    xs, ys = grid()
    u, v = xs / W, ys / H
    col = vgrad([(0.0, (14, 14, 19)), (1.0, (26, 22, 22))], u * 0.7 + v * 0.3)
    add(col, np.exp(-(np.hypot((u - 0.8) * 2.0, v - 0.5) / 0.5) ** 2), (255, 130, 30), 0.12)
    field = 0.62 * smoothstep(0.25, 1.0, u) + 0.38 * (noise(rng, 7, 3) * 0.5 + 0.5)
    R = 19.0                                   # pointy-top hexagons, circumradius in px
    fill_img = Image.new("RGB", (W * SS, H * SS), (0, 0, 0))
    edge, hot_edge = layer(), layer()
    df, de, dh = ImageDraw.Draw(fill_img), ImageDraw.Draw(edge), ImageDraw.Draw(hot_edge)
    cells = [(colm * math.sqrt(3) * R + (math.sqrt(3) * R / 2 if row % 2 else 0), row * 1.5 * R)
             for row in range(-1, int(H / (1.5 * R)) + 2) for colm in range(-1, int(W / (math.sqrt(3) * R)) + 2)]
    right = [i for i, (cx, cy) in enumerate(cells) if 0.5 * W < cx < W - 10 and 10 < cy < H - 10]
    hot = set(int(i) for i in rng.choice(right, 6, replace=False))
    for idx, (cx, cy) in enumerate(cells):
        pts = [(cx + (R - 1.6) * math.cos(math.radians(60 * k - 30)), cy + (R - 1.6) * math.sin(math.radians(60 * k - 30)))
               for k in range(6)]
        de.polygon(sc(pts), outline=60)
        lit = float(smoothstep(0.52, 0.95, sample(field, cx, cy) + rng.uniform(-0.08, 0.08)))
        if idx in hot:
            lit = 1.0
            dh.polygon(sc(pts), outline=255, width=SS)
        if lit > 0.02:
            c = AMBER * (1 - lit) + GOLD * lit
            df.polygon(sc(pts), fill=tuple(int(x) for x in c * (0.08 + 0.42 * lit ** 1.5)))
            if lit > 0.35:
                dh.polygon(sc(pts), outline=int(255 * lit), width=1)
    fl = np.asarray(fill_img).astype(np.float32)
    col += fl + blur(fl, 6.0) * 0.9
    add(col, to_f(edge), (190, 176, 150), 0.5)
    he = to_f(hot_edge)
    add(col, he, (255, 210, 110), 0.9)
    add(col, blur(he, 3.0), (255, 150, 30), 1.4)
    sweep = np.exp(-((u * 0.8 + v * 0.35 - 0.78) / 0.035) ** 2)
    add(col, sweep * (0.25 + to_f(edge) * 2.0), (255, 220, 160), 0.18)
    return col


# ---------------------------------------------------------------- 4 CONTOUR
def contour(rng):
    xs, ys = grid()
    u, v = xs / W, ys / H
    col = vgrad([(0.0, (9, 22, 30)), (1.0, (5, 11, 19))], v * 0.6 + (1 - u) * 0.4)
    peak = (0.74 * W, 0.44 * H)
    h = 1.0 * np.exp(-(((xs - peak[0]) / 95) ** 2 + ((ys - peak[1]) / 70) ** 2))
    h += 0.55 * np.exp(-(((xs - 0.95 * W) / 70) ** 2 + ((ys - 0.95 * H) / 60) ** 2))
    h += 0.45 * np.exp(-(((xs - 0.45 * W) / 120) ** 2 + ((ys - 0.15 * H) / 50) ** 2))
    h += 0.22 * noise(rng, 9, 3) + 0.08 * noise(rng, 22, 8)
    add(col, np.exp(-(np.hypot(xs - peak[0], (ys - peak[1]) * 1.3) / 140) ** 2), (30, 70, 80), 0.6)
    n_lv = 26.0
    hn = h * n_lv
    gy, gx = np.gradient(hn, 1.0 / SS)
    g = np.hypot(gx, gy) + 1e-4
    frac = hn - np.floor(hn)
    dist = np.minimum(frac, 1 - frac) / g                     # px to the nearest contour
    index = (np.round(hn).astype(int) % 5) == 0
    width = np.where(index, 0.9, 0.55)
    lines = np.exp(-(dist / width) ** 2)
    near = np.exp(-(np.hypot(xs - peak[0], ys - peak[1]) / 210) ** 2)
    strength = np.where(index, 0.8, 0.42) * (0.35 + 0.65 * near) * (0.45 + 0.55 * smoothstep(0.1, 0.55, u))
    add(col, lines * strength, (240, 160, 64), 1.0)
    add(col, blur(lines * strength * near, 2.0), (255, 140, 40), 0.5)
    gl = np.zeros_like(u)
    for gxp in np.arange(50, W, 50):
        gl = np.maximum(gl, np.exp(-((xs - gxp) / 0.45) ** 2))
    for gyp in np.arange(50, H, 50):
        gl = np.maximum(gl, np.exp(-((ys - gyp) / 0.45) ** 2))
    add(col, gl, (110, 180, 196), 0.09)
    route = layer()
    dr = ImageDraw.Draw(route)
    pts = [(0.3 * W + t * (peak[0] - 0.3 * W - 14), 0.86 * H + t * (peak[1] - 0.86 * H) - 34 * math.sin(math.pi * t))
           for t in np.linspace(0, 1, 40)]
    for i in range(0, len(pts) - 1, 2):
        dr.line(sc([pts[i], pts[i + 1]]), fill=255, width=SS)
    add(col, to_f(route) * smoothstep(0.25, 0.5, u), (235, 240, 240), 0.45)
    mk = layer()
    dm = ImageDraw.Draw(mk)
    px, py = peak
    dm.ellipse(sc([(px - 9, py - 9), (px + 9, py + 9)]), outline=255, width=int(1.6 * SS))
    for a in range(4):
        ca, sa = math.cos(a * math.pi / 2), math.sin(a * math.pi / 2)
        dm.line(sc([(px + ca * 12, py + sa * 12), (px + ca * 17, py + sa * 17)]), fill=255, width=int(1.6 * SS))
    dm.ellipse(sc([(px - 2, py - 2), (px + 2, py + 2)]), fill=255)
    m = to_f(mk)
    add(col, m, GOLD, 1.0)
    add(col, blur(m, 4.0), (255, 160, 30), 1.6)
    return col


# ---------------------------------------------------------------- 5 SHARDS
def shards(rng):
    xs, ys = grid()
    u, v = xs / W, ys / H
    cell = 34.0
    nx, ny = int(W / cell) + 3, int(H / cell) + 3
    gx = (np.arange(nx)[None, :] - 1) * cell + rng.uniform(-0.36, 0.36, (ny, nx)) * cell
    gy = (np.arange(ny)[:, None] - 1) * cell + rng.uniform(-0.36, 0.36, (ny, nx)) * cell
    hz = noise(rng, 6, 2)
    gz = np.array([[sample(hz, gx[j, i], gy[j, i]) for i in range(nx)] for j in range(ny)]) * 26 + rng.uniform(-9, 9, (ny, nx))
    light = np.array([0.45, -0.55, 0.7])
    light /= np.linalg.norm(light)

    def band(x, y):                      # distance (px) to the seam that rises across the right half
        y_line = H * (1.05 - 1.25 * (x / W - 0.3))
        return abs(y - y_line) * 0.78

    img = Image.new("RGB", (W * SS, H * SS), (0, 0, 0))
    seams = layer()
    di, dsm = ImageDraw.Draw(img), ImageDraw.Draw(seams)
    for j in range(ny - 1):
        for i in range(nx - 1):
            a, b, c, d = (i, j), (i + 1, j), (i + 1, j + 1), (i, j + 1)
            tris = [(a, b, c), (a, c, d)] if rng.random() < 0.5 else [(a, b, d), (b, c, d)]
            for tri in tris:
                p = np.array([[gx[q[1], q[0]], gy[q[1], q[0]], gz[q[1], q[0]]] for q in tri])
                nrm = np.cross(p[1] - p[0], p[2] - p[0])
                nrm = nrm / (np.linalg.norm(nrm) + 1e-6)
                if nrm[2] < 0:
                    nrm = -nrm
                lam = max(0.0, float(nrm @ light))
                cxm, cym = p[:, 0].mean(), p[:, 1].mean()
                base = np.array([16, 22, 32]) + (np.array([58, 70, 92]) - np.array([16, 22, 32])) * lam ** 1.6
                base = base * (0.75 + 0.45 * smoothstep(0.0, 1.0, cxm / W))
                e = math.exp(-(band(cxm, cym) / 26) ** 2) * float(smoothstep(0.32, 0.75, cxm / W))
                c = base * (1 - e) + (EMBER * (1 - e) + GOLD * e) * e * (0.55 + 0.45 * lam)
                pts = sc([(q[0], q[1]) for q in p[:, :2]])
                di.polygon(pts, fill=tuple(int(x) for x in np.clip(c, 0, 255)))
                dsm.line(pts + [pts[0]], fill=int(40 + 215 * e), width=1)
    col = np.asarray(img).astype(np.float32)
    s = to_f(seams)
    hot = s * (s > 0.3)
    col *= (1 - 0.35 * s * (s < 0.3))[..., None]           # dark seams between cool plates
    add(col, hot, (255, 214, 120), 0.8)
    add(col, blur(hot, 3.0), (255, 120, 30), 1.8)
    add(col, np.exp(-(np.hypot((u - 0.85) * 2.2, v - 0.3) / 0.5) ** 2), (120, 150, 190), 0.12)
    return col


# ---------------------------------------------------------------- 6 SCOPE
def scope(rng):
    xs, ys = grid()
    c0 = (0.76 * W, 0.52 * H)
    r = np.hypot(xs - c0[0], ys - c0[1])
    col = vgrad([(0.0, (26, 38, 62)), (120.0, (14, 20, 36)), (420.0, (7, 9, 16))], r)
    th = np.arctan2(ys - c0[1], xs - c0[0])
    rings = np.zeros_like(r)
    for k, rr in enumerate((34, 68, 102, 136, 170, 204, 238)):
        w = 0.9 if rr == 102 else 0.5
        rings = np.maximum(rings, np.exp(-((r - rr) / w) ** 2) * (1.0 if rr == 102 else 0.55))
    add(col, rings, (230, 196, 120), 0.42)
    tk = layer()
    dt = ImageDraw.Draw(tk)
    for deg in range(0, 360, 6):
        a = math.radians(deg)
        ln = 10 if deg % 30 == 0 else 4
        dt.line(sc([(c0[0] + math.cos(a) * 136, c0[1] + math.sin(a) * 136),
                    (c0[0] + math.cos(a) * (136 + ln), c0[1] + math.sin(a) * (136 + ln))]), fill=255, width=SS)
    for a in range(4):
        ca, sa = math.cos(a * math.pi / 2), math.sin(a * math.pi / 2)
        dt.line(sc([(c0[0] + ca * 12, c0[1] + sa * 12), (c0[0] + ca * 260, c0[1] + sa * 260)]), fill=150, width=SS)
    add(col, to_f(tk), (230, 196, 120), 0.45)
    lead = math.radians(-38)
    dth = (lead - th) % (2 * math.pi)                       # angle behind the sweep's leading edge
    trail = np.exp(-dth / 0.7) * (dth < math.radians(100)) * smoothstep(250, 30, r) * smoothstep(4, 16, r)
    add(col, trail, (255, 160, 40), 0.75)
    signed = (th - lead + math.pi) % (2 * math.pi) - math.pi
    edge = np.exp(-((signed * r) / 1.1) ** 2) * (r < 245) * (r > 10)
    add(col, edge, (255, 214, 130), 0.9)
    add(col, blur(edge, 3.0), (255, 150, 40), 0.8)
    blips = layer()
    db = ImageDraw.Draw(blips)
    targets = []
    for _ in range(5):
        a = lead + rng.uniform(0.05, 1.1)
        rr = rng.uniform(40, 225)
        bx, by = c0[0] + math.cos(-a + 2 * lead) * rr, c0[1] + math.sin(-a + 2 * lead) * rr
        targets.append((bx, by))
        q = rng.uniform(1.4, 2.4)
        db.ellipse(sc([(bx - q, by - q), (bx + q, by + q)]), fill=255)
    bx, by = targets[0]
    db.ellipse(sc([(bx - 8, by - 8), (bx + 8, by + 8)]), outline=255, width=SS)
    b = to_f(blips)
    add(col, b, (255, 226, 150), 1.0)
    add(col, blur(b, 3.0), (255, 120, 40), 1.7)
    return col


BANNERS = [ember_ridge, gold_rush, hive, contour, shards, scope]


# ---------------------------------------------------------------- outputs
def write_import(path):
    """2D art import: lossless, mipmaps (the banner picker draws them smaller), never VRAM.
    Writes a new .import (Godot fills in the uid and the rest on import) or fixes these keys."""
    want = {"compress/mode": "0", "mipmaps/generate": "true", "detect_3d/compress_to": "0"}
    imp = path + ".import"
    if os.path.exists(imp):
        text = open(imp).read()
        new = text
        for k, v in want.items():
            pat = re.compile(r"^%s=.*$" % re.escape(k), re.M)
            new = pat.sub("%s=%s" % (k, v), new) if pat.search(new) else new.replace("[params]\n", "[params]\n\n%s=%s\n" % (k, v), 1)
        if new != text:
            open(imp, "w").write(new)
        return
    res = "res://" + os.path.relpath(path, ROOT).replace(os.sep, "/")
    lines = ["[remap]", "", 'importer="texture"', 'type="CompressedTexture2D"', "", "[deps]", "",
             'source_file="%s"' % res, "", "[params]", ""] + ["%s=%s" % kv for kv in want.items()] + [""]
    open(imp, "w").write("\n".join(lines))


def main():
    args = sys.argv[1:]
    preview = None
    if "--preview" in args:
        preview = args[args.index("--preview") + 1]
        del args[args.index("--preview"):args.index("--preview") + 2]
    out = args[0] if args else OUT
    os.makedirs(out, exist_ok=True)
    in_project = os.path.normpath(out) == os.path.normpath(OUT)
    paths = []
    for n, fn in enumerate(BANNERS, start=1):
        img = finish(fn(np.random.default_rng(1000 + n)), 2000 + n)
        path = os.path.join(out, "banner_%d.png" % n)
        img.save(path, optimize=True)
        if in_project:
            write_import(path)
        paths.append(path)
        print("wrote %s  %s  %.0f KB" % (path, NAMES[n - 1], os.path.getsize(path) / 1024))
    if preview:
        sheet = Image.new("RGB", (2 * W + 48, 3 * (H + 40) + 16), (40, 42, 48))
        d = ImageDraw.Draw(sheet)
        for i, p in enumerate(paths):
            x, y = 16 + (i % 2) * (W + 16), 16 + (i // 2) * (H + 40)
            sheet.paste(Image.open(p), (x, y))
            # a mock avatar and name where the profile page puts them
            d.ellipse([x + 24, y + 52, x + 120, y + 148], fill=(60, 62, 70), outline=(255, 194, 14), width=3)
            d.text((x + 136, y + 84), "PLAYER NAME", fill=(255, 255, 255))
            d.text((x + 136, y + 102), "LV 12", fill=(255, 194, 14))
            d.text((x, y + H + 6), "banner_%d  %s" % (i + 1, NAMES[i]), fill=(255, 220, 120))
        sheet.save(preview)
        print("preview", preview)


if __name__ == "__main__":
    main()
