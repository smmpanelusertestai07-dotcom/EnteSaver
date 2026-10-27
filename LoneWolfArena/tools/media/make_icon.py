"""App icon + title emblem for LONE WOLF ARENA (original low-poly wolf over a crosshair).

Drawn with Pillow at 4x and downsampled with Lanczos for anti-aliasing.
Usage: python3 make_icon.py [out_dir]
"""
from __future__ import annotations

import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy import ndimage

SS = 4
CHARCOAL = (18, 19, 23)
TOP = np.array([255, 214, 84], float)      # amber-yellow
BOTTOM = np.array([232, 74, 22], float)     # deep orange
RING = (236, 112, 38)

# ---------------------------------------------------------------- geometry
# right half (x >= 0.5) in a unit box, y down; mirrored for the left half
P = {
    "T0": (0.50, 0.25), "E1": (0.585, 0.215), "E2": (0.725, 0.035), "E3": (0.80, 0.30),
    "C1": (0.855, 0.40), "C2": (0.955, 0.50), "C3": (0.875, 0.545), "C4": (0.935, 0.635),
    "C5": (0.82, 0.655), "J1": (0.77, 0.73), "M1": (0.645, 0.80), "M2": (0.565, 0.925),
    "B0": (0.50, 0.95),
    "F0": (0.50, 0.40), "F1": (0.64, 0.355), "F2": (0.735, 0.445), "F3": (0.765, 0.565),
    "N0": (0.50, 0.63), "N1": (0.575, 0.60), "N2": (0.62, 0.72), "N3": (0.50, 0.80),
}
OUTLINE_R = ["T0", "E1", "E2", "E3", "C1", "C2", "C3", "C4", "C5", "J1", "M1", "M2", "B0"]
FACETS = [  # (points, shade)
    (("T0", "E1", "F1"), 1.10), (("T0", "F1", "F0"), 1.16), (("E1", "E2", "E3"), 1.06),
    (("E1", "E3", "F1"), 1.00), (("F1", "E3", "C1"), 0.92), (("F1", "C1", "F2"), 0.98),
    (("C1", "C2", "C3"), 0.80), (("F2", "C1", "C3"), 0.88), (("F2", "C3", "F3"), 0.93),
    (("C3", "C4", "C5"), 0.74), (("F3", "C3", "C5"), 0.84), (("F3", "C5", "J1"), 0.78),
    (("F0", "F1", "F2"), 1.04), (("F0", "F2", "N1"), 0.97), (("F0", "N1", "N0"), 1.12),
    (("F2", "F3", "N1"), 0.9), (("N1", "F3", "N2"), 0.86), (("F3", "J1", "N2"), 0.8),
    (("J1", "M1", "N2"), 0.74), (("N0", "N1", "N3"), 1.08), (("N1", "N2", "N3"), 0.95),
    (("N2", "M1", "N3"), 0.86), (("M1", "M2", "N3"), 0.78), (("M2", "B0", "N3"), 0.72),
]
INNER_EAR = [(0.615, 0.225), (0.715, 0.095), (0.765, 0.29)]
EYE = [(0.565, 0.505), (0.715, 0.445), (0.69, 0.50), (0.60, 0.532)]
GLINT = [(0.605, 0.502), (0.683, 0.468), (0.668, 0.49), (0.618, 0.511)]
BROW_MARK = [(0.50, 0.29), (0.555, 0.355), (0.50, 0.46), (0.445, 0.355)]
NOSE = [(0.452, 0.785), (0.548, 0.785), (0.528, 0.83), (0.50, 0.848), (0.472, 0.83)]
MOUTH = [(0.50, 0.846), (0.50, 0.872), (0.528, 0.892)]


def mirror(pts):
    return [(1.0 - x, y) for x, y in pts]


def grad_color(y, shade):
    t = np.clip((y - 0.03) / 0.92, 0, 1)
    c = TOP * (1 - t) + BOTTOM * t
    return tuple(int(v) for v in np.clip(c * shade, 0, 255))


# ---------------------------------------------------------------- drawing
def draw_emblem(size, outline=True, crosshair=True):
    """Return an RGBA emblem of `size` px (drawn at 4x).  The artwork spans the
    central circle of radius 0.48*size."""
    S = size * SS
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx = cy = S / 2
    if crosshair:
        R = 0.40 * S
        w = 0.03 * S
        ring = Image.new("L", (S, S), 0)
        rd = ImageDraw.Draw(ring)
        rd.ellipse([cx - R - w / 2, cy - R - w / 2, cx + R + w / 2, cy + R + w / 2], fill=255)
        rd.ellipse([cx - R + w / 2, cy - R + w / 2, cx + R - w / 2, cy + R - w / 2], fill=0)
        r2 = 0.335 * S
        w2 = 0.008 * S
        rd.ellipse([cx - r2 - w2, cy - r2 - w2, cx + r2 + w2, cy + r2 + w2], fill=170)
        rd.ellipse([cx - r2 + w2, cy - r2 + w2, cx + r2 - w2, cy + r2 - w2], fill=0)
        tw = 0.034 * S
        for ang in (0, 90, 180, 270):
            a = np.radians(ang)
            r_in, r_out = 0.33 * S, 0.48 * S
            ux, uy = np.cos(a), np.sin(a)
            px, py = -uy, ux
            pts = [(cx + ux * r_in + px * tw / 2, cy + uy * r_in + py * tw / 2),
                   (cx + ux * r_out + px * tw / 2, cy + uy * r_out + py * tw / 2),
                   (cx + ux * r_out - px * tw / 2, cy + uy * r_out - py * tw / 2),
                   (cx + ux * r_in - px * tw / 2, cy + uy * r_in - py * tw / 2)]
            rd.polygon(pts, fill=255)
        for ang in (45, 135, 225, 315):
            a = np.radians(ang)
            ux, uy = np.cos(a), np.sin(a)
            px, py = -uy, ux
            r_in, r_out = 0.415 * S, 0.455 * S
            t2 = 0.016 * S
            pts = [(cx + ux * r_in + px * t2 / 2, cy + uy * r_in + py * t2 / 2),
                   (cx + ux * r_out + px * t2 / 2, cy + uy * r_out + py * t2 / 2),
                   (cx + ux * r_out - px * t2 / 2, cy + uy * r_out - py * t2 / 2),
                   (cx + ux * r_in - px * t2 / 2, cy + uy * r_in - py * t2 / 2)]
            rd.polygon(pts, fill=255)
        # dark keyline around the crosshair so it reads on any background
        ra = np.asarray(ring) > 0
        dist = ndimage.distance_transform_edt(~ra)
        key = (dist < 0.012 * S) & ~ra
        layer = np.zeros((S, S, 4), np.uint8)
        layer[key] = (*CHARCOAL, 255)
        rr = np.asarray(ring).astype(float) / 255
        yy = np.linspace(0, 1, S)[:, None]
        col = (TOP * 0.25 + BOTTOM * 0.75) * (1 - yy[..., None] * 0.15) + np.array([20, 10, 0]) * (1 - yy[..., None])
        col = np.broadcast_to(np.clip(col, 0, 255), (S, S, 3))
        m = rr > 0
        layer[m, :3] = col[m].astype(np.uint8)
        layer[m, 3] = (rr[m] * 255).astype(np.uint8)
        img = Image.alpha_composite(img, Image.fromarray(layer, "RGBA"))
        d = ImageDraw.Draw(img)

    box = 0.80 * S
    ox, oy = cx - box / 2, cy - box / 2 + 0.015 * S

    def tp(pts):
        return [(ox + x * box, oy + y * box) for x, y in pts]

    sil_r = [P[k] for k in OUTLINE_R]
    sil = sil_r + mirror(sil_r[::-1])[1:-1]
    if outline:
        m = Image.new("L", (S, S), 0)
        ImageDraw.Draw(m).polygon(tp(sil), fill=255)
        ma = np.asarray(m) > 0
        dist = ndimage.distance_transform_edt(~ma)
        stroke = (dist < 0.022 * S).astype(np.uint8) * 255
        st = Image.fromarray(stroke, "L").filter(ImageFilter.GaussianBlur(SS * 0.5))
        dark = Image.new("RGBA", (S, S), (*CHARCOAL, 255))
        img.paste(dark, (0, 0), st)
        d = ImageDraw.Draw(img)
    d.polygon(tp(sil), fill=grad_color(0.5, 0.85))
    for side in (0, 1):
        for pts_k, shade in FACETS:
            pts = [P[k] for k in pts_k]
            if side:
                pts = mirror(pts)
                shade *= 0.9
            yc = np.mean([p[1] for p in pts])
            d.polygon(tp(pts), fill=grad_color(yc, shade))
    # facet edge lines (subtle low-poly seams), composited so alpha is preserved
    seams = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(seams)
    for side in (0, 1):
        for pts_k, _ in FACETS:
            pts = [P[k] for k in pts_k]
            if side:
                pts = mirror(pts)
            q = tp(pts)
            sd.line(q + [q[0]], fill=(110, 36, 8, 255), width=max(1, int(0.0028 * S)))
    sil_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sil_mask).polygon(tp(sil), fill=255)
    sa = np.asarray(seams).copy()
    sa[..., 3] = (sa[..., 3].astype(float) * 0.32 * (np.asarray(sil_mask) / 255.0)).astype(np.uint8)
    img = Image.alpha_composite(img, Image.fromarray(sa, "RGBA"))
    d = ImageDraw.Draw(img)
    for side in (0, 1):
        f = mirror if side else (lambda p: p)
        d.polygon(tp(f(INNER_EAR)), fill=(150, 46, 16))
        d.polygon(tp(f(EYE)), fill=CHARCOAL)
        d.polygon(tp(f(GLINT)), fill=(255, 236, 170))
        d.line(tp(f(MOUTH)), fill=CHARCOAL, width=int(0.0075 * S), joint="curve")
    d.polygon(tp(BROW_MARK), fill=grad_color(0.33, 0.86))
    d.polygon(tp(NOSE), fill=CHARCOAL)
    return img.resize((size, size), Image.LANCZOS)


def background(size, glow=True, hexes=True):
    S = size
    yy, xx = np.mgrid[0:S, 0:S].astype(float) + 0.5
    r = np.hypot(xx - S / 2, yy - S / 2) / (S / 2)
    base_in = np.array([44, 46, 53], float)
    base_out = np.array([14, 15, 18], float)
    t = np.clip(r / 1.3, 0, 1) ** 1.2
    col = base_in * (1 - t[..., None]) + base_out * t[..., None]
    if hexes:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from make_textures import hex_pattern  # noqa: E402
        hx = np.asarray(Image.fromarray((hex_pattern(512)[..., 0] * 255).astype(np.uint8)).resize(
            (S, S), Image.LANCZOS)).astype(float) / 255
        col += hx[..., None] * np.array([255, 140, 60]) * 0.05 * np.clip(1.1 - r, 0, 1)[..., None]
    if glow:
        g = np.exp(-(r / 0.55) ** 2)
        col += g[..., None] * np.array([235, 92, 24]) * 0.32
    return Image.fromarray(np.clip(col, 0, 255).astype(np.uint8), "RGB")


def build(out):
    os.makedirs(out, exist_ok=True)
    emblem = draw_emblem(1024)
    emblem.save(os.path.join(out, "emblem_1024.png"), optimize=True)
    for size in (512, 192):
        bg = background(size).convert("RGBA")
        art = int(round(size * 0.86))
        e = draw_emblem(art if size >= 256 else 512).resize((art, art), Image.LANCZOS)
        off = (size - art) // 2
        bg.alpha_composite(e, (off, off))
        bg.convert("RGB").save(os.path.join(out, f"icon_{size}.png"), optimize=True)
    # adaptive icon layers (432 = 108dp @ xxxhdpi). Artwork inside the central 66 %.
    S = 432
    background(S).save(os.path.join(out, "icon_bg_432.png"), optimize=True)
    art = int(0.326 * S / 0.495)                 # artwork (incl. keyline) radius is ~0.495 of its box
    fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    fg.alpha_composite(draw_emblem(art), ((S - art) // 2, (S - art) // 2))
    fg.save(os.path.join(out, "icon_fg_432.png"), optimize=True)
    a = np.asarray(fg)[..., 3]
    ys, xs = np.nonzero(a > 8)
    rr = np.hypot(xs - S / 2 + 0.5, ys - S / 2 + 0.5).max()
    print(f"fg artwork max radius {rr:.1f}px = {2 * rr / S * 100:.1f}% of canvas diameter (safe <= 66%)")


def preview(out, path):
    sheet = Image.new("RGB", (1400, 560), (70, 72, 78))
    e = Image.open(os.path.join(out, "emblem_1024.png")).resize((512, 512), Image.LANCZOS)
    chk = Image.new("RGBA", (512, 512), (200, 200, 205, 255))
    dd = ImageDraw.Draw(chk)
    for y in range(0, 512, 32):
        for x in range(0, 512, 32):
            if (x // 32 + y // 32) % 2:
                dd.rectangle([x, y, x + 31, y + 31], fill=(150, 150, 158, 255))
    sheet.paste(Image.alpha_composite(chk, e).convert("RGB"), (16, 16))
    sheet.paste(Image.open(os.path.join(out, "icon_512.png")).resize((384, 384), Image.LANCZOS), (544, 16))
    sheet.paste(Image.open(os.path.join(out, "icon_192.png")), (944, 16))
    sheet.paste(Image.open(os.path.join(out, "icon_192.png")).resize((96, 96), Image.LANCZOS), (1150, 16))
    sheet.paste(Image.open(os.path.join(out, "icon_192.png")).resize((48, 48), Image.LANCZOS), (1260, 16))
    # adaptive: composite with a circular launcher mask (72/108 visible region)
    bg = Image.open(os.path.join(out, "icon_bg_432.png")).convert("RGBA")
    bg.alpha_composite(Image.open(os.path.join(out, "icon_fg_432.png")))
    vis = bg.crop((72, 72, 360, 360))
    mask = Image.new("L", vis.size, 0)
    ImageDraw.Draw(mask).ellipse([0, 0, vis.size[0] - 1, vis.size[1] - 1], fill=255)
    circ = Image.new("RGB", vis.size, (70, 72, 78))
    circ.paste(vis, (0, 0), mask)
    sheet.paste(circ.resize((240, 240), Image.LANCZOS), (944, 260))
    fgonly = Image.open(os.path.join(out, "icon_fg_432.png")).resize((216, 216), Image.LANCZOS)
    chk2 = chk.resize((216, 216))
    sheet.paste(Image.alpha_composite(chk2, fgonly).convert("RGB"), (1184, 260))
    sheet.save(path)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "/root/work/assets/icon"
    build(out)
    if len(sys.argv) > 2:
        preview(out, sys.argv[2])
