"""App icon, title emblem and boot splash for LONE WOLF ARENA (original low-poly wolf over a crosshair).

Two drawings share the wolf geometry below:
- draw_emblem: the title emblem, an amber wolf inside an orange crosshair ring (logo lockup and
  emblem.png in tools/media/make_keyart.py, emblem_1024.png, the boot splash).
- draw_launcher: the launcher icon art, the wolf in white steel drawn to read at 48 px: a heavy
  gold sight ring with four outer posts behind the head, a charcoal keyline and a gap cut into the
  ring around the head, a thickness band under it (depth), a cool key rim light from the upper
  left and a warm back rim on the right, glowing amber eyes; on a clean ember gradient
  (launcher_background). draw_monochrome is its one-colour silhouette for Android 13 themed icons.
Drawn with Pillow/numpy at 4x and downsampled with Lanczos for anti-aliasing. Deterministic.
Writes into assets/icon/: icon_512 (store and project icon), icon_192 (legacy launcher), the
adaptive layers icon_bg_432 / icon_fg_432 and icon_mono_432 (white on transparent), emblem_1024;
the project icon (icon.png = icon_512) and assets/ui/boot_splash.png (+ .import): the title emblem
on project.godot's boot_splash/bg_color, drawn 1:1 (boot splash fullsize=false, stretch disabled).
Adaptive layers are 432 px = 108 dp; launchers mask them to the inner 72 dp and only the central
66 dp circle (61 % of the canvas) is safe from every mask shape, so the fg and mono art stay in it.
Usage: python3 make_icon.py [out_dir] [preview.png]   (a custom out_dir also receives the splash)
"""
from __future__ import annotations

import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy import ndimage

SS = 4
CHARCOAL = (18, 19, 23)
PALETTES = {
    # facet gradient top / bottom, crosshair ring colour (top, bottom), inner ear, eye, glint
    "amber": {"top": (255, 214, 84), "bottom": (232, 74, 22), "ring": ((255, 150, 60), (200, 70, 20)),
              "ear": (150, 46, 16), "eye": CHARCOAL, "glint": (255, 236, 170), "seam": (110, 36, 8)},
    "steel": {"top": (255, 255, 255), "bottom": (172, 182, 198), "ring": ((40, 40, 48), (16, 16, 20)),
              "ear": (226, 98, 34), "eye": (255, 176, 20), "glint": (255, 250, 220), "seam": (80, 88, 104)},
}
TOP = np.array(PALETTES["amber"]["top"], float)
BOTTOM = np.array(PALETTES["amber"]["bottom"], float)

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


def shrink(pts, k):
    cx = sum(p[0] for p in pts) / len(pts)
    cy = sum(p[1] for p in pts) / len(pts)
    return [(cx + (x - cx) * k, cy + (y - cy) * k) for x, y in pts]


def grad_color(y, shade, pal=None):
    pal = pal or PALETTES["amber"]
    t = np.clip((y - 0.03) / 0.92, 0, 1)
    c = np.array(pal["top"], float) * (1 - t) + np.array(pal["bottom"], float) * t
    return tuple(int(v) for v in np.clip(c * shade, 0, 255))


# ---------------------------------------------------------------- drawing
def draw_emblem(size, outline=True, crosshair=True, palette="amber"):
    """Return an RGBA emblem of `size` px (drawn at 4x).  The artwork spans the
    central circle of radius 0.48*size."""
    pal = PALETTES[palette]
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
        layer[key] = (*CHARCOAL, 255) if palette == "amber" else (255, 236, 200, 255)
        rr = np.asarray(ring).astype(float) / 255
        yy = np.linspace(0, 1, S)[:, None, None]
        r_top = np.array(pal["ring"][0], float)
        r_bot = np.array(pal["ring"][1], float)
        col = r_top * (1 - yy) + r_bot * yy
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
    d.polygon(tp(sil), fill=grad_color(0.5, 0.85, pal))
    for side in (0, 1):
        for pts_k, shade in FACETS:
            pts = [P[k] for k in pts_k]
            if side:
                pts = mirror(pts)
                shade *= 0.9
            yc = np.mean([p[1] for p in pts])
            d.polygon(tp(pts), fill=grad_color(yc, shade, pal))
    # facet edge lines (subtle low-poly seams), composited so alpha is preserved
    seams = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(seams)
    for side in (0, 1):
        for pts_k, _ in FACETS:
            pts = [P[k] for k in pts_k]
            if side:
                pts = mirror(pts)
            q = tp(pts)
            sd.line(q + [q[0]], fill=(*pal["seam"], 255), width=max(1, int(0.0028 * S)))
    sil_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(sil_mask).polygon(tp(sil), fill=255)
    sa = np.asarray(seams).copy()
    sa[..., 3] = (sa[..., 3].astype(float) * 0.32 * (np.asarray(sil_mask) / 255.0)).astype(np.uint8)
    img = Image.alpha_composite(img, Image.fromarray(sa, "RGBA"))
    d = ImageDraw.Draw(img)
    for side in (0, 1):
        f = mirror if side else (lambda p: p)
        d.polygon(tp(f(INNER_EAR)), fill=pal["ear"])
        d.polygon(tp(f(EYE)), fill=pal["eye"] if palette == "amber" else CHARCOAL)
        if palette != "amber":
            # glowing eye: the slit filled with amber, a hot core
            d.polygon(tp(f(shrink(EYE, 0.78))), fill=pal["eye"])
        d.polygon(tp(f(GLINT)), fill=pal["glint"])
        d.line(tp(f(MOUTH)), fill=CHARCOAL, width=int(0.0075 * S), joint="curve")
    d.polygon(tp(BROW_MARK), fill=grad_color(0.33, 0.86, pal) if palette == "amber" else (232, 104, 36))
    d.polygon(tp(NOSE), fill=CHARCOAL)
    return img.resize((size, size), Image.LANCZOS)


def drop_shadow(img, offset, blur, alpha=150):
    a = img.getchannel("A").filter(ImageFilter.GaussianBlur(blur))
    sh = Image.new("RGBA", img.size, (40, 8, 0, 0))
    sh.putalpha(a.point(lambda x: x * alpha // 255))
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.alpha_composite(sh, offset)
    out.alpha_composite(img)
    return out


# ---------------------------------------------------------------- launcher icon
RING_GOLD = ((255, 224, 128), (206, 112, 22))   # sight ring gradient, top / bottom
RING_HI = (255, 250, 224)                       # bevel light on the ring's upper-left faces
DEPTH = (52, 58, 72)                            # the head's thickness band
HEAD_BOX = 0.84                                 # head box, fraction of the art size
RING_R, RING_W = 0.40, 0.05                     # ring radius and width (fraction of the art)
POSTS = (0.40, 0.485, 0.055)                    # outer sight posts: from radius, to radius, width
BG_STOPS = ((236, 116, 28), (124, 42, 16), (36, 14, 12))   # ember gradient: centre, middle, edge
SAFE_DP = 66.0 / 108.0                          # adaptive-icon safe circle (diameter / canvas)


def _poly(S, pts):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return np.asarray(m).astype(np.float32) / 255.0


def _soft(mask, sigma):
    return ndimage.gaussian_filter(mask.astype(np.float32), sigma)


def _over(dst, rgb, a):
    """Composites colour `rgb` (tuple or (S, S, 3) array) with coverage `a` over the float RGBA
    image `dst` (colour 0..255, alpha 0..1), in place."""
    a = np.clip(a, 0.0, 1.0)[..., None]
    rgb = np.broadcast_to(np.asarray(rgb, np.float32), dst[..., :3].shape)
    out_a = a + dst[..., 3:4] * (1.0 - a)
    dst[..., :3] = (rgb * a + dst[..., :3] * dst[..., 3:4] * (1.0 - a)) / np.maximum(out_a, 1e-6)
    dst[..., 3:4] = out_a
    return dst


def _launcher_shapes(S):
    """Masks of the launcher art at supersampled size S: the sight ring with its posts, the head,
    the head with its thickness band, and helpers for drawing the head."""
    cx = cy = S / 2
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32) + 0.5
    r = np.hypot(xx - cx, yy - cy)
    ring = np.clip((RING_W * S / 2 - np.abs(r - RING_R * S)) / SS + 0.5, 0, 1)
    posts = Image.new("L", (S, S), 0)
    pd = ImageDraw.Draw(posts)
    r_in, r_out, pw = POSTS[0] * S, POSTS[1] * S, POSTS[2] * S
    for ang in (0, 90, 180, 270):          # outside the ring only: the top post never reads as a cross
        ux, uy = np.cos(np.radians(ang)), np.sin(np.radians(ang))
        px, py = -uy, ux
        pd.polygon([(cx + ux * r_in + px * pw / 2, cy + uy * r_in + py * pw / 2),
                    (cx + ux * r_out + px * pw / 2, cy + uy * r_out + py * pw / 2),
                    (cx + ux * r_out - px * pw / 2, cy + uy * r_out - py * pw / 2),
                    (cx + ux * r_in - px * pw / 2, cy + uy * r_in - py * pw / 2)], fill=255)
    sight = np.maximum(ring, np.asarray(posts).astype(np.float32) / 255.0)
    box = HEAD_BOX * S
    ox, oy = cx - box / 2, cy - box / 2 + 0.016 * S

    def tp(pts, dy=0.0):
        return [(ox + x * box, oy + y * box + dy) for x, y in pts]

    sil_r = [P[k] for k in OUTLINE_R]
    sil = sil_r + mirror(sil_r[::-1])[1:-1]
    head = _poly(S, tp(sil))
    body = np.maximum(head, _poly(S, tp(sil, 0.03 * S)))
    return {"sight": sight, "head": head, "body": body, "tp": tp, "sil": sil, "yy": yy}


def _features(S, tp, pal):
    feat = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(feat)
    for side in (0, 1):
        f = mirror if side else (lambda p: p)
        d.polygon(tp(f(INNER_EAR)), fill=pal["ear"])
        d.polygon(tp(f(EYE)), fill=CHARCOAL)
        d.polygon(tp(f(shrink(EYE, 0.78))), fill=pal["eye"])
        d.polygon(tp(f(GLINT)), fill=pal["glint"])
        d.line(tp(f(MOUTH)), fill=CHARCOAL, width=int(0.0075 * S), joint="curve")
    d.polygon(tp(BROW_MARK), fill=(232, 104, 36))
    d.polygon(tp(NOSE), fill=CHARCOAL)
    return np.asarray(feat).astype(np.float32)


def draw_launcher(size):
    """The launcher art (RGBA, `size` px, drawn at 4x): spans the central circle of radius
    ~0.5*size (posts and their keyline)."""
    S = size * SS
    sh = _launcher_shapes(S)
    head, body, tp, yy = sh["head"], sh["body"], sh["tp"], sh["yy"]
    img = np.zeros((S, S, 4), np.float32)
    # ring: cut away around the head, metal gradient with a bevel light from the upper left
    out_dist = ndimage.distance_transform_edt(body < 0.5)
    gap = _soft(out_dist < 0.045 * S, SS * 0.4)
    sight = sh["sight"] * (1 - gap)
    t = (yy / S)[..., None]
    col = np.array(RING_GOLD[0], np.float32) * (1 - t) + np.array(RING_GOLD[1], np.float32) * t
    gy, gx = np.gradient(_soft(sh["sight"], SS * 1.2))
    lit = np.clip(0.6 * gx + 0.8 * gy, 0, None)
    lit /= lit.max() + 1e-6
    col = col + (np.array(RING_HI, np.float32) - col) * (0.9 * lit[..., None])
    s_dist = ndimage.distance_transform_edt(sight < 0.5)
    _over(img, CHARCOAL, _soft(s_dist < 0.014 * S, SS * 0.4) * (1 - gap))
    _over(img, col, sight)
    # head: keyline, thickness band, faceted steel face
    _over(img, CHARCOAL, _soft(out_dist < 0.026 * S, SS * 0.4))
    _over(img, DEPTH, body)
    pal = PALETTES["steel"]
    face = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(face)
    d.polygon(tp(sh["sil"]), fill=grad_color(0.5, 0.85, pal))
    for side in (0, 1):
        for pts_k, shade in FACETS:
            pts = [P[k] for k in pts_k]
            if side:
                pts = mirror(pts)
                shade *= 0.86
            d.polygon(tp(pts), fill=grad_color(np.mean([p[1] for p in pts]), shade, pal))
    fa = np.asarray(face).astype(np.float32)
    _over(img, fa[..., :3], fa[..., 3] / 255.0 * head)
    seams = Image.new("L", (S, S), 0)
    sd = ImageDraw.Draw(seams)
    for side in (0, 1):
        for pts_k, _ in FACETS:
            q = tp([P[k] for k in pts_k] if not side else mirror([P[k] for k in pts_k]))
            sd.line(q + [q[0]], fill=255, width=max(1, int(0.003 * S)))
    _over(img, pal["seam"], np.asarray(seams).astype(np.float32) / 255.0 * head * 0.28)
    # rim lights in a thin band inside the silhouette: cool key from the upper left, warm back
    # light (the ember background) from the right
    band = np.exp(-(ndimage.distance_transform_edt(head > 0.5) / (0.012 * S)) ** 2) * head
    gy, gx = np.gradient(_soft(head, SS * 2.0))
    n = np.hypot(gx, gy) + 1e-6
    nx, ny = -gx / n, -gy / n
    _over(img, (255, 255, 255), band * np.clip(-0.55 * nx - 0.83 * ny, 0, 1) ** 1.2 * 0.85)
    _over(img, (255, 170, 60), band * np.clip(0.8 * nx + 0.2 * ny, 0, 1) ** 1.5 * 0.75)
    fe = _features(S, tp, pal)
    _over(img, fe[..., :3], fe[..., 3] / 255.0)
    # glowing eyes (additive)
    eyes = np.maximum(_poly(S, tp(shrink(EYE, 0.78))), _poly(S, tp(mirror(shrink(EYE, 0.78)))))
    glow = _soft(eyes, 0.02 * S)
    glow /= glow.max() + 1e-6
    img[..., :3] = np.minimum(img[..., :3] + glow[..., None] * np.array([140, 82, 16], np.float32) * img[..., 3:4], 255)
    img[..., 3] *= 255.0
    out = Image.fromarray(np.clip(img + 0.5, 0, 255).astype(np.uint8), "RGBA")
    return out.resize((size, size), Image.LANCZOS)


def draw_monochrome(size):
    """Android 13 themed-icon glyph (`size` px): the launcher art as one white silhouette on
    transparency (the launcher tints it) - sight ring and posts, the head with its ears, eyes,
    brow mark, nose and mouth cut out, a transparent gap between head and ring."""
    S = size * SS
    sh = _launcher_shapes(S)
    head, tp = sh["head"], sh["tp"]
    gap = _soft(ndimage.distance_transform_edt(head < 0.5) < 0.04 * S, SS * 0.4)
    a = np.maximum(sh["sight"] * (1 - gap), head)
    cut = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(cut)
    for side in (0, 1):
        f = mirror if side else (lambda p: p)
        d.polygon(tp(f(INNER_EAR)), fill=255)
        d.polygon(tp(f(EYE)), fill=255)
        d.line(tp(f(MOUTH)), fill=255, width=int(0.0075 * S), joint="curve")
    d.polygon(tp(BROW_MARK), fill=255)
    d.polygon(tp(NOSE), fill=255)
    a = a * (1 - np.asarray(cut).astype(np.float32) / 255.0)
    out = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    out.putalpha(Image.fromarray(np.clip(a * 255 + 0.5, 0, 255).astype(np.uint8), "L"))
    return out.resize((size, size), Image.LANCZOS)


def launcher_background(size, seed=11):
    """Clean ember gradient: a warm glow behind the head (centre a little above the middle)
    falling off through burnt orange to a deep brown edge, a faint sheen from the upper left and
    a 1/2-LSB dither against banding. No rays or streaks: the art carries the detail."""
    S = size
    yy, xx = np.mgrid[0:S, 0:S].astype(float) + 0.5
    u, v = xx / S, yy / S
    r = np.hypot(u - 0.5, (v - 0.44) * 1.04)
    t = np.clip(r / 0.72, 0, 1)
    t = t * t * (3 - 2 * t)
    c0, c1, c2 = (np.array(c, float) for c in BG_STOPS)
    k = t[..., None]
    col = np.where(k < 0.5, c0 + (c1 - c0) * (k / 0.5), c1 + (c2 - c1) * ((k - 0.5) / 0.5))
    col += np.exp(-((u + v - 0.45) / 0.22) ** 2)[..., None] * np.array([255, 190, 120]) * 0.07
    col += np.random.default_rng(seed).uniform(-0.5, 0.5, (S, S, 1))
    return Image.fromarray(np.clip(col + 0.5, 0, 255).astype(np.uint8), "RGB")


# ---------------------------------------------------------------- boot splash
def boot_color():
    """project.godot's application/boot_splash/bg_color as 8-bit RGB (rounded like the GL clear)."""
    import re
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "project.godot")
    m = re.search(r"^boot_splash/bg_color=Color\(([^)]*)\)", open(path).read(), re.M)
    vals = [float(v) for v in m.group(1).split(",")[:3]] if m else [0.05, 0.05, 0.07]
    return tuple(int(round(v * 255)) for v in vals)


def boot_splash(size=512, emblem=352):
    """The title emblem centred on the boot colour with a soft warm glow behind it. The engine
    draws it 1:1 in screen pixels (fullsize=false): the emblem is ~1/3 of a 1080 px tall screen.
    The outer margin is exactly the boot colour, so the image edge never shows."""
    bg = np.array(boot_color(), float)
    yy, xx = np.mgrid[0:size, 0:size].astype(float) + 0.5
    r = np.hypot(xx - size / 2, yy - size / 2) / (size / 2)
    edge = np.clip((r - 0.92) / (0.55 - 0.92), 0, 1)        # 1 inside r = 0.55, 0 beyond 0.92
    w = edge * edge * (3 - 2 * edge) * np.exp(-(r / 0.6) ** 2)
    col = bg + w[..., None] * (np.array([150, 62, 14]) - bg) * 0.42
    col += np.random.default_rng(5).uniform(-0.5, 0.5, (size, size, 1)) * (w[..., None] > 0.004)
    img = Image.fromarray(np.clip(col + 0.5, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    em = draw_emblem(emblem)
    img.alpha_composite(em, ((size - emblem) // 2, (size - emblem) // 2))
    return img.convert("RGB")


SPLASH_IMPORT = """[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="res://assets/ui/boot_splash.png"

[params]

compress/mode=0
compress/lossy_quality=0.86
mipmaps/generate=false
detect_3d/compress_to=0
"""


# ---------------------------------------------------------------- outputs
def build(out):
    os.makedirs(out, exist_ok=True)
    emblem = draw_emblem(1024)
    emblem.save(os.path.join(out, "emblem_1024.png"), optimize=True)
    for size in (512, 192):
        bg = launcher_background(size).convert("RGBA")
        art = int(round(size * 0.9))
        e = draw_launcher(max(art, 432)).resize((art, art), Image.LANCZOS)
        e = drop_shadow(e, (0, max(2, size // 70)), max(2, size // 40))
        off = (size - art) // 2
        bg.alpha_composite(e, (off, off))
        bg.convert("RGB").save(os.path.join(out, f"icon_{size}.png"), optimize=True)
    # adaptive icon layers (432 px = 108 dp at xxxhdpi); the art fits the 66 dp safe circle
    S = 432
    launcher_background(S).save(os.path.join(out, "icon_bg_432.png"), optimize=True)
    art = 258
    fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    fg.alpha_composite(drop_shadow(draw_launcher(art), (0, 3), 4), ((S - art) // 2, (S - art) // 2))
    fg.save(os.path.join(out, "icon_fg_432.png"), optimize=True)
    mono = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    mart = 240                   # a little smaller than the colour art, like other themed glyphs
    mono.alpha_composite(draw_monochrome(mart), ((S - mart) // 2, (S - mart) // 2))
    mono.save(os.path.join(out, "icon_mono_432.png"), optimize=True)
    for name, layer in (("fg", fg), ("mono", mono)):
        a = np.asarray(layer)[..., 3]
        ys, xs = np.nonzero(a > 8)
        rr = np.hypot(xs - S / 2 + 0.5, ys - S / 2 + 0.5).max()
        print(f"{name} artwork max radius {rr:.1f}px = {2 * rr / S * 100:.1f}% of the canvas "
              f"(safe circle 66 dp = {SAFE_DP * 100:.1f}%)")
        if 2 * rr / S > SAFE_DP:
            raise SystemExit(f"icon_{name}_432 leaves the adaptive-icon safe circle")


def preview(out, splash, path):
    """Contact sheet: launcher icon at 512/192/96/64/48 px, the adaptive layers under a circle
    and a squircle mask at 48-144 px on light and dark wallpapers, the themed (monochrome) icon
    tinted both ways, the boot splash and the title emblem."""
    sheet = Image.new("RGB", (1400, 900), (70, 72, 78))
    d = ImageDraw.Draw(sheet)
    icon = Image.open(os.path.join(out, "icon_512.png"))
    sheet.paste(icon.resize((384, 384), Image.LANCZOS), (16, 16))
    x = 416
    for s in (192, 96, 64, 48):
        sheet.paste(icon.resize((s, s), Image.LANCZOS), (x, 16))
        x += s + 16
    sheet.paste(icon.resize((48, 48), Image.LANCZOS).resize((192, 192), Image.NEAREST), (416, 224))
    bg = Image.open(os.path.join(out, "icon_bg_432.png")).convert("RGBA")
    bg.alpha_composite(Image.open(os.path.join(out, "icon_fg_432.png")))
    vis = bg.crop((72, 72, 360, 360))
    mono = Image.open(os.path.join(out, "icon_mono_432.png")).crop((72, 72, 360, 360))

    def masked(im, s, squircle):
        big = Image.new("L", (s * 4, s * 4), 0)
        md = ImageDraw.Draw(big)
        if squircle:
            md.rounded_rectangle([0, 0, s * 4 - 1, s * 4 - 1], radius=int(s * 4 * 0.3), fill=255)
        else:
            md.ellipse([0, 0, s * 4 - 1, s * 4 - 1], fill=255)
        o = im.resize((s, s), Image.LANCZOS)
        o.putalpha(Image.composite(o.getchannel("A"), Image.new("L", (s, s), 0), big.resize((s, s), Image.LANCZOS)))
        return o

    def themed(s, dark):
        base = Image.new("RGBA", (288, 288), (40, 44, 36, 255) if dark else (220, 230, 200, 255))
        tint = Image.new("RGBA", (288, 288), (200, 230, 160, 255) if dark else (44, 70, 30, 255))
        base.paste(tint, (0, 0), mono.getchannel("A"))
        return masked(base, s, False)

    for row, wall in enumerate(((228, 232, 238), (12, 12, 16))):
        y0 = 432 + row * 230
        d.rectangle([16, y0, 1384, y0 + 214], fill=wall)
        x = 32
        for s in (144, 96, 64, 48):
            m = masked(vis, s, False)
            sheet.paste(m, (x, y0 + 16), m)
            x += s + 18
        for s in (96, 48):
            m = masked(vis, s, True)
            sheet.paste(m, (x, y0 + 16), m)
            x += s + 18
        for s in (144, 64, 48):
            m = themed(s, row == 1)
            sheet.paste(m, (x, y0 + 16), m)
            x += s + 18
    sp = Image.open(splash)
    sheet.paste(sp.resize((256, 256), Image.LANCZOS), (640, 160))
    d.text((640, 420), "boot_splash.png (1:1 would be 512 px)", fill=(230, 230, 230))
    em = Image.open(os.path.join(out, "emblem_1024.png")).resize((256, 256), Image.LANCZOS)
    chk = Image.new("RGBA", (256, 256), (150, 150, 158, 255))
    chk.alpha_composite(em)
    sheet.paste(chk.convert("RGB"), (920, 160))
    d.text((920, 420), "title emblem (emblem_1024.png)", fill=(230, 230, 230))
    sheet.save(path)


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.normpath(os.path.join(here, "..", ".."))
    default_out = os.path.join(root, "assets", "icon")
    out = sys.argv[1] if len(sys.argv) > 1 else default_out
    build(out)
    in_project = os.path.abspath(out) == os.path.abspath(default_out)
    splash = os.path.join(root, "assets", "ui", "boot_splash.png") if in_project else os.path.join(out, "boot_splash.png")
    boot_splash().save(splash, optimize=True)
    if in_project:
        # the project icon (project.godot config/icon) is the 512 px launcher icon
        Image.open(os.path.join(out, "icon_512.png")).save(os.path.join(root, "icon.png"), optimize=True)
        if not os.path.exists(splash + ".import"):
            open(splash + ".import", "w").write(SPLASH_IMPORT)   # Godot fills in the rest on import
    if len(sys.argv) > 2:
        preview(out, splash, sys.argv[2])
