#!/usr/bin/env python3
"""Draws the HUD's vector icons (white shapes, black = cut-out, 128x128 viewBox) and writes them
as 192x192 white-on-transparent PNGs into assets/ui/icons/ (alpha = brightness, so the black
cut-outs become holes), plus the coloured elimination badge (badge_elim.png). New icons get a
.import file with mipmaps on (the HUD draws them scaled down). tools/media/render_silhouettes.py
adds the silhouette icons (stances, weapons, grenade) rendered from the game's own 3D models.
Needs: pip install cairosvg pillow. Run `godot --headless --path . --import` afterwards.

usage: python3 tools/media/make_ui_icons.py [out_dir] [--preview sheet.png]"""
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "assets", "ui", "icons")
W = "#ffffff"


def svg(body, view=128):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d">%s</svg>'
            % (view, view, view, view, body))


def ring(cx, cy, r, w):
    return '<circle cx="%g" cy="%g" r="%g" fill="none" stroke="%s" stroke-width="%g"/>' % (cx, cy, r, W, w)


def dot(cx, cy, r):
    return '<circle cx="%g" cy="%g" r="%g" fill="%s"/>' % (cx, cy, r, W)


def line(x1, y1, x2, y2, w, cap="round"):
    return ('<line x1="%g" y1="%g" x2="%g" y2="%g" stroke="%s" stroke-width="%g" stroke-linecap="%s"/>'
            % (x1, y1, x2, y2, W, w, cap))


def path(d, fill=True, w=0, extra=""):
    if fill:
        return '<path d="%s" fill="%s" %s/>' % (d, W, extra)
    return ('<path d="%s" fill="none" stroke="%s" stroke-width="%g" stroke-linecap="round" stroke-linejoin="round" %s/>'
            % (d, W, w, extra))


def poly(points):
    return '<polygon points="%s" fill="%s"/>' % (" ".join("%g,%g" % p for p in points), W)


def arc_path(cx, cy, r, a0, a1):
    """SVG arc from angle a0 to a1 (degrees, clockwise, 0 = right)."""
    x0, y0 = cx + r * math.cos(math.radians(a0)), cy + r * math.sin(math.radians(a0))
    x1, y1 = cx + r * math.cos(math.radians(a1)), cy + r * math.sin(math.radians(a1))
    large = 1 if (a1 - a0) % 360 > 180 else 0
    return "M%g %g A%g %g 0 %d 1 %g %g" % (x0, y0, r, r, large, x1, y1)


def bullet(x, y, w, h):
    """Upright cartridge with its tip at (x, y)."""
    r = w / 2
    return path("M%g %g C%g %g %g %g %g %g L%g %g L%g %g L%g %g C%g %g %g %g %g %g Z" % (
        x, y, x + r * 0.9, y + h * 0.12, x + r, y + h * 0.28, x + r, y + h * 0.42,
        x + r, y + h, x - r, y + h, x - r, y + h * 0.42,
        x - r, y + h * 0.28, x - r * 0.9, y + h * 0.12, x, y))


ICONS = {}

def cartridge(cx, cy, w, h, angle):
    """A rifle cartridge (bullet + case with a rim groove) centred on (cx, cy), tip up before
    rotating by `angle` degrees (clockwise)."""
    x, y = cx, cy - h / 2
    r = w / 2
    tip = h * 0.36
    body = (path("M%g %g C%g %g %g %g %g %g L%g %g L%g %g L%g %g C%g %g %g %g %g %g Z" % (
        x, y, x + r * 0.55, y + tip * 0.25, x + r, y + tip * 0.62, x + r, y + tip,
        x + r, y + h, x - r, y + h, x - r, y + tip,
        x - r, y + tip * 0.62, x - r * 0.55, y + tip * 0.25, x, y)))
    # Seam between bullet and case, and the extractor groove near the base.
    cuts = ('<rect x="%g" y="%g" width="%g" height="%g" fill="#000"/>' % (x - r - 1, y + tip + 2, w + 2, 4)
            + '<rect x="%g" y="%g" width="%g" height="%g" fill="#000"/>' % (x - r - 1, y + h - 13, w + 2, 4))
    return '<g transform="rotate(%g %g %g)">%s%s</g>' % (angle, cx, cy, body, cuts)


# Fire: a cartridge flying up-right with three short blast streaks behind its base.
ICONS["fire"] = svg(cartridge(74, 52, 32, 96, 45)
                    + line(31, 97, 9, 119, 9) + line(45, 109, 33, 121, 8) + line(19, 83, 7, 95, 8))
# Scope / aim down sights: reticle.
ICONS["scope"] = svg(ring(64, 64, 40, 7) + ring(64, 64, 13, 6) + line(64, 8, 64, 38, 7) + line(64, 90, 64, 120, 7)
                     + line(8, 64, 38, 64, 7) + line(90, 64, 120, 64, 7))
# Reload: circular arrow around a cartridge.
ICONS["reload"] = svg(path(arc_path(64, 64, 42, -60, 230), False, 9)
                      + poly([(98, 14), (104, 46), (72, 40)]) + bullet(64, 40, 16, 48))
# Medkit: case with a cross and a handle.
ICONS["medkit"] = svg(path("M44 30 V22 A6 6 0 0 1 50 16 H78 A6 6 0 0 1 84 22 V30", False, 7)
                      + '<rect x="14" y="30" width="100" height="78" rx="12" fill="%s"/>' % W
                      + '<path d="M56 46 H72 V61 H87 V77 H72 V92 H56 V77 H41 V61 H56 Z" fill="#000" fill-opacity="1"/>')
# Shield wall: a curved energy wall with hex cells.
hexes = ""
for row in range(3):
    for col in range(4):
        cx = 30 + col * 23 + (11 if row % 2 else 0)
        cy = 44 + row * 20
        if cx > 104:
            continue
        pts = [(cx + 10 * math.cos(math.radians(60 * k + 30)), cy + 10 * math.sin(math.radians(60 * k + 30))) for k in range(6)]
        hexes += '<polygon points="%s" fill="none" stroke="#000" stroke-width="3"/>' % " ".join("%g,%g" % p for p in pts)
ICONS["wall"] = svg(path("M14 108 V40 Q64 14 114 40 V108 Z") + hexes)
# Settings gear.
teeth = []
for k in range(8):
    a = math.radians(k * 45)
    teeth.append('<rect x="56" y="10" width="16" height="22" rx="3" fill="%s" transform="rotate(%g 64 64)"/>' % (W, k * 45))
ICONS["settings"] = svg("".join(teeth) + dot(64, 64, 38) + '<circle cx="64" cy="64" r="15" fill="#000"/>')
# Map: folded map.
ICONS["map"] = svg(poly([(10, 30), (44, 18), (84, 30), (118, 18), (118, 98), (84, 110), (44, 98), (10, 110)])
                   + line(44, 22, 44, 96, 4) + '<line x1="84" y1="32" x2="84" y2="106" stroke="#000" stroke-width="4"/>'
                   + '<line x1="44" y1="22" x2="44" y2="96" stroke="#000" stroke-width="4"/>')
# Backpack.
ICONS["backpack"] = svg(path("M46 30 V22 A8 8 0 0 1 54 14 H74 A8 8 0 0 1 82 22 V30", False, 7)
                        + '<rect x="24" y="28" width="80" height="88" rx="22" fill="%s"/>' % W
                        + '<rect x="40" y="70" width="48" height="28" rx="6" fill="#000"/>')
# Scoreboard: podium / list.
ICONS["scoreboard"] = svg('<rect x="14" y="20" width="100" height="18" rx="5" fill="%s"/>' % W
                          + '<rect x="14" y="55" width="100" height="18" rx="5" fill="%s"/>' % W
                          + '<rect x="14" y="90" width="100" height="18" rx="5" fill="%s"/>' % W
                          + '<rect x="24" y="24" width="10" height="10" fill="#000"/><rect x="24" y="59" width="10" height="10" fill="#000"/>'
                          + '<rect x="24" y="94" width="10" height="10" fill="#000"/>')
# Pause.
ICONS["pause"] = svg('<rect x="30" y="22" width="24" height="84" rx="5" fill="%s"/><rect x="74" y="22" width="24" height="84" rx="5" fill="%s"/>' % (W, W))
# Skull (kills, kill feed).
ICONS["skull"] = svg(path("M64 12 C34 12 16 32 16 58 C16 76 26 86 36 90 V108 A6 6 0 0 0 42 114 H86 A6 6 0 0 0 92 108 V90 C102 86 112 76 112 58 C112 32 94 12 64 12 Z")
                     + '<ellipse cx="45" cy="60" rx="13" ry="15" fill="#000"/><ellipse cx="83" cy="60" rx="13" ry="15" fill="#000"/>'
                     + '<path d="M64 76 L56 92 H72 Z" fill="#000"/>'
                     + '<rect x="50" y="100" width="6" height="14" fill="#000"/><rect x="72" y="100" width="6" height="14" fill="#000"/>')
# Headshot: head in crosshair.
ICONS["headshot"] = svg(dot(64, 52, 22) + path("M28 112 C28 88 44 78 64 78 C84 78 100 88 100 112 Z")
                        + ring(64, 52, 36, 5) + line(64, 4, 64, 20, 5) + line(12, 52, 28, 52, 5) + line(100, 52, 116, 52, 5))
# Alive / player count.
ICONS["player"] = svg(dot(64, 38, 24) + path("M20 116 C20 84 40 70 64 70 C88 70 108 84 108 116 Z"))
# Timer.
ICONS["timer"] = svg(ring(64, 70, 44, 8) + '<rect x="54" y="8" width="20" height="12" rx="3" fill="%s"/>' % W
                     + line(64, 70, 64, 42, 8) + line(64, 70, 84, 82, 8))
# Safe zone.
ICONS["zone"] = svg(ring(64, 64, 46, 7) + dot(64, 64, 9) + path("M64 30 L56 44 H72 Z") + path("M64 98 L56 84 H72 Z")
                    + path("M30 64 L44 56 V72 Z") + path("M98 64 L84 56 V72 Z"))
# Vest (body armor) and helmet.
ICONS["vest"] = svg(path("M40 14 L52 14 C54 24 74 24 76 14 L88 14 L110 30 L104 60 L96 56 V114 H32 V56 L24 60 L18 30 Z"))
ICONS["helmet"] = svg(path("M14 86 C14 46 36 22 66 22 C96 22 114 44 114 74 V86 H96 V96 H34 V86 Z"))
# Eye (free look).
ICONS["eye"] = svg(path("M6 64 C26 30 102 30 122 64 C102 98 26 98 6 64 Z") + '<circle cx="64" cy="64" r="22" fill="#000"/>' + dot(64, 64, 11))
# Back arrow / close.
ICONS["back"] = svg(path("M72 22 L30 64 L72 106", False, 14))
ICONS["close"] = svg(line(28, 28, 100, 100, 14) + line(100, 28, 28, 100, 14))
# Trophy (victory / wins).
ICONS["trophy"] = svg(path("M34 14 H94 V44 C94 66 80 80 64 80 C48 80 34 66 34 44 Z")
                      + path("M34 22 H16 V36 C16 50 26 58 38 58", False, 7) + path("M94 22 H112 V36 C112 50 102 58 90 58", False, 7)
                      + '<rect x="56" y="78" width="16" height="18" fill="%s"/><rect x="38" y="96" width="52" height="16" rx="4" fill="%s"/>' % (W, W))
# Crosshair glyph (settings preview).
ICONS["crosshair"] = svg(dot(64, 64, 7) + line(64, 14, 64, 44, 8) + line(64, 84, 64, 114, 8) + line(14, 64, 44, 64, 8) + line(84, 64, 114, 64, 8))
# Swap weapon arrows.
ICONS["swap"] = svg(path("M20 44 H96", False, 9) + poly([(92, 28), (114, 44), (92, 60)]) + path("M108 84 H32", False, 9)
                    + poly([(36, 68), (14, 84), (36, 100)]))
# Lock (locked bundle).
ICONS["lock"] = svg(path("M40 56 V40 A24 24 0 0 1 88 40 V56", False, 10) + '<rect x="26" y="54" width="76" height="62" rx="10" fill="%s"/>' % W)
# Coin (offline reward currency).
ICONS["coin"] = svg(dot(64, 64, 52) + ring(64, 64, 38, 6).replace(W, "#000") + path("M64 40 L76 64 L64 88 L52 64 Z").replace(W, "#000"))
# Star (XP / level).
star = [(64 + (52 if k % 2 == 0 else 22) * math.cos(math.radians(-90 + k * 36)),
         66 + (52 if k % 2 == 0 else 22) * math.sin(math.radians(-90 + k * 36))) for k in range(10)]
ICONS["star"] = svg(poly(star))
# Wardrobe / bundle (hanger).
ICONS["wardrobe"] = svg(path("M64 40 V30 A10 10 0 1 1 74 20", False, 7) + path("M64 40 L10 80 H118 Z", False, 8)
                        + '<rect x="14" y="78" width="100" height="10" rx="5" fill="%s"/>' % W)
# Info / how to play.
ICONS["info"] = svg(ring(64, 64, 52, 8) + dot(64, 38, 8) + '<rect x="57" y="54" width="14" height="44" rx="5" fill="%s"/>' % W)
# Sound on.
ICONS["sound"] = svg(path("M14 48 H40 L70 22 V106 L40 80 H14 Z") + path("M86 44 C96 54 96 74 86 84", False, 8)
                     + path("M98 30 C116 48 116 80 98 98", False, 8))
# Graphics (picture).
ICONS["graphics"] = svg('<rect x="10" y="22" width="108" height="84" rx="10" fill="%s"/>' % W
                        + '<path d="M22 94 L52 56 L72 80 L86 64 L106 94 Z" fill="#000"/><circle cx="90" cy="44" r="9" fill="#000"/>')
# Controls (gamepad-ish joystick).
ICONS["controls"] = svg(ring(64, 64, 50, 7) + dot(64, 64, 22))
# Sensitivity (sliders).
ICONS["sensitivity"] = svg(line(18, 34, 110, 34, 7) + line(18, 64, 110, 64, 7) + line(18, 94, 110, 94, 7)
                           + dot(44, 34, 12) + dot(86, 64, 12) + dot(58, 94, 12))
# Custom HUD (layout grid with a move cross).
ICONS["hud"] = svg('<rect x="10" y="22" width="108" height="84" rx="10" fill="none" stroke="%s" stroke-width="7"/>' % W
                   + dot(36, 78, 14) + dot(94, 70, 18) + dot(92, 40, 9))
# Fist (melee slot / fists button): four knuckles over a thumb, seen from the front.
ICONS["fist"] = svg(
    "".join('<rect x="%g" y="%g" width="23" height="46" rx="11" fill="%s"/>' % (17 + i * 24, 20 + (4 if i in (0, 3) else 0), W)
            for i in range(4))
    + '<rect x="17" y="44" width="95" height="52" rx="14" fill="%s"/>' % W
    + "".join('<line x1="%g" y1="%g" x2="%g" y2="58" stroke="#000" stroke-width="3.5" stroke-linecap="round"/>' % (40.5 + i * 24, 30, 40.5 + i * 24)
              for i in range(3))
    + '<path d="M10 66 C10 58 18 56 26 58 L74 64 C84 66 86 80 76 84 L30 88 C18 89 10 80 10 66 Z" fill="%s" stroke="#000" stroke-width="4"/>' % W
    + '<rect x="40" y="94" width="52" height="26" rx="5" fill="%s"/>' % W
    + '<line x1="38" y1="95" x2="94" y2="95" stroke="#000" stroke-width="3.5"/>')
# Magazine (reload mark on the crosshair): a curved box magazine with grip ridges.
ICONS["mag"] = svg(path("M40 10 H82 L86 30 C90 56 98 82 112 104 L80 120 C64 96 52 66 46 34 Z")
                   + '<line x1="58" y1="44" x2="88" y2="38" stroke="#000" stroke-width="5"/>'
                   + '<line x1="64" y1="62" x2="94" y2="54" stroke="#000" stroke-width="5"/>'
                   + '<line x1="72" y1="80" x2="102" y2="70" stroke="#000" stroke-width="5"/>')
# Running figure (sprint button fallback while no rendered stance_sprint exists).
ICONS["sprint"] = svg(dot(78, 18, 12)
                      + path("M70 34 L52 62 L64 70 L58 92 L36 108", False, 15)
                      + path("M70 34 L84 66 L104 74", False, 13) + path("M64 40 L42 46 L30 62", False, 12)
                      + path("M64 70 L86 86 L96 114", False, 14))
# Lying figure with a rifle (prone button fallback while no rendered stance_prone exists).
ICONS["prone"] = svg(dot(96, 70, 11) + path("M84 78 L52 84 L14 88", False, 15) + path("M84 78 L104 88", False, 9)
                     + line(70, 70, 124, 66, 6) + path("M52 84 L30 96", False, 10))
# Chevron (grenade slot expander / panels).
ICONS["chevron"] = svg(path("M22 84 L64 42 L106 84", False, 16))
# Tick (selected weapon card).
ICONS["tick"] = svg(path("M20 66 L50 96 L108 34", False, 18))


# Coloured badge for the elimination banner (kept in colour, not converted to white).
BADGE = svg(
    # Wings: three angular blades on each side.
    "".join('<polygon points="%s" fill="%s" stroke="#1a1d24" stroke-width="2"/>' % (
        " ".join("%g,%g" % (64 + sx * px, py) for px, py in pts), col)
        for sx in (-1, 1)
        for pts, col in (
            ([(24, 36), (61, 15), (59, 30), (28, 50)], "#f4f6fa"),
            ([(26, 52), (61, 35), (57, 48), (30, 64)], "#dfe3ea"),
            ([(28, 68), (60, 56), (55, 68), (32, 78)], "#bcc4d0"),
        ))
    # Shield with a red rim.
    + '<path d="M64 14 L98 26 L94 74 C90 92 78 104 64 114 C50 104 38 92 34 74 L30 26 Z" fill="#c8323a" stroke="#1a1d24" stroke-width="3"/>'
    + '<path d="M64 22 L91 31 L88 72 C85 87 76 97 64 105 C52 97 43 87 40 72 L37 31 Z" fill="#20242c"/>'
    # Crosshair ring and a fang-shaped mark (our own emblem).
    + '<circle cx="64" cy="58" r="20" fill="none" stroke="#f4f6fa" stroke-width="5"/>'
    + '<line x1="64" y1="30" x2="64" y2="42" stroke="#f4f6fa" stroke-width="5"/>'
    + '<line x1="64" y1="74" x2="64" y2="86" stroke="#f4f6fa" stroke-width="5"/>'
    + '<line x1="36" y1="58" x2="48" y2="58" stroke="#f4f6fa" stroke-width="5"/>'
    + '<line x1="80" y1="58" x2="92" y2="58" stroke="#f4f6fa" stroke-width="5"/>'
    + '<path d="M55 48 L64 72 L73 48 L64 54 Z" fill="#ff5a4e"/>'
    + '<path d="M50 92 H78 L74 100 H54 Z" fill="#ffc94a"/>')
COLOR_ICONS = {"badge_elim": BADGE}


IMPORT_TEMPLATE = """[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="res://assets/ui/icons/%s"

[params]

compress/mode=0
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map=0
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=1
"""


def ensure_import(png_path):
    """HUD icons are drawn scaled down, so they import lossless WITH mipmaps. Writes the .import
    file for a new icon (Godot fills in the uid on the next --import) or switches mipmaps on."""
    imp = png_path + ".import"
    if os.path.exists(imp):
        text = open(imp).read()
        new = re.sub(r"^mipmaps/generate=.*$", "mipmaps/generate=true", text, flags=re.M)
        if new != text:
            open(imp, "w").write(new)
    else:
        open(imp, "w").write(IMPORT_TEMPLATE % os.path.basename(png_path))


def to_white(im):
    """White shapes keep full alpha, black cut-outs become holes (alpha = brightness)."""
    from PIL import Image
    r, g, b, a = im.split()
    lum = Image.merge("RGB", (r, g, b)).convert("L")
    alpha = Image.composite(lum, Image.new("L", im.size, 0), a)
    white = Image.new("RGBA", im.size, (255, 255, 255, 0))
    white.putalpha(alpha)
    return white


def main():
    out = OUT
    args = [a for a in sys.argv[1:]]
    preview = None
    if "--preview" in args:
        preview = args[args.index("--preview") + 1]
        del args[args.index("--preview"):args.index("--preview") + 2]
    if args:
        out = args[0]
    import io
    import cairosvg
    from PIL import Image, ImageDraw
    os.makedirs(out, exist_ok=True)
    in_project = os.path.normpath(out) == os.path.normpath(OUT)
    written = []
    for name, content in ICONS.items():
        png = cairosvg.svg2png(bytestring=content.encode(), output_width=192, output_height=192)
        path = os.path.join(out, "v_" + name + ".png")
        to_white(Image.open(io.BytesIO(png)).convert("RGBA")).save(path)
        written.append(path)
    for name, content in COLOR_ICONS.items():
        png = cairosvg.svg2png(bytestring=content.encode(), output_width=384, output_height=384)
        path = os.path.join(out, name + ".png")
        Image.open(io.BytesIO(png)).convert("RGBA").save(path)
        written.append(path)
    if in_project:
        # Also covers the silhouettes from render_silhouettes.py (run that one first).
        for name in sorted(os.listdir(out)):
            if name.endswith(".png"):
                ensure_import(os.path.join(out, name))
    print("wrote %d icons to %s" % (len(written), out))
    if preview:
        cols = 8
        cell = 150
        rows = (len(written) + cols - 1) // cols
        sheet = Image.new("RGBA", (cols * cell, rows * cell), (40, 44, 52, 255))
        d = ImageDraw.Draw(sheet)
        for i, path in enumerate(sorted(written)):
            im = Image.open(path).convert("RGBA").resize((96, 96), Image.LANCZOS)
            x, y = (i % cols) * cell, (i // cols) * cell
            d.ellipse((x + 15, y + 8, x + 135, y + 128), fill=(0, 0, 0, 110))
            sheet.alpha_composite(im, (x + 27, y + 20))
            d.text((x + 8, y + 132), os.path.basename(path)[:-4], fill=(255, 220, 120, 255))
        sheet.save(preview)
        print("preview", preview)


if __name__ == "__main__":
    main()
