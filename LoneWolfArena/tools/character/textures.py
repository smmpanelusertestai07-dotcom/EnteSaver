"""Texture processing (PIL/numpy): skin tone grading, recolors, downscaling.
All outputs are written to char_config.TEX_DIR as JPEG (opaque) or PNG (alpha)."""
import os
import numpy as np
from PIL import Image, ImageFilter

import char_config as CFG

os.makedirs(CFG.TEX_DIR, exist_ok=True)


def load_rgba(path):
    im = Image.open(path)
    im.load()
    return np.asarray(im.convert("RGBA")).astype(np.float32) / 255.0


def save(arr, name, size, alpha=False, quality=90):
    """arr float RGBA 0..1. size = max side in px."""
    arr = np.clip(arr, 0, 1)
    im = Image.fromarray((arr * 255 + 0.5).astype(np.uint8), "RGBA")
    if max(im.size) > size:
        s = size / max(im.size)
        im = im.resize((max(1, int(round(im.size[0] * s))), max(1, int(round(im.size[1] * s)))), Image.LANCZOS)
    path = os.path.join(CFG.TEX_DIR, name + (".png" if alpha else ".jpg"))
    if alpha:
        im.save(path, optimize=True)
    else:
        im.convert("RGB").save(path, quality=quality, optimize=True)
    return path


def srgb_to_lin(c):
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def lin_to_srgb(c):
    c = np.clip(c, 0, 1)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def luminance(rgb):
    return rgb[..., 0] * 0.2126 + rgb[..., 1] * 0.7152 + rgb[..., 2] * 0.0722


# ----------------------------------------------------------------------------- skin
SKIN_TARGET = np.array([0.66, 0.46, 0.34])   # medium-brown South-Asian (sRGB, mid skin)


def grade_skin(src_path):
    a = load_rgba(src_path)
    rgb = a[..., :3]
    # reference = median colour of typical skin pixels (exclude background-ish uniform pixels: use all)
    h, w = rgb.shape[:2]
    sample = rgb[h // 8: h * 7 // 8: 4, w // 16: w * 10 // 16: 4].reshape(-1, 3)
    ref = np.median(sample, axis=0)
    lin = srgb_to_lin(rgb)
    gain = srgb_to_lin(SKIN_TARGET) / np.maximum(srgb_to_lin(ref), 1e-4)
    out = lin * gain
    # slightly reduce local contrast of very red areas (lips/nipples) so they read as darker brown-pink
    out = lin_to_srgb(out)
    res = np.concatenate([out, np.ones_like(out[..., :1])], axis=-1)
    return res, ref


def paint_scalp(skin_rgba, mask, color=(0.10, 0.075, 0.06), strength=0.92):
    """Blend a dark 'short hair' tone into the scalp (mask 0..1 same size)."""
    c = np.array(color, dtype=np.float32)
    rgb = skin_rgba[..., :3]
    lum = luminance(rgb)[..., None]
    hair = c * (0.75 + 0.5 * (lum / max(lum.mean(), 1e-3) - 1.0) * 0.6)
    m = (mask * strength)[..., None]
    skin_rgba[..., :3] = rgb * (1 - m) + hair * m
    return skin_rgba


# ----------------------------------------------------------------------------- recolors
def tint(src_path, color, keep_detail=0.85, gamma=1.0, contrast=1.0):
    """Luminance-preserving recolor of a (cloth) texture to `color` (sRGB 0..1).
    The relative luminance pattern is kept; the mean maps to `color`."""
    a = load_rgba(src_path)
    rgb = a[..., :3]
    lum = luminance(srgb_to_lin(rgb))
    alpha = a[..., 3]
    valid = alpha > 0.5
    m = np.median(lum[valid]) if valid.any() else np.median(lum)
    rel = (lum / max(m, 1e-4)) ** gamma
    rel = np.clip(rel, 0.35, 1.8)
    rel = 1.0 + (rel - 1.0) * keep_detail * contrast
    out = srgb_to_lin(np.array(color, dtype=np.float32))[None, None, :] * rel[..., None]
    out = lin_to_srgb(out)
    return np.concatenate([out, alpha[..., None]], axis=-1)


def flat(color, size=16):
    arr = np.ones((size, size, 4), dtype=np.float32)
    arr[..., :3] = color
    return arr


def hue_mask(rgba, hue_lo, hue_hi, sat_min=0.25, val_min=0.08):
    """Mask of pixels whose hue (0..360) is within [hue_lo, hue_hi] (wraps)."""
    rgb = rgba[..., :3]
    mx = rgb.max(-1)
    mn = rgb.min(-1)
    d = mx - mn + 1e-6
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    hue = np.where(mx == r, (g - b) / d % 6, np.where(mx == g, (b - r) / d + 2, (r - g) / d + 4)) * 60.0
    sat = d / (mx + 1e-6)
    if hue_lo <= hue_hi:
        hm = (hue >= hue_lo) & (hue <= hue_hi)
    else:
        hm = (hue >= hue_lo) | (hue <= hue_hi)
    return (hm & (sat >= sat_min) & (mx >= val_min)).astype(np.float32)


def soften(mask, radius=1.5):
    im = Image.fromarray((np.clip(mask, 0, 1) * 255).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(radius))
    return np.asarray(im).astype(np.float32) / 255.0
