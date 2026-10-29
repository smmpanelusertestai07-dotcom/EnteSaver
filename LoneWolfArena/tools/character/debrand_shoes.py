"""Removes third-party branding from the sneaker textures.

The CC0 MakeHuman shoe photo (shoes05) behind the ROOKIE and NEON STRIKER outfits shows a
sportswear maker's logo on the outsole and its three side stripes. CC0 does not clear
trademarks, so both are painted out: the logo box and the dark stripe bars are filled from
the surrounding material (a diffusion fill), then a little grain is put back.

The game uses the textures Godot extracts next to character.glb
(assets/character/character_<name>.jpg); the same JPEGs are embedded in the GLB, so both
copies are rewritten (a re-import cannot bring the old ones back).

usage: python3 tools/character/debrand_shoes.py           rewrite the textures and the GLB
       python3 tools/character/debrand_shoes.py --check   exit 1 if the marks are still there
"""
import io
import json
import os
import struct
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
CHAR_DIR = os.path.join(ROOT, "assets", "character")
GLB = os.path.join(CHAR_DIR, "character.glb")
TEXTURES = ["default_Shoes", "neon_Shoes"]       # same UV layout, recoloured accents

# Areas in the 512 x 512 texture: (x0, y0, x1, y1).
SOLE_LOGO = (132, 76, 166, 110)                  # the whole box is refilled
STRIPE_AREAS = [(100, 266, 200, 368), (290, 268, 420, 366)]   # only the dark bars inside
STRIPE_DARK = 95                                 # luminance below this inside an area = bar
# Where only the bars are dark (the panels' perforations are mid-grey): used by --check.
STRIPE_CORES = [(112, 282, 188, 358), (302, 282, 398, 356)]


def _luma(a):
    return 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]


def _dilate(mask, r):
    out = mask.copy()
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            out |= np.roll(np.roll(mask, dy, 0), dx, 1)
    return out


def brand_mask(a):
    """Pixels to refill: the sole-logo box and the dark stripe bars (grown by 2 px). A bar is a
    dark blob lying wholly inside its area; dark blobs that reach the area's edge belong to
    the shoe's own dark parts and stay."""
    h, w = a.shape[:2]
    mask = np.zeros((h, w), bool)
    x0, y0, x1, y1 = SOLE_LOGO
    mask[y0:y1, x0:x1] = True
    lum = _luma(a.astype(np.float32))
    for x0, y0, x1, y1 in STRIPE_AREAS:
        dark = lum[y0:y1, x0:x1] < STRIPE_DARK
        labels, count = ndimage.label(dark)
        bars = np.zeros_like(dark)
        for k in range(1, count + 1):
            blob = labels == k
            ys, xs = np.nonzero(blob)
            touches = ys.min() == 0 or xs.min() == 0 or ys.max() == dark.shape[0] - 1 or xs.max() == dark.shape[1] - 1
            if not touches and blob.sum() >= 30:
                bars |= blob
        full = np.zeros((h, w), bool)
        full[y0:y1, x0:x1] = bars
        mask |= _dilate(full, 2)
    return mask


def diffusion_fill(a, mask, iterations=600):
    """Fills masked pixels with the average of their neighbours until it settles (a Laplace
    fill), seeded from the unmasked surroundings."""
    out = a.astype(np.float32).copy()
    known = ~mask
    out[mask] = 0.0
    weight = known.astype(np.float32)
    acc = out * weight[..., None]
    for _ in range(iterations):
        s = np.zeros_like(acc)
        n = np.zeros_like(weight)
        for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            s += np.roll(np.roll(acc, dy, 0), dx, 1)
            n += np.roll(np.roll(weight, dy, 0), dx, 1)
        fill = mask & (n > 0)
        acc[fill] = s[fill] / n[fill][:, None]
        weight[fill] = 1.0
    return acc


def debrand(jpeg_bytes):
    a = np.asarray(Image.open(io.BytesIO(jpeg_bytes)).convert("RGB"))
    mask = brand_mask(a)
    filled = diffusion_fill(a, mask)
    rng = np.random.default_rng(7)
    grain = rng.normal(0.0, 3.0, filled.shape[:2])[..., None]
    filled[mask] += grain[mask]
    out = Image.fromarray(np.clip(filled, 0, 255).astype(np.uint8))
    buf = io.BytesIO()
    out.save(buf, "JPEG", quality=92, optimize=True)
    return buf.getvalue()


def still_branded(jpeg_bytes):
    """True when the side panels still hold dark bars: the originals are ~30 % very dark
    pixels in the core boxes, a clean panel has none (the check used by --check)."""
    a = np.asarray(Image.open(io.BytesIO(jpeg_bytes)).convert("RGB")).astype(np.float32)
    lum = _luma(a)
    return any((lum[y0:y1, x0:x1] < 70).mean() > 0.03 for x0, y0, x1, y1 in STRIPE_CORES)


def read_glb(path):
    data = open(path, "rb").read()
    jlen = struct.unpack("<I", data[12:16])[0]
    j = json.loads(data[20:20 + jlen])
    off = 20 + jlen
    blen = struct.unpack("<I", data[off:off + 4])[0]
    return j, data[off + 8:off + 8 + blen]


def write_glb(path, j, views_data):
    """Writes the GLB with each bufferView's bytes taken from views_data (4-byte aligned)."""
    blob = bytearray()
    for i, v in enumerate(j["bufferViews"]):
        while len(blob) % 4:
            blob.append(0)
        v["byteOffset"] = len(blob)
        v["byteLength"] = len(views_data[i])
        blob += views_data[i]
    while len(blob) % 4:
        blob.append(0)
    j["buffers"][0]["byteLength"] = len(blob)
    js = json.dumps(j, separators=(",", ":")).encode()
    while len(js) % 4:
        js += b" "
    total = 12 + 8 + len(js) + 8 + len(blob)
    with open(path, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, total))
        f.write(struct.pack("<I4s", len(js), b"JSON") + js)
        f.write(struct.pack("<I4s", len(blob), b"BIN\x00") + bytes(blob))


def main():
    check = "--check" in sys.argv
    j, binb = read_glb(GLB)
    if len(j["buffers"]) != 1:
        sys.exit("expected one buffer in character.glb")
    views = [binb[v.get("byteOffset", 0):v.get("byteOffset", 0) + v["byteLength"]] for v in j["bufferViews"]]
    by_name = {img.get("name"): img["bufferView"] for img in j["images"]}
    bad = []
    for name in TEXTURES:
        tex_path = os.path.join(CHAR_DIR, "character_%s.jpg" % name)
        current = open(tex_path, "rb").read()
        if check:
            if still_branded(current) or still_branded(views[by_name[name]]):
                bad.append(name)
            continue
        if not still_branded(current):
            print("already clean:", name)
            new = current
        else:
            new = debrand(current)
            with open(tex_path, "wb") as f:
                f.write(new)
            print("cleaned:", name)
        views[by_name[name]] = new
    if check:
        print("still branded: " + (", ".join(bad) if bad else "nothing"))
        sys.exit(1 if bad else 0)
    write_glb(GLB, j, views)
    print("rewrote", os.path.relpath(GLB, ROOT))


if __name__ == "__main__":
    main()
