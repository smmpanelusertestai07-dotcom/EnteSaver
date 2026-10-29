"""Key art, logo lockup, mode card and wardrobe portraits for LONE WOLF ARENA (all original).

1. renders the 3D shots with Blender (tools/media/render_keyart.py): the hero key art and one
   portrait per outfit bundle (assets/character/manifest.json);
2. grades the key art (contrast, saturation, warm/cool split, vignette), adds light streaks and
   embers, and draws the logo lockup: the wolf emblem of tools/media/make_icon.py next to a heavy
   italic "LONE WOLF" (gradient fill, dark outline, shadow) over a slanted yellow "ARENA" plate;
3. writes into assets/ui/:
     keyart.jpg          1920x1080 key art with the logo (store / marketing image)
     keyart_clean.jpg    the same without the logo: the loading screen's full-bleed background
     logo.png            the logo lockup on transparency (loading screen, lobby)
     emblem.png          the wolf emblem alone, 256 px (results medal, player avatar)
     mode_lonewolf.jpg   the mode art: the face-off render (two fighters squaring up inside the
                         Cargo Cage hall), graded with a blue / orange duel split (lobby mode
                         card, featured card, match loading card)
     bundle_<id>.png     the outfit portraits (wardrobe item cards)
     lobby_skyline.png   the lobby's painted horizon card (cranes, warehouses, city lights) on
                         transparency, 2048x384
   plus their Godot .import settings (lossy WebP for the photos, mipmaps for downscaled art).

usage: python3 tools/media/make_keyart.py [--work DIR] [--skip-render] [--quick] [--out DIR]
                                          [--only keyart,logo,emblem,mode,portraits,skyline]
  --work DIR     where the raw renders go (default: a fresh temporary folder)
  --skip-render  reuse the renders already in --work
  --quick        low resolution / samples (layout checks only)
  --only LIST    write only these outputs (and render only what they need)
Needs Blender on PATH (blender), Pillow, numpy and scipy."""
from __future__ import annotations

import json
import math
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont
from scipy import ndimage

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
from make_icon import draw_emblem  # noqa: E402  (the same wolf emblem as the app icon)

ARGS = sys.argv[1:]


def arg(name, default=None):
    return ARGS[ARGS.index(name) + 1] if name in ARGS else default


QUICK = "--quick" in ARGS
ONLY = set((arg("--only") or "keyart,logo,emblem,mode,portraits,skyline").split(","))
WORK = arg("--work") or tempfile.mkdtemp(prefix="lw_keyart_")
OUT = arg("--out", os.path.join(ROOT, "assets", "ui"))
FONTS = os.path.join(ROOT, "assets", "fonts")
MANIFEST = json.load(open(os.path.join(ROOT, "assets", "character", "manifest.json")))
BUNDLES = [b["id"] for b in MANIFEST["bundles"]]
W, H = (960, 540) if QUICK else (1920, 1080)
YELLOW = (255, 196, 22)
CHARCOAL = (16, 16, 20)


# ---------------------------------------------------------------- renders
def render(scene, out, *extra):
    cmd = ["blender", "-b", "--python", os.path.join(HERE, "render_keyart.py"), "--", "--scene", scene,
           "--out", out, *extra]
    print("render:", scene, os.path.basename(out), flush=True)
    r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if r.returncode != 0 or not os.path.exists(out):
        print(r.stdout[-3000:])
        raise SystemExit("render failed: " + out)


def render_all():
    os.makedirs(WORK, exist_ok=True)
    if "keyart" in ONLY:
        render("hero", os.path.join(WORK, "hero.png"), "--res", "%dx%d" % (W, H), "--samples", "12" if QUICK else "64")
    if "mode" in ONLY:
        render("faceoff", os.path.join(WORK, "faceoff.png"), "--res", "640x360" if QUICK else "1280x720",
               "--samples", "12" if QUICK else "48")
    if "portraits" in ONLY:
        for b in BUNDLES:
            render("portrait", os.path.join(WORK, "portrait_%s.png" % b), "--bundle", b,
                   "--samples", "12" if QUICK else "48")


# ---------------------------------------------------------------- grading and effects
def grade(img: Image.Image) -> Image.Image:
    a = np.asarray(img.convert("RGB")).astype(np.float32) / 255.0
    h, w = a.shape[:2]
    # gentle S-curve
    a = np.clip(a, 0, 1)
    a = a + 0.22 * (a - 0.5) * (1 - np.abs(2 * a - 1)) * 1.6
    # saturation boost around the luminance
    lum = (a @ np.array([0.2126, 0.7152, 0.0722], np.float32))[..., None]
    a = lum + (a - lum) * 1.18
    # split toning: cool shadows, warm highlights
    a += (1 - lum) * np.array([-0.012, 0.0, 0.03], np.float32) * 1.4
    a += lum * np.array([0.03, 0.012, -0.02], np.float32)
    # vignette (stronger at the bottom corners)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    nx = (xx / w - 0.5) * 2.0
    ny = (yy / h - 0.46) * 2.0
    r = np.sqrt(nx * nx * 0.75 + ny * ny)
    v = np.clip(1.0 - 0.32 * np.clip(r - 0.55, 0, None) ** 1.5, 0.45, 1.0)
    a *= v[..., None]
    return Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")


def streaks(img: Image.Image, seed=7) -> Image.Image:
    """Slanted light streaks (speed / energy shards) along the right edge and the bottom-left,
    plus a few glowing embers drifting through the frame. Additive, then softly blurred."""
    w, h = img.size
    rng = np.random.default_rng(seed)
    layer = Image.new("RGB", (w, h), (0, 0, 0))
    d = ImageDraw.Draw(layer)
    ang = math.radians(-24)
    ux, uy = math.cos(ang), math.sin(ang)
    px, py = -uy, ux

    def shard(cx, cy, length, width, col):
        pts = [(cx - ux * length / 2, cy - uy * length / 2),
               (cx + ux * length / 2 + px * width * 0.15, cy + uy * length / 2 + py * width * 0.15),
               (cx + ux * length / 2 + px * width, cy + uy * length / 2 + py * width),
               (cx - ux * length / 2 + px * width * 0.85, cy - uy * length / 2 + py * width * 0.85)]
        d.polygon(pts, fill=col)

    s = w / 1920.0
    for i in range(9):
        cx = w * rng.uniform(0.80, 1.02)
        cy = h * rng.uniform(0.52, 0.98)
        shard(cx, cy, rng.uniform(140, 380) * s, rng.uniform(5, 16) * s,
              (int(255 * rng.uniform(0.75, 1.0)), int(120 * rng.uniform(0.6, 1.0)), 20))
    for i in range(6):
        cx = w * rng.uniform(-0.02, 0.18)
        cy = h * rng.uniform(0.70, 1.02)
        shard(cx, cy, rng.uniform(120, 300) * s, rng.uniform(4, 12) * s, (255, int(150 * rng.uniform(0.6, 1)), 30))
    layer = layer.filter(ImageFilter.GaussianBlur(1.2 * s))
    glow = layer.filter(ImageFilter.GaussianBlur(10 * s))
    out = ImageChops.add(img, layer.point(lambda v: int(v * 0.55)))
    out = ImageChops.add(out, glow.point(lambda v: int(v * 0.7)))
    # embers
    emb = Image.new("RGB", (w, h), (0, 0, 0))
    de = ImageDraw.Draw(emb)
    for i in range(70):
        x = w * rng.uniform(0.35, 1.0)
        y = h * rng.uniform(0.05, 0.85)
        r = rng.uniform(1.0, 3.2) * s
        c = rng.uniform(0.5, 1.0)
        de.ellipse([x - r, y - r, x + r, y + r], fill=(int(255 * c), int(170 * c), int(70 * c)))
    emb_glow = emb.filter(ImageFilter.GaussianBlur(4 * s))
    out = ImageChops.add(out, emb.filter(ImageFilter.GaussianBlur(0.6 * s)))
    out = ImageChops.add(out, emb_glow)
    return out


def sun_flare(img: Image.Image, x, y) -> Image.Image:
    """A thin horizontal anamorphic streak and a soft bloom where the sun sits."""
    w, h = img.size
    s = w / 1920.0
    layer = Image.new("RGB", (w, h), (0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.ellipse([x - 26 * s, y - 26 * s, x + 26 * s, y + 26 * s], fill=(255, 210, 150))
    layer = layer.filter(ImageFilter.GaussianBlur(40 * s))
    line = Image.new("RGB", (w, h), (0, 0, 0))
    dl = ImageDraw.Draw(line)
    dl.rectangle([x - 300 * s, y - 1.5 * s, x + 420 * s, y + 1.5 * s], fill=(255, 170, 90))
    line = line.filter(ImageFilter.GaussianBlur(3 * s))
    out = ImageChops.add(img, layer.point(lambda v: int(v * 0.8)))
    return ImageChops.add(out, line.point(lambda v: int(v * 0.6)))


# ---------------------------------------------------------------- logo lockup
def text_mask(text, font_path, size, tracking=0.0):
    """White-on-black L mask of `text`, tight bbox, with letter spacing (fraction of size)."""
    font = ImageFont.truetype(font_path, size)
    widths = [font.getlength(ch) for ch in text]
    total = int(sum(widths) + tracking * size * (len(text) - 1)) + size
    m = Image.new("L", (total, int(size * 1.6)), 0)
    d = ImageDraw.Draw(m)
    x = size * 0.5
    for ch, cw in zip(text, widths):
        d.text((x, size * 0.2), ch, font=font, fill=255)
        x += cw + tracking * size
    return m.crop(m.getbbox())


def shear(m: Image.Image, slant=0.2):
    """Italic: shift rows right toward the top (x' = x + slant * (h - y))."""
    w, h = m.size
    extra = int(abs(slant) * h) + 2
    return m.transform((w + extra, h), Image.AFFINE, (1, slant, -slant * h, 0, 1, 0), Image.BICUBIC)


def dilate(m: Image.Image, r):
    a = np.asarray(m) > 127
    dist = ndimage.distance_transform_edt(~a)
    return Image.fromarray(((dist <= r) * 255).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(0.8))


def pad(m: Image.Image, p):
    out = Image.new(m.mode, (m.size[0] + 2 * p, m.size[1] + 2 * p), 0)
    out.paste(m, (p, p))
    return out


def gradient_fill(size, top, bottom, mid=None):
    w, h = size
    t = np.linspace(0, 1, h, dtype=np.float32)[:, None]
    top = np.array(top, np.float32)
    bottom = np.array(bottom, np.float32)
    if mid is not None:
        mid = np.array(mid, np.float32)
        c = np.where(t[..., None] < 0.55, top + (mid - top) * (t[..., None] / 0.55),
                     mid + (bottom - mid) * ((t[..., None] - 0.55) / 0.45))
    else:
        c = top + (bottom - top) * t[..., None]
    c = np.broadcast_to(c, (h, w, 3))
    return Image.fromarray(c.astype(np.uint8), "RGB")


def logo(height=420) -> Image.Image:
    """The lockup at `height` px: emblem | LONE WOLF / [ARENA plate]."""
    s = height / 420.0
    title = os.path.join(FONTS, "title.ttf")
    bold = os.path.join(FONTS, "ui_bold.ttf")
    # LONE WOLF: heavy italic with a white -> gold gradient, a charcoal outline and a shadow.
    m = text_mask("LONE WOLF", title, int(250 * s), 0.02)
    m = pad(m, int(30 * s))
    m = dilate(m, 3.5 * s)                              # embolden
    m = shear(m, 0.21)
    outline = dilate(m, 11 * s)
    fill = gradient_fill(m.size, (255, 255, 255), (255, 176, 40), mid=(255, 232, 160))
    word = Image.new("RGBA", m.size, (0, 0, 0, 0))
    shadow = Image.new("RGBA", m.size, (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", m.size, (0, 0, 0, 150)), (int(8 * s), int(10 * s)), outline)
    shadow = shadow.filter(ImageFilter.GaussianBlur(6 * s))
    word.alpha_composite(shadow)
    word.paste(Image.new("RGBA", m.size, (*CHARCOAL, 255)), (0, 0), outline)
    word.paste(fill.convert("RGBA"), (0, 0), m)
    # a thin highlight line through the upper third of the letters
    hl = Image.new("L", m.size, 0)
    ImageDraw.Draw(hl).rectangle([0, int(m.size[1] * 0.30), m.size[0], int(m.size[1] * 0.33)], fill=110)
    hl = ImageChops.multiply(hl, m)
    word.paste(Image.new("RGBA", m.size, (255, 255, 255, 255)), (0, 0), hl)
    word = word.crop(word.getbbox())
    # ARENA: black letters on a slanted yellow plate with a hazard-stripe tail.
    am = text_mask("ARENA", bold, int(92 * s), 0.42)
    am = shear(pad(am, 2), 0.21)
    pw, ph = am.size[0] + int(110 * s), am.size[1] + int(30 * s)
    plate = Image.new("RGBA", (pw + int(150 * s), ph + int(16 * s)), (0, 0, 0, 0))
    dp = ImageDraw.Draw(plate)
    sl = int(ph * 0.42)
    poly = [(sl, 0), (pw, 0), (pw - sl, ph), (0, ph)]
    shadow_poly = [(x + 6 * s, y + 8 * s) for x, y in poly]
    dp.polygon(shadow_poly, fill=(0, 0, 0, 110))
    plate = plate.filter(ImageFilter.GaussianBlur(4 * s))
    dp = ImageDraw.Draw(plate)
    dp.polygon(poly, fill=(*CHARCOAL, 255))
    inset = 5 * s
    dp.polygon([(sl + inset, inset), (pw - inset, inset), (pw - sl - inset * 0.6, ph - inset), (inset * 1.6, ph - inset)],
               fill=(*YELLOW, 255))
    # hazard tail: three slanted bars after the plate
    for i in range(3):
        x0 = pw + int((18 + i * 40) * s)
        dp.polygon([(x0 + sl, 0), (x0 + sl + 20 * s, 0), (x0 + 20 * s, ph), (x0, ph)],
                   fill=(*YELLOW, 255) if i % 2 == 0 else (255, 255, 255, 200))
    plate.paste(Image.new("RGBA", am.size, (*CHARCOAL, 255)), (int(55 * s), int(15 * s)), am)
    # emblem
    em_size = int(height * 0.98)
    em = draw_emblem(em_size)
    # assemble
    gap = int(18 * s)
    tw = max(word.size[0], plate.size[0] + int(40 * s))
    total_w = em_size + gap + tw
    out = Image.new("RGBA", (total_w, height), (0, 0, 0, 0))
    out.alpha_composite(em, (0, (height - em_size) // 2))
    wy = int(height * 0.04)
    out.alpha_composite(word, (em_size + gap, wy))
    py = wy + word.size[1] - int(22 * s)
    out.alpha_composite(plate, (em_size + gap + int(40 * s), min(py, height - plate.size[1])))
    return out.crop(out.getbbox())


# ---------------------------------------------------------------- mode art (face-off)
def mode_art(img: Image.Image) -> Image.Image:
    """The face-off render as mode art: contrast and saturation, the duel's colour split (blue
    on the left fighter's side, orange on the right one's), bloom on the windows and tubes and a
    vignette. 640x360."""
    img = img.convert("RGB").resize((1280, 720), Image.LANCZOS)
    a = np.asarray(img).astype(np.float32) / 255.0
    h, w = a.shape[:2]
    a = np.clip(a, 0, 1)
    a = a + 0.26 * (a - 0.5) * (1 - np.abs(2 * a - 1)) * 1.6
    lum = (a @ np.array([0.2126, 0.7152, 0.0722], np.float32))[..., None]
    a = lum + (a - lum) * 1.22
    xx = np.linspace(0, 1, w, dtype=np.float32)[None, :, None]
    blue = np.array([0.10, 0.45, 1.0], np.float32)
    orange = np.array([1.0, 0.42, 0.10], np.float32)
    k_l = np.clip(1.0 - xx / 0.5, 0, 1) ** 1.4
    k_r = np.clip((xx - 0.5) / 0.5, 0, 1) ** 1.4
    # soft-light style tint: stronger in the mid tones
    mid = 4.0 * lum * (1 - lum)
    a = a + (blue - a) * k_l * 0.22 * (0.4 + mid) + (orange - a) * k_r * 0.22 * (0.4 + mid)
    # bloom from the luminance only (windows, tubes), added as a warm white
    lum2 = (np.clip(a, 0, 1) @ np.array([0.2126, 0.7152, 0.0722], np.float32))
    yy, xg = np.mgrid[0:h, 0:w].astype(np.float32)
    hot = np.clip((lum2 - 0.82) / 0.18, 0, 1) * (yy < h * 0.45)
    glow = np.asarray(Image.fromarray((hot * 255).astype(np.uint8), "L").filter(ImageFilter.GaussianBlur(16))).astype(np.float32) / 255.0
    a = a + glow[..., None] * np.array([0.55, 0.5, 0.42], np.float32)
    # vignette, heavier along the bottom (the bright floor)
    r = np.sqrt(((xg / w - 0.5) * 2) ** 2 * 0.6 + ((yy / h - 0.45) * 2) ** 2)
    v = np.clip(1.0 - 0.36 * np.clip(r - 0.45, 0, None) ** 1.3, 0.45, 1.0)
    v *= 1.0 - 0.3 * np.clip((yy / h - 0.72) / 0.28, 0, 1) ** 1.5
    a *= v[..., None]
    out = Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
    return out.resize((640, 360), Image.LANCZOS)


# ---------------------------------------------------------------- lobby skyline card
def skyline(w=2048, h=384, seed=5) -> Image.Image:
    """The lobby's horizon card, RGBA with a transparent sky (the lobby's procedural sunset
    shows through): a low hazy far city, port gantry cranes on the sun side, warehouses with lit
    windows, a water tower, light poles and container stacks, all backlit (dark violet
    silhouettes, a warm rim on the right, warm and cool windows, red aviation lights).
    Mapping used by scripts/lobby.gd: 280 m wide, ground line at 92 % of the height, the lobby's
    x = 0 m at 126 m from the left edge. Painted at 2x and downsampled (smooth edges)."""
    S = 2
    W, H = w * S, h * S
    pxm = W / 280.0
    gy = H * 0.92
    rng = np.random.default_rng(seed)

    def X(m):
        return (m + 126.0) * pxm

    def Y(m):
        return gy - m * pxm

    haze = np.array([214, 132, 120], np.float32)

    def col(base, k, a=255):
        b = np.array(base, np.float32)
        c = b + (haze - b) * k
        return (int(c[0]), int(c[1]), int(c[2]), a)

    layers = []                 # [silhouettes, their lights], far to near
    reds = []
    dl = None

    def layer():
        nonlocal dl
        im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        lim = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        layers.append((im, lim))
        dl = ImageDraw.Draw(lim)
        return ImageDraw.Draw(im)

    def windows(x0, x1, y0, y1, k, density, size=(0.7, 0.5), step=(1.6, 1.5)):
        for wy in np.arange(y0, y1, step[1]):
            for wx in np.arange(x0, x1, step[0]):
                if rng.random() < density:
                    warm = rng.random() < 0.82
                    c = col((255, 196, 118) if warm else (168, 208, 255), k, int(rng.uniform(150, 245)))
                    dl.rectangle([X(wx), Y(wy + size[1]), X(wx + size[0]), Y(wy)], fill=c)

    # far city: low and hazy, taller clusters only toward the edges (never behind the hero)
    d = layer()
    x = -126.0
    while x < 154.0:
        bw = rng.uniform(3.0, 8.0)
        edge = x < -55.0 or x > 92.0
        bh = rng.uniform(12.0, 24.0) if edge and rng.random() < 0.5 else rng.uniform(3.5, 9.5)
        d.rectangle([X(x), Y(bh), X(x + bw), Y(-6)], fill=col((44, 28, 58), 0.58))
        windows(x + 0.6, x + bw - 0.7, 1.5, bh - 1.0, 0.5, 0.13, (0.5, 0.45), (1.3, 1.4))
        if bh > 19.0:
            d.rectangle([X(x + bw / 2 - 0.12), Y(bh + 3.5), X(x + bw / 2 + 0.12), Y(bh)], fill=col((44, 28, 58), 0.58))
            reds.append((x + bw / 2, bh + 3.5, 0.5, len(layers) - 1))
        x += bw + rng.uniform(0.0, 2.2)

    # port gantry cranes on the sun side (right), booms reaching left
    d = layer()
    cc = col((28, 18, 38), 0.32)
    lw = max(2, int(0.28 * pxm))
    for cx, s in ((46.0, 0.64), (82.0, 0.58), (112.0, 0.5)):
        top = 30.0 * s
        for lx in (cx - 9.0 * s, cx + 9.0 * s):
            d.polygon([(X(lx - 0.9 * s), Y(0)), (X(lx + 0.9 * s), Y(0)), (X(lx + 0.55 * s), Y(top)), (X(lx - 0.55 * s), Y(top))], fill=cc)
        for by in (7.0 * s, 19.0 * s):
            d.rectangle([X(cx - 9.0 * s), Y(by + 1.1 * s), X(cx + 9.0 * s), Y(by)], fill=cc)
        d.line([(X(cx - 9.0 * s), Y(7.0 * s)), (X(cx + 9.0 * s), Y(19.0 * s))], fill=cc, width=lw)
        b0, b1 = cx - 40.0 * s, cx + 17.0 * s
        bt = top + 2.6 * s
        d.rectangle([X(b0), Y(bt), X(b1), Y(top)], fill=cc)
        k = b0
        while k < b1 - 2.0:
            d.line([(X(k), Y(top)), (X(k + 1.6 * s), Y(bt))], fill=cc, width=lw)
            k += 3.2 * s
        ax = cx + 1.5 * s
        apex = top + 15.0 * s
        d.polygon([(X(cx - 7.5 * s), Y(bt)), (X(cx - 6.3 * s), Y(bt)), (X(ax + 0.35 * s), Y(apex)), (X(ax - 0.35 * s), Y(apex))], fill=cc)
        d.polygon([(X(cx + 6.3 * s), Y(bt)), (X(cx + 7.5 * s), Y(bt)), (X(ax + 0.35 * s), Y(apex)), (X(ax - 0.35 * s), Y(apex))], fill=cc)
        for end in (b0 + 3.0 * s, b0 + 16.0 * s, b1 - 1.0 * s):
            d.line([(X(ax), Y(apex)), (X(end), Y(bt))], fill=cc, width=max(1, lw // 2))
        d.rectangle([X(cx - 3.5 * s), Y(bt + 4.5 * s), X(cx + 5.5 * s), Y(bt)], fill=cc)
        d.rectangle([X(b0 + 8.0 * s), Y(top), X(b0 + 11.0 * s), Y(top - 2.5 * s)], fill=cc)       # spreader
        reds.append((ax, apex + 0.6, 0.25, len(layers) - 1))
        reds.append((b0 + 0.6, bt + 0.5, 0.25, len(layers) - 1))
        for fx in np.arange(b0 + 4.0 * s, b1, 9.0 * s):
            dl.ellipse([X(fx) - 3, Y(top - 0.2) - 2, X(fx) + 3, Y(top - 0.2) + 2], fill=(255, 226, 170, 235))

    # warehouses (sawtooth and flat roofs) with rows of lit windows, rooftop units, a water tower
    d = layer()
    wc = col((24, 16, 32), 0.2)
    for x0, x1, hh, saw in ((-126, -86, 9.0, True), (-80, -50, 12.0, False), (-44, -14, 7.0, True),
                            (-10, 26, 6.0, False), (30, 60, 10.0, False), (64, 100, 8.0, True), (104, 154, 9.0, False)):
        d.rectangle([X(x0), Y(hh), X(x1), Y(-6)], fill=wc)
        if saw:
            t = float(x0)
            while t < x1 - 1.0:
                d.polygon([(X(t), Y(hh)), (X(t + 4.0), Y(hh + 2.6)), (X(t + 4.0), Y(hh))], fill=wc)
                t += 4.0
        else:
            d.rectangle([X(x0 + 2.0), Y(hh + 1.4), X(x0 + 5.0), Y(hh)], fill=wc)
            d.rectangle([X(x1 - 9.0), Y(hh + 2.2), X(x1 - 6.0), Y(hh)], fill=wc)
        windows(x0 + 1.0, x1 - 1.5, hh * 0.5, hh - 1.2, 0.12, 0.62, (1.6, 0.7), (2.4, 1.8))
        windows(x0 + 1.0, x1 - 1.5, 1.4, 2.4, 0.12, 0.3, (2.2, 0.9), (4.0, 2.0))
    tx = -62.0
    for lx in (tx - 2.2, tx + 2.2):
        d.line([(X(lx), Y(0)), (X(lx * 0.0 + tx + (lx - tx) * 0.6), Y(13.0))], fill=wc, width=lw)
    d.rectangle([X(tx - 3.2), Y(18.0), X(tx + 3.2), Y(13.0)], fill=wc)
    d.polygon([(X(tx - 3.2), Y(18.0)), (X(tx), Y(19.6)), (X(tx + 3.2), Y(18.0))], fill=wc)
    reds.append((tx, 19.9, 0.12, len(layers) - 1))
    # light poles with warm heads (the yard's own lights)
    for px in (-34.0, -4.0, 38.0, 70.0):
        d.rectangle([X(px - 0.14), Y(15.0), X(px + 0.14), Y(0)], fill=wc)
        d.rectangle([X(px - 1.1), Y(15.4), X(px + 1.1), Y(14.8)], fill=wc)
        for hx in (px - 0.7, px + 0.7):
            dl.ellipse([X(hx) - 4, Y(14.75) - 3, X(hx) + 4, Y(14.75) + 3], fill=(255, 232, 180, 245))

    # container stacks near the ground, dark paint colours
    d = layer()
    paints = [(46, 24, 26), (26, 30, 48), (24, 38, 44), (50, 32, 20), (38, 34, 42)]
    x = -126.0
    while x < 154.0:
        ln = 12.2 if rng.random() < 0.45 else 6.1
        n = int(rng.choice([0, 1, 1, 2, 2, 3, 4]))
        for k in range(n):
            pc = paints[int(rng.integers(len(paints)))]
            c = col(pc, 0.24)
            off = rng.uniform(-0.4, 0.4)
            d.rectangle([X(x + off), Y((k + 1) * 2.59), X(x + off + ln), Y(k * 2.59)], fill=c)
            d.line([(X(x + off), Y((k + 1) * 2.59)), (X(x + off + ln), Y((k + 1) * 2.59))], fill=col((80, 60, 72), 0.24), width=2)
            if rng.random() < 0.3:
                windows(x + off + 0.5, x + off + ln - 0.5, k * 2.59 + 1.0, k * 2.59 + 1.6, 0.1, 0.06, (0.6, 0.35), (2.0, 1.0))
        x += ln + rng.uniform(0.4, 6.0)

    for x_m, y_m, r, li in reds:
        rr = max(2.0, r * pxm)
        ImageDraw.Draw(layers[li][1]).ellipse([X(x_m) - rr, Y(y_m) - rr, X(x_m) + rr, Y(y_m) + rr], fill=(255, 64, 44, 255))
    out = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    rim_col = np.array([255, 150, 96], np.float32)
    for im, lim in layers:
        arr = np.asarray(im).astype(np.float32)
        a = arr[..., 3] / 255.0
        # warm rim on the sun side (right edges) and a faint one along the tops
        right = np.clip(a - np.roll(a, -int(1.2 * S), axis=1), 0, 1)
        topr = np.clip(a - np.roll(a, int(1.0 * S), axis=0), 0, 1)
        rim = np.clip(right * 0.75 + topr * 0.35, 0, 1)[..., None]
        arr[..., :3] = arr[..., :3] + (rim_col - arr[..., :3]) * rim * 0.7
        out.alpha_composite(Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGBA"))
        # this layer's lights with a soft glow, before the nearer layers cover them
        glow = lim.filter(ImageFilter.GaussianBlur(5 * S))
        ga = np.asarray(glow).astype(np.float32)
        ga[..., 3] *= 0.55
        out.alpha_composite(Image.fromarray(np.clip(ga, 0, 255).astype(np.uint8), "RGBA"))
        out.alpha_composite(lim)
    # solid below the ground line (hidden under the lobby floor anyway)
    ImageDraw.Draw(out).rectangle([0, int(gy) + 2, W, H], fill=col((26, 18, 30), 0.15))
    return out.resize((w, h), Image.LANCZOS)


# ---------------------------------------------------------------- outputs
def write_import(path, lossy=False, mipmaps=False):
    """Godot import settings next to an output (Godot fills in the rest on import). Kept when
    the file already exists and has the same parameters."""
    imp = path + ".import"
    want = {"compress/mode": "1" if lossy else "0", "compress/lossy_quality": "0.86",
            "mipmaps/generate": "true" if mipmaps else "false"}
    if os.path.exists(imp):
        text = open(imp).read()
        new = text
        import re
        for k, v in want.items():
            pat = re.compile(r"^%s=.*$" % re.escape(k), re.M)
            new = pat.sub("%s=%s" % (k, v), new) if pat.search(new) else new.replace("[params]\n", "[params]\n\n%s=%s\n" % (k, v), 1)
        if new != text:
            open(imp, "w").write(new)
        return
    res = "res://" + os.path.relpath(path, ROOT).replace(os.sep, "/")
    lines = ["[remap]", "", 'importer="texture"', 'type="CompressedTexture2D"', "", "[deps]", "",
             'source_file="%s"' % res, "", "[params]", ""]
    lines += ["%s=%s" % (k, v) for k, v in want.items()]
    lines += ["detect_3d/compress_to=0", ""]
    open(imp, "w").write("\n".join(lines))


def portraits():
    for b in BUNDLES:
        src = os.path.join(WORK, "portrait_%s.png" % b)
        if not os.path.exists(src):
            print("missing portrait", src)
            continue
        im = Image.open(src).convert("RGBA")
        bb = im.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
        im = im.crop(bb)
        cw, ch = 300, 400
        sc = min((ch * 0.97) / im.size[1], (cw * 0.96) / im.size[0])
        im = im.resize((max(1, int(im.size[0] * sc)), max(1, int(im.size[1] * sc))), Image.LANCZOS)
        canvas = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
        canvas.alpha_composite(im, ((cw - im.size[0]) // 2, ch - im.size[1] - 4))
        out = os.path.join(OUT, "bundle_%s.png" % b)
        canvas.save(out, optimize=True)
        write_import(out, lossy=False, mipmaps=True)
        print("wrote", out)


def main():
    if "--skip-render" not in ARGS:
        render_all()
    os.makedirs(OUT, exist_ok=True)
    lg = logo() if ONLY & {"keyart", "logo"} else None
    if "keyart" in ONLY:
        hero = Image.open(os.path.join(WORK, "hero.png")).convert("RGB")
        if hero.size != (W, H):
            hero = hero.resize((W, H), Image.LANCZOS)
        art = grade(hero)
        art = sun_flare(art, int(W * 0.66), int(H * 0.47))
        art = streaks(art)
        full = art.copy()
        lw = int(W * 0.30)
        lg_small = lg.resize((lw, int(lg.size[1] * lw / lg.size[0])), Image.LANCZOS)
        full.paste(lg_small, (int(W * 0.035), int(H * 0.05)), lg_small)
        full.save(os.path.join(OUT, "keyart.jpg"), quality=88, optimize=True, progressive=True)
        art.save(os.path.join(OUT, "keyart_clean.jpg"), quality=86, optimize=True, progressive=True)
        write_import(os.path.join(OUT, "keyart.jpg"), lossy=True)
        write_import(os.path.join(OUT, "keyart_clean.jpg"), lossy=True)
    if "mode" in ONLY:
        # Its own art (not a crop of the key art, which is the loading screens' backdrop).
        duel = mode_art(Image.open(os.path.join(WORK, "faceoff.png")))
        duel.save(os.path.join(OUT, "mode_lonewolf.jpg"), quality=88, optimize=True, progressive=True)
        write_import(os.path.join(OUT, "mode_lonewolf.jpg"), lossy=True, mipmaps=True)
    if "logo" in ONLY:
        lg_out = lg.resize((900, int(lg.size[1] * 900 / lg.size[0])), Image.LANCZOS)
        lg_out.save(os.path.join(OUT, "logo.png"), optimize=True)
        write_import(os.path.join(OUT, "logo.png"), lossy=False, mipmaps=True)
    if "emblem" in ONLY:
        em = draw_emblem(256)
        em.save(os.path.join(OUT, "emblem.png"), optimize=True)
        write_import(os.path.join(OUT, "emblem.png"), lossy=False, mipmaps=True)
    if "portraits" in ONLY:
        portraits()
    if "skyline" in ONLY:
        sky = skyline()
        sky.save(os.path.join(OUT, "lobby_skyline.png"), optimize=True)
        write_import(os.path.join(OUT, "lobby_skyline.png"), lossy=False, mipmaps=True)
    print("key art done (%s); renders in %s" % (",".join(sorted(ONLY)), WORK))


if __name__ == "__main__":
    main()
