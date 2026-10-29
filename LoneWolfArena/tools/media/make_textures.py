"""Procedural seamless textures for Lone Wolf Arena.

Usage: python3 make_textures.py [out_dir] [name ...]
Writes into assets/textures/ (or out_dir) the 1024x1024 tileable metal_painted and wood_planks albedo
maps, the corrugated_n normal map, hex_pattern (shield wall) and the glow / muzzle_flash FX sprites
(name "fx"); the warehouse textures come from make_warehouse_textures.py. The contact sheet goes to
tools/media/_work/textures_preview.png, outside res://.
"""
from __future__ import annotations

import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

from texlib import (WrapCanvas, fft_noise, lerp, normal_map, palette, rgb, save, seam_score, smoothstep,
                    worley)

N = 1024
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "assets", "textures")
FONT = os.path.join(ROOT, "assets", "fonts", "ui_semibold.ttf")
PREVIEW = os.path.join(HERE, "_work", "textures_preview.png")


def R(seed):
    return np.random.default_rng(seed)


def mul(col, f):
    return col * np.asarray(f)[..., None]


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
ALBEDO = [  # name, fn, normal map name (None: not shipped), normal strength
    ("metal_painted", metal_painted, None, 0),
    ("wood_planks", wood_planks, None, 0),
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
        save_rgba(muzzle_flash(), os.path.join(out, "muzzle_flash.png"))
    for nm_, (sx, sy) in report:
        flag = "" if max(sx, sy) < 1.6 else "  <-- SEAM?"
        print(f"   seam {nm_:16s} x {sx:5.2f}  y {sy:5.2f}{flag}")
    return report


TILED = ["metal_painted", "corrugated_n", "wood_planks", "hex_pattern"]   # shown 2x2 tiled
PREVIEW_ORDER = TILED + ["glow", "muzzle_flash"]                         # sprites: alpha over a checker


def preview(out, path=PREVIEW, cell=384, cols=3):
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
    os.makedirs(os.path.dirname(path), exist_ok=True)
    sheet.save(path, optimize=True)
    print("preview:", path)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else OUT
    only = set(sys.argv[2:]) or None
    build(out, only)
    preview(out)
