"""wall_bay.glb - one 6 m bay of the warehouse outer wall (x -3..+3), 9 m tall, 0.25 m deep.
FRONT = inner face (the side players see) toward Blender +Y (Godot -Z).
Vertical trapezoid-corrugated cladding (real geometry): ochre lower band z 0-2.6 ('WallLower'),
light-grey upper part z 2.6-9 ('WallUpper'); steel girt/ledge at z 2.6, steel base trim and top
flashing ('Steel'); a row of 3 high windows (1.5 x 1.6 m, sills at z 6.1) with dark frames/mullions
('Frame') and opaque emissive daylight panes ('Glass'). Back side is a flat plain slab.
Origin: bottom centre of the slab (x = 0, y = 0 = middle of the 0.25 m depth, z = 0 = floor).
The corrugation starts and ends on a valley at x = +-3, so bays tile seamlessly side by side."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *

reset()
WL = mat('WallLower', '#d98a2b', metallic=0.15, rough=0.55)
WU = mat('WallUpper', '#c8ccd1', metallic=0.15, rough=0.5)
ST = mat('Steel', '#474c54', metallic=0.5, rough=0.45)
FR = mat('Frame', '#3a3f46', metallic=0.35, rough=0.5)
GL = mat('Glass', '#dcecff', metallic=0.0, rough=0.15, emit='#dcecff', emit_strength=1.5)

# ---------------------------------------------------------------- dimensions (Blender coords)
HX = 3.0                 # half bay width
H = 9.0                  # wall height
YB = -0.125              # back face of the slab
YV = -0.005              # slab front = corrugation valley plane
YC = 0.045               # corrugation crest plane (main visible wall surface)
YG = 0.125               # front of the girt ledge (front-most point of the bay)
Z_BAND = 2.6             # ochre / grey split
NRIB = 24                # ribs per bay (pitch 0.25 m)
P = 2 * HX / NRIB
FV, FS = 0.42, 0.12      # valley (pan) and slope widths as fractions of the pitch; crest = rest
WIN_X = (-2.0, 0.0, 2.0)
WIN_W, WIN_H, SILL = 1.5, 1.6, 6.1
WIN_T = SILL + WIN_H
Z_FLASH = 8.80           # underside of the top flashing
Z_BASE = 0.12            # top of the steel base trim
GIRT = (2.50, 2.70)      # girt ledge z range

DIRS = {'+x': Vector((1, 0, 0)), '-x': Vector((-1, 0, 0)), '+y': Vector((0, 1, 0)),
        '-y': Vector((0, -1, 0)), '+z': Vector((0, 0, 1)), '-z': Vector((0, 0, -1))}


def drop_faces(bm, drop):
    """Delete faces whose normal points along any of the given directions (hidden faces)."""
    bm.normal_update()
    dels = [f for f in bm.faces if any(f.normal.dot(DIRS[d]) > 0.95 for d in drop)]
    bmesh.ops.delete(bm, geom=dels, context='FACES')
    return bm


def oface(bm, verts, want):
    """New face oriented so its normal points along `want`."""
    f = bm.faces.new(verts)
    f.normal_update()
    if f.normal.dot(want) < 0:
        f.normal_flip()
    return f


# ---------------------------------------------------------------- corrugated cladding (front face only)
def corr_points():
    """Profile breakpoints (x, y) over the whole bay; starts/ends at a valley so bays tile."""
    fc = 1.0 - FV - 2 * FS
    pts = [(-HX, YV)]
    for k in range(NRIB):
        x0 = -HX + k * P
        for f, y in ((FV / 2, YV), (FV / 2 + FS, YC), (FV / 2 + FS + fc, YC), (1 - FV / 2, YV)):
            pts.append((x0 + f * P, y))
    pts.append((HX, YV))
    return pts


PTS = corr_points()


def y_at(x):
    for (x0, y0), (x1, y1) in zip(PTS[:-1], PTS[1:]):
        if x0 - 1e-9 <= x <= x1 + 1e-9:
            t = 0.0 if x1 == x0 else (x - x0) / (x1 - x0)
            return y0 + t * (y1 - y0)
    return PTS[-1][1]


def clip(xa, xb):
    return [(xa, y_at(xa))] + [(x, y) for (x, y) in PTS if xa + 1e-6 < x < xb - 1e-6] + [(xb, y_at(xb))]


cl = bmesh.new()


def strip(xa, xb, z0, z1, mi):
    prof = clip(xa, xb)
    cols = [(cl.verts.new((x, y, z0)), cl.verts.new((x, y, z1))) for x, y in prof]
    for (a0, a1), (b0, b1) in zip(cols[:-1], cols[1:]):
        oface(cl, (a0, a1, b1, b0), DIRS['+y']).material_index = mi


strip(-HX, HX, Z_BASE - 0.02, GIRT[0] + 0.02, 0)               # ochre lower band
strip(-HX, HX, GIRT[1] - 0.02, SILL, 1)                         # grey, girt -> window sills
edges = [-HX] + [v for xc in WIN_X for v in (xc - WIN_W / 2, xc + WIN_W / 2)] + [HX]
for xa, xb in zip(edges[0::2], edges[1::2]):                    # piers between the windows
    strip(xa, xb, SILL, WIN_T, 1)
strip(-HX, HX, WIN_T, Z_FLASH + 0.02, 1)                        # grey, windows -> flashing
bmesh.ops.remove_doubles(cl, verts=cl.verts, dist=1e-5)
part(cl, [WL, WU], smooth=40, name='cladding')

# ---------------------------------------------------------------- back slab (plain), split at the band line
part(drop_faces(bm_box(-HX, HX, YB, YV, 0.0, Z_BAND), ('+y', '-z', '+z')), WL, name='slab_low')
part(drop_faces(bm_box(-HX, HX, YB, YV, Z_BAND, Z_FLASH), ('+y', '-z', '+z')), WU, name='slab_up')

# ---------------------------------------------------------------- steel: base trim, girt ledge, top flashing
base = [(YV, 0.0), (0.075, 0.0), (0.075, 0.085), (0.045, Z_BASE), (YV, Z_BASE)]
part(drop_faces(bm_prism(base, 'X', -HX, HX), ('-z',)), ST, bevel=0.006, name='base_trim')
g0, g1 = GIRT
girt = [(YV, g0), (YG - 0.012, g0), (YG, g0 + 0.012), (YG, g1 - 0.075), (0.055, g1), (YV, g1)]
part(bm_prism(girt, 'X', -HX, HX), ST, bevel=0.008, name='girt')
flash = [(YB - 0.005, Z_FLASH + 0.06), (YB - 0.005, H), (0.085, H), (0.095, H - 0.012), (0.095, Z_FLASH),
         (0.06, Z_FLASH), (YV, Z_FLASH + 0.035)]
part(bm_prism(flash, 'X', -HX, HX), ST, bevel=0.006, name='flashing')

# ---------------------------------------------------------------- windows
FW = 0.09                 # frame member width
FO = 0.05                 # frame overlap onto the cladding
YF = 0.085                # frame front
YGL = 0.0                 # glass plane
for xc in WIN_X:
    x0, x1 = xc - WIN_W / 2 - FO, xc + WIN_W / 2 + FO
    z0, z1 = SILL - FO, WIN_T + FO
    xi0, xi1, zi0, zi1 = x0 + FW, x1 - FW, z0 + FW, z1 - FW
    bm = bmesh.new()
    O = [(x0, z0), (x1, z0), (x1, z1), (x0, z1)]
    I = [(xi0, zi0), (xi1, zi0), (xi1, zi1), (xi0, zi1)]
    of = [bm.verts.new((x, YF, z)) for x, z in O]
    ob = [bm.verts.new((x, YV, z)) for x, z in O]
    inf = [bm.verts.new((x, YF, z)) for x, z in I]
    ing = [bm.verts.new((x, YGL - 0.004, z)) for x, z in I]
    c = Vector((xc, 0, (z0 + z1) / 2))
    for i in range(4):
        j = (i + 1) % 4
        oface(bm, (of[i], of[j], inf[j], inf[i]), DIRS['+y'])
        mid = (Vector((O[i][0], 0, O[i][1])) + Vector((O[j][0], 0, O[j][1]))) / 2
        oface(bm, (ob[i], ob[j], of[j], of[i]), (mid - c).normalized())        # outer sides
        midi = (Vector((I[i][0], 0, I[i][1])) + Vector((I[j][0], 0, I[j][1]))) / 2
        oface(bm, (inf[i], inf[j], ing[j], ing[i]), (c - midi).normalized())   # inner reveal
    part(bm, FR, name='frame')
    # mullions (2 vertical) + transom: front and two sides only
    yb, yf = YGL, 0.05
    mw = 0.045
    for k in (1, 2):
        xm = xi0 + (xi1 - xi0) * k / 3
        part(drop_faces(bm_box(xm - mw / 2, xm + mw / 2, yb, yf, zi0 - 0.01, zi1 + 0.01), ('-y', '+z', '-z')),
             FR, name='mullion')
    zt = zi0 + (zi1 - zi0) * 0.5
    part(drop_faces(bm_box(xi0 - 0.01, xi1 + 0.01, yb, yf, zt - mw / 2, zt + mw / 2), ('-y', '+x', '-x')),
         FR, name='transom')
    # glass pane (single quad behind the mullions)
    gb = bmesh.new()
    gv = [gb.verts.new((x, YGL, z)) for x, z in ((xi0 - 0.01, zi0 - 0.01), (xi1 + 0.01, zi0 - 0.01),
                                                 (xi1 + 0.01, zi1 + 0.01), (xi0 - 0.01, zi1 + 0.01))]
    oface(gb, gv, DIRS['+y'])
    part(gb, GL, name='glass')
    # sloped steel sill under the frame
    sill = [(YV, z0 - 0.07), (0.115, z0 - 0.07), (0.115, z0 - 0.045), (0.08, z0 + 0.01), (YV, z0 + 0.01)]
    part(bm_prism(sill, 'X', x0 - 0.04, x1 + 0.04), ST, bevel=0.005, name='sill')

ob = finalize('WallBay')
report(ob, 'wall_bay', 1600)
export('wall_bay')
