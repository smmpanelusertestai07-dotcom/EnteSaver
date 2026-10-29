"""rollup_door.glb - closed industrial roll-up shutter door for a 4.4 x 5.0 m opening, made to be
mounted flush on a wall face. Horizontal ribbed slats ('Shutter'), side guide rails, top roll housing
box and bottom bar ('Steel'), rubber seal ('Black'), yellow/black diagonal hazard bands wrapped around
the lower 1.2 m of both guide rails ('Yellow', 'Black'), small push-button control box on the +X side
(= the viewer's LEFT when facing the door front).
FRONT toward Blender +Y (Godot -Z). Origin: bottom centre of the opening ON THE BACK (mounting) PLANE:
x = 0 opening centre, y = 0 wall face, z = 0 floor. Everything sits in y 0..0.48."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *

reset()
SH = mat('Shutter', '#b9bec5', metallic=0.3, rough=0.5)
ST = mat('Steel', '#474c54', metallic=0.5, rough=0.45)
YE = mat('Yellow', '#f2c200', metallic=0.0, rough=0.55)
BK = mat('Black', '#1a1a1a', metallic=0.0, rough=0.7)

OW, OH = 4.4, 5.0          # opening
HW = OW / 2
RW, RD = 0.16, 0.20        # guide rail width (x) / depth (y)
YCF = 0.12                 # curtain front plane
GRV = 0.022                # slat joint groove depth
ZBAR = 0.155               # top of the bottom bar
NSLAT = 44
HZ = 1.2                   # hazard band height on the rails
BAND = 0.15                # vertical size of one hazard band
HB0, HB1, HD = OH, OH + 0.6, 0.46     # housing z range and depth
HXW = HW + RW + 0.04       # housing half width

DIRS = {'+x': Vector((1, 0, 0)), '-x': Vector((-1, 0, 0)), '+y': Vector((0, 1, 0)),
        '-y': Vector((0, -1, 0)), '+z': Vector((0, 0, 1)), '-z': Vector((0, 0, -1))}


def drop_faces(bm, drop):
    bm.normal_update()
    dels = [f for f in bm.faces if any(f.normal.dot(DIRS[d]) > 0.95 for d in drop)]
    bmesh.ops.delete(bm, geom=dels, context='FACES')
    return bm


def oface(bm, verts, want):
    f = bm.faces.new(verts)
    f.normal_update()
    if f.normal.dot(want) < 0:
        f.normal_flip()
    return f


# ---------------------------------------------------------------- curtain: ribbed slats (front surface only)
def curtain():
    bm = bmesh.new()
    z0, z1 = ZBAR - 0.02, OH + 0.03
    h = (z1 - z0) / NSLAT
    prof = []                                   # (y, z) bottom -> top
    for k in range(NSLAT):
        b = z0 + k * h
        prof += [(YCF - GRV, b), (YCF, b + 0.016), (YCF, b + h - 0.036), (YCF - GRV * 0.45, b + h - 0.008)]
    prof.append((YCF - GRV, z1))
    xa, xb = -HW - 0.005, HW + 0.005
    rows = [(bm.verts.new((xa, y, z)), bm.verts.new((xb, y, z))) for y, z in prof]
    for (a0, a1), (b0, b1) in zip(rows[:-1], rows[1:]):
        oface(bm, (a0, a1, b1, b0), DIRS['+y'])
    # plain back sheet so the door also reads closed from behind
    bv = [bm.verts.new(p) for p in ((xa, 0.0, 0.0), (xb, 0.0, 0.0), (xb, 0.0, OH), (xa, 0.0, OH))]
    oface(bm, bv, DIRS['-y'])
    return bm


part(curtain(), SH, smooth=35, name='curtain')


# ---------------------------------------------------------------- guide rails with wrapped diagonal hazard bands
def clip_half(poly, a, b, c):
    """Keep the part of a convex polygon with a*u + b*z + c >= 0."""
    out = []
    n = len(poly)
    for i in range(n):
        p, q = poly[i], poly[(i + 1) % n]
        fp, fq = a * p[0] + b * p[1] + c, a * q[0] + b * q[1] + c
        if fp >= 0:
            out.append(p)
        if (fp >= 0) != (fq >= 0):
            t = fp / (fp - fq)
            out.append((p[0] + t * (q[0] - p[0]), p[1] + t * (q[1] - p[1])))
    clean = []
    for p in out:
        if not clean or (abs(p[0] - clean[-1][0]) > 1e-7 or abs(p[1] - clean[-1][1]) > 1e-7):
            clean.append(p)
    if len(clean) > 1 and abs(clean[0][0] - clean[-1][0]) < 1e-7 and abs(clean[0][1] - clean[-1][1]) < 1e-7:
        clean.pop()
    return clean


def area2(poly):
    return abs(sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1]
                   for i in range(len(poly)))) / 2


def rail(sx):
    """Guide rail at side sx (+1 = +X side, -1 = -X side). Faces are unfolded into one strip coordinate u
    (inner side -> front -> outer side) so the diagonal bands wrap continuously around the corners."""
    xi, xo = sx * HW, sx * (HW + RW)
    yf, yfl = RD, 0.012
    faces = [  # (u0, u1, map(u, z) -> 3D, normal)
        (-RD, 0.0, lambda u, z: Vector((xi, RD + u, z)), Vector((-sx, 0, 0))),
        (0.0, RW, lambda u, z: Vector((xi + sx * u, yf, z)), Vector((0, 1, 0))),
        (RW, RW + RD - yfl, lambda u, z: Vector((xo, RD - (u - RW), z)), Vector((sx, 0, 0))),
    ]
    bm = bmesh.new()
    S = 1.0                                     # 45 deg bands, rising toward the outside
    for (u0, u1, fmap, nrm) in faces:
        kmin = int(math.floor((0.0 - S * u1) / BAND)) - 1
        kmax = int(math.ceil((HZ - S * u0) / BAND)) + 1
        rect = [(u0, 0.0), (u1, 0.0), (u1, HZ), (u0, HZ)]
        cuts = []
        for k in range(kmin, kmax + 1):
            c0, c1 = k * BAND, (k + 1) * BAND
            poly = clip_half(rect, -S, 1.0, -c0)
            poly = clip_half(poly, S, -1.0, c1) if len(poly) >= 3 else []
            if len(poly) >= 3 and area2(poly) > 1e-7:
                oface(bm, [bm.verts.new(fmap(u, z)) for u, z in poly], nrm).material_index = 1 if k % 2 == 0 else 2
            uc = (HZ - c0) / S                  # band boundary hitting the top edge of the striped zone
            if u0 + 1e-6 < uc < u1 - 1e-6:
                cuts.append(uc)
        top = [(u0, HZ)] + [(u, HZ) for u in sorted(cuts)] + [(u1, HZ), (u1, OH), (u0, OH)]
        oface(bm, [bm.verts.new(fmap(u, z)) for u, z in top], nrm).material_index = 0
    # mounting flange strip beyond the outer side + plain back
    fl = drop_faces(bm_box(min(xo, xo + sx * 0.05), max(xo, xo + sx * 0.05), 0.0, yfl, 0.0, OH), ('-z', '+z'))
    bv = [bm.verts.new(p) for p in ((xi, 0.0, 0.0), (xo, 0.0, 0.0), (xo, 0.0, OH), (xi, 0.0, OH))]
    oface(bm, bv, DIRS['-y']).material_index = 0
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    return bm, fl


for sx in (-1, 1):
    bm, fl = rail(sx)
    part(bm, [ST, YE, BK], smooth=30, name='rail')
    part(fl, ST, name='rail_flange')

# ---------------------------------------------------------------- roll housing box with end plates
prof = [(0.0, HB0 - 0.02), (HD - 0.06, HB0 - 0.02), (HD, HB0 + 0.05), (HD, HB1 - 0.06), (HD - 0.07, HB1),
        (0.0, HB1)]
part(bm_prism(prof, 'X', -HXW, HXW), ST, bevel=0.008, name='housing')
for sx in (-1, 1):
    xa, xb = sorted((sx * HXW, sx * (HXW + 0.03)))
    part(bm_box(xa, xb, 0.0, HD + 0.02, HB0 - 0.05, HB1 + 0.02), ST, bevel=0.006, name='end_plate')
# two vertical cover strips split the hood front into three sheet panels
for xs in (-HXW / 3, HXW / 3):
    part(drop_faces(bm_box(xs - 0.03, xs + 0.03, HD - 0.01, HD + 0.012, HB0 + 0.05, HB1 - 0.06), ('-y',)), ST,
         name='hood_strip')

# ---------------------------------------------------------------- control box (open / close buttons) on the +X side
cx0, cx1 = HW + RW + 0.08, HW + RW + 0.26
part(bm_box(cx0, cx1, 0.0, 0.09, 1.30, 1.62), ST, bevel=0.006, name='ctrl_box')
part(drop_faces(bm_box(cx0 + 0.02, cx1 - 0.02, 0.09, 0.097, 1.32, 1.60), ('-y',)), YE, name='ctrl_plate')
for bz in (1.40, 1.52):
    xm = (cx0 + cx1) / 2
    part(drop_faces(bm_box(xm - 0.025, xm + 0.025, 0.097, 0.118, bz - 0.025, bz + 0.025), ('-y',)), BK, name='button')

# ---------------------------------------------------------------- bottom bar, seal, handles
bar = [(0.06, 0.03), (0.152, 0.03), (0.165, 0.043), (0.165, 0.125), (0.14, ZBAR), (0.06, ZBAR)]
part(drop_faces(bm_prism(bar, 'X', -HW, HW), ('-x', '+x', '-y')), ST, bevel=0.006, name='bottom_bar')
part(drop_faces(bm_box(-HW, HW, 0.07, 0.15, 0.0, 0.031), ('-x', '+x', '-y', '-z', '+z')), BK, name='seal')
for hx in (-1.25, 1.25):
    path = [(hx - 0.11, 0.155, 0.088), (hx - 0.11, 0.215, 0.088), (hx + 0.11, 0.215, 0.088), (hx + 0.11, 0.155, 0.088)]
    part(bm_tube(path, 0.013, sides=6, caps=False), ST, smooth=70, name='handle')
# centre lock plate
part(drop_faces(bm_box(-0.06, 0.06, 0.16, 0.175, 0.045, 0.125), ('-y',)), ST, name='lock')
part(drop_faces(bm_box(-0.012, 0.012, 0.175, 0.18, 0.07, 0.10), ('-y',)), BK, name='keyhole')

ob = finalize('RollupDoor')
report(ob, 'rollup_door', 900)
export('rollup_door')
