"""Periodic (tileable) noise + image helpers for procedural textures.

Every operator here is periodic over the image size (FFT noise, wrap-around
worley, np.roll gradients, wrap-mode filters), so results tile seamlessly.
Images are float arrays in [0, 1]; colour images are (h, w, 3).
"""
from __future__ import annotations

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def norm01(a):
    a = a - a.min()
    return a / (a.max() + 1e-12)


def fft_noise(n, beta, rng, fmin=1.0, fmax=None, aniso=(1.0, 1.0), m=None):
    """Periodic fractal noise: amplitude spectrum ~ f^-beta. Zero mean, unit std.

    aniso=(ax, ay): ax > 1 stretches features along x (horizontal streaks)."""
    m = m or n
    fx = np.fft.fftfreq(m, 1.0 / m)
    fy = np.fft.fftfreq(n, 1.0 / n)
    FX, FY = np.meshgrid(fx, fy)
    f = np.hypot(FX * aniso[0], FY * aniso[1])
    with np.errstate(divide="ignore"):
        amp = np.where(f > 0, f ** (-beta), 0.0)
    amp[f < fmin] = 0.0
    if fmax is not None:
        amp *= np.exp(-(f / fmax) ** 2)
    spec = amp * (rng.standard_normal((n, m)) + 1j * rng.standard_normal((n, m)))
    img = np.fft.ifft2(spec).real
    img -= img.mean()
    return img / (img.std() + 1e-12)


def blur(img, sigma):
    if img.ndim == 3:
        return np.stack([ndimage.gaussian_filter(img[..., c], sigma, mode="wrap") for c in range(img.shape[2])], -1)
    return ndimage.gaussian_filter(img, sigma, mode="wrap")


def warp(img, dx, dy, order=1):
    """Sample img at (x+dx, y+dy) with wrap-around."""
    n, m = img.shape[:2]
    yy, xx = np.mgrid[0:n, 0:m].astype(float)
    coords = [yy + dy, xx + dx]
    if img.ndim == 3:
        return np.stack([ndimage.map_coordinates(img[..., c], coords, order=order, mode="grid-wrap")
                         for c in range(img.shape[2])], -1)
    return ndimage.map_coordinates(img, coords, order=order, mode="grid-wrap")


def grid_coords(n, cells, dx=None, dy=None):
    c = (np.arange(n) + 0.5) * cells / n
    X, Y = np.meshgrid(c, c)
    if dx is not None:
        X = X + dx * cells / n
        Y = Y + dy * cells / n
    return X, Y


def worley(n, cells, rng, jitter=0.9, dx=None, dy=None, pts=None):
    """Periodic cellular noise. Returns F1, F2 (cell units), id of nearest cell, and
    the offset vector (pixel - feature point) in cell units."""
    if pts is None:
        pts = 0.5 + (rng.random((cells, cells, 2)) - 0.5) * jitter
    X, Y = grid_coords(n, cells, dx, dy)
    ci = np.floor(X).astype(int)
    cj = np.floor(Y).astype(int)
    F1 = np.full(X.shape, 1e9)
    F2 = np.full(X.shape, 1e9)
    ID = np.zeros(X.shape, dtype=np.int64)
    VX = np.zeros(X.shape)
    VY = np.zeros(X.shape)
    for dj in (-1, 0, 1):
        for di in (-1, 0, 1):
            ni, nj = ci + di, cj + dj
            wi, wj = ni % cells, nj % cells
            px = ni + pts[wj, wi, 0]
            py = nj + pts[wj, wi, 1]
            vx, vy = X - px, Y - py
            d = np.hypot(vx, vy)
            closer = d < F1
            F2 = np.where(closer, F1, np.minimum(F2, d))
            ID = np.where(closer, wj * cells + wi, ID)
            VX = np.where(closer, vx, VX)
            VY = np.where(closer, vy, VY)
            F1 = np.where(closer, d, F1)
    return F1, F2, ID, VX, VY


def normal_map(h, strength=1.0):
    """Tangent-space normal map from height (pixel units), OpenGL convention (+Y up)."""
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5   # image y points down
    nx = -dx * strength
    ny = dy * strength
    nz = np.ones_like(h)
    ln = np.sqrt(nx * nx + ny * ny + nz * nz)
    return np.stack([nx / ln, ny / ln, nz / ln], -1) * 0.5 + 0.5


def ao_from_height(h, sigma, k):
    """Cheap ambient occlusion: darken where the surface is below its local mean."""
    return np.clip(1.0 - k * np.maximum(blur(h, sigma) - h, 0), 0, 1)


def lerp(a, b, t):
    a = np.asarray(a, float)
    b = np.asarray(b, float)
    t = np.asarray(t, float)
    if t.ndim == 2:
        t = t[..., None]
    return a + (b - a) * t


def palette(t, stops):
    """Map t in [0,1] through colour stops [(pos, (r,g,b) 0-255), ...]."""
    pos = np.array([p for p, _ in stops], float)
    cols = np.array([c for _, c in stops], float) / 255.0
    out = np.empty(t.shape + (3,))
    for c in range(3):
        out[..., c] = np.interp(t, pos, cols[:, c])
    return out


def rgb(c):
    return np.array(c, float) / 255.0


def to_u8(img):
    return np.clip(np.round(img * 255.0), 0, 255).astype(np.uint8)


def save(img, path):
    Image.fromarray(to_u8(img)).save(path, optimize=True)


class WrapCanvas:
    """Supersampled PIL canvas that draws primitives with wrap-around copies."""

    def __init__(self, n, ss=2, mode="L", bg=0):
        self.n, self.ss = n, ss
        self.im = Image.new(mode, (n * ss, n * ss), bg)
        self.d = ImageDraw.Draw(self.im)

    def _copies(self, xs, ys, margin):
        n = self.n
        offs_x = [0] + ([n] if min(xs) < margin else []) + ([-n] if max(xs) > n - margin else [])
        offs_y = [0] + ([n] if min(ys) < margin else []) + ([-n] if max(ys) > n - margin else [])
        return [(ox, oy) for ox in offs_x for oy in offs_y]

    def line(self, pts, fill, width=1.0):
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        s = self.ss
        for ox, oy in self._copies(xs, ys, width + 2):
            self.d.line([((x + ox) * s, (y + oy) * s) for x, y in pts], fill=fill,
                        width=max(1, int(round(width * s))), joint="curve")

    def polygon(self, pts, fill):
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        s = self.ss
        for ox, oy in self._copies(xs, ys, 2):
            self.d.polygon([((x + ox) * s, (y + oy) * s) for x, y in pts], fill=fill)

    def ellipse(self, cx, cy, rx, ry, fill):
        s = self.ss
        for ox, oy in self._copies([cx - rx, cx + rx], [cy - ry, cy + ry], 2):
            self.d.ellipse([(cx - rx + ox) * s, (cy - ry + oy) * s, (cx + rx + ox) * s, (cy + ry + oy) * s],
                           fill=fill)

    def result(self):
        im = self.im.resize((self.n, self.n), Image.LANCZOS) if self.ss > 1 else self.im
        a = np.asarray(im).astype(float) / 255.0
        return a


def seam_score(img):
    """Ratio of the wrap-around neighbour difference to the interior neighbour difference
    (per axis).  ~1.0 means seamless; a visible seam gives values >> 1."""
    a = img.astype(float)
    if a.ndim == 3:
        a = a[..., :3].mean(-1) if a.shape[2] >= 3 else a[..., 0]
    inner_x = np.mean(np.abs(np.diff(a, axis=1)))
    wrap_x = np.mean(np.abs(a[:, 0] - a[:, -1]))
    inner_y = np.mean(np.abs(np.diff(a, axis=0)))
    wrap_y = np.mean(np.abs(a[0, :] - a[-1, :]))
    return wrap_x / (inner_x + 1e-9), wrap_y / (inner_y + 1e-9)


def scatter_ellipses(n, cells, rng, pres, rmin, rmax, amax=1.5, jitter=0.85, dx=None, dy=None, reach=1):
    """Periodic scatter of rotated ellipses (one candidate per grid cell), evaluated over
    neighbouring cells so shapes are never clipped by cell borders.  Overlaps resolve
    by a random stacking order.  Returns coverage (anti-aliased), dome height (0..1),
    id of the visible ellipse (-1 = none), and local unit coords (u, v) of that ellipse."""
    pts = 0.5 + (rng.random((cells, cells, 2)) - 0.5) * jitter
    rad = rng.uniform(rmin, rmax, (cells, cells))
    asp = rng.uniform(1.0, amax, (cells, cells))
    ang = rng.uniform(0, np.pi, (cells, cells))
    present = rng.random((cells, cells)) < pres
    zord = rng.random((cells, cells))
    X, Y = grid_coords(n, cells, dx, dy)
    ci = np.floor(X).astype(int)
    cj = np.floor(Y).astype(int)
    px_per_cell = n / cells
    best = np.full(X.shape, -1.0)
    cov = np.zeros(X.shape)
    dome = np.zeros(X.shape)
    ID = np.full(X.shape, -1, dtype=np.int64)
    U = np.zeros(X.shape)
    V = np.zeros(X.shape)
    rng_ = range(-reach, reach + 1)
    for dj in rng_:
        for di in rng_:
            ni, nj = ci + di, cj + dj
            wi, wj = ni % cells, nj % cells
            vx = X - (ni + pts[wj, wi, 0])
            vy = Y - (nj + pts[wj, wi, 1])
            c, s = np.cos(ang[wj, wi]), np.sin(ang[wj, wi])
            a = rad[wj, wi] * np.sqrt(asp[wj, wi])
            b = rad[wj, wi] / np.sqrt(asp[wj, wi])
            u = (vx * c + vy * s) / a
            v = (-vx * s + vy * c) / b
            e = np.sqrt(u * u + v * v)
            aa = 1.2 / (b * px_per_cell)
            cv = smoothstep(1.0, 1.0 - aa, e) * present[wj, wi]
            z = zord[wj, wi]
            top = (cv > 0.5) & (z > best)
            cov = np.maximum(cov, cv)
            dome = np.where(top, np.sqrt(np.clip(1 - e * e, 0, 1)), dome)
            ID = np.where(top, wj * cells + wi, ID)
            U = np.where(top, u, U)
            V = np.where(top, v, V)
            best = np.where(top, z, best)
    return cov, dome, ID, U, V
