"""house.glb - single-storey concrete house shell 7 x 6 m (X x Y), 3 m high, 0.25 m walls,
door (1.2 x 2.2) on +Y and -Y, two windows (1.2 x 1.0, sill 1.0 m) on each long (+/-Y) side, flat roof slab.
Origin bottom centre. Also writes the collider boxes (Godot axes) to meta/house.json."""
import sys
sys.path.insert(0, '/root/work/tools/props')
from lib import *
reset()
WA = mat('Wall', '#d9cdb5', metallic=0.0, rough=0.85)
TR = mat('Trim', '#7e7b74', metallic=0.0, rough=0.8)
RF = mat('Roof', '#55585c', metallic=0.0, rough=0.9)
X, Y, T = 7.0, 6.0, 0.25
HW = 2.8                 # wall height; roof slab 2.8 .. 3.0
RT = 0.20
OV = 0.10                # roof overhang
hx, hy = X / 2, Y / 2
DOOR = (1.2, 2.2)
WIN = (1.2, 1.0, 1.0)    # w, h, sill
WIN_X = (-2.0, 2.0)

# ---------------------------------------------------------------- wall ring with openings (boolean)
bm = bmesh.new()
outer = [(hx, hy), (-hx, hy), (-hx, -hy), (hx, -hy)]
inner = [(hx - T, hy - T), (-hx + T, hy - T), (-hx + T, -hy + T), (hx - T, -hy + T)]
ob_ = [[bm.verts.new((x, y, z)) for (x, y) in outer] for z in (0.0, HW)]
ib_ = [[bm.verts.new((x, y, z)) for (x, y) in inner] for z in (0.0, HW)]
for i in range(4):
    j = (i + 1) % 4
    bm.faces.new((ob_[0][i], ob_[0][j], ob_[1][j], ob_[1][i]))       # outer
    bm.faces.new((ib_[0][j], ib_[0][i], ib_[1][i], ib_[1][j]))       # inner
    bm.faces.new((ob_[1][i], ob_[1][j], ib_[1][j], ib_[1][i]))       # top
    bm.faces.new((ob_[0][j], ob_[0][i], ib_[0][i], ib_[0][j]))       # bottom
bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
cutters = []
for sy in (-1, 1):
    cutters.append((bm_box(-DOOR[0] / 2, DOOR[0] / 2, sy * hy - 0.4, sy * hy + 0.4, -0.1, DOOR[1]), WA))
    for wx in WIN_X:
        cutters.append((bm_box(wx - WIN[0] / 2, wx + WIN[0] / 2, sy * hy - 0.4, sy * hy + 0.4, WIN[2], WIN[2] + WIN[1]), WA))
part(bm, WA, bevel=0.015, bevel_angle=50, name='walls', cutters=cutters)

# ---------------------------------------------------------------- plinth band (outside), cut at the doors
pl = bmesh.new()
po = [(hx + 0.03, hy + 0.03), (-hx - 0.03, hy + 0.03), (-hx - 0.03, -hy - 0.03), (hx + 0.03, -hy - 0.03)]
pi = [(hx - 0.01, hy - 0.01), (-hx + 0.01, hy - 0.01), (-hx + 0.01, -hy + 0.01), (hx - 0.01, -hy + 0.01)]
a = [[pl.verts.new((x, y, z)) for (x, y) in po] for z in (0.0, 0.32)]
b = [[pl.verts.new((x, y, z)) for (x, y) in pi] for z in (0.0, 0.32)]
for i in range(4):
    j = (i + 1) % 4
    pl.faces.new((a[0][i], a[0][j], a[1][j], a[1][i]))
    pl.faces.new((b[0][j], b[0][i], b[1][i], b[1][j]))
    pl.faces.new((a[1][i], a[1][j], b[1][j], b[1][i]))
    pl.faces.new((a[0][j], a[0][i], b[0][i], b[0][j]))
bmesh.ops.recalc_face_normals(pl, faces=pl.faces)
part(pl, TR, name='plinth', cutters=[(bm_box(-DOOR[0] / 2 - 0.08, DOOR[0] / 2 + 0.08, sy * hy - 0.3, sy * hy + 0.3, -0.1, 0.5), TR) for sy in (-1, 1)])

# ---------------------------------------------------------------- window / door frames (outside)
for sy in (-1, 1):
    yo = sy * hy
    def fbox(x0, x1, z0, z1, depth):
        ya, yb = yo - sy * 0.01, yo + sy * depth
        return bm_box(x0, x1, min(ya, yb), max(ya, yb), z0, z1)
    for wx in WIN_X:
        w0, w1 = wx - WIN[0] / 2, wx + WIN[0] / 2
        z0, z1 = WIN[2], WIN[2] + WIN[1]
        part(fbox(w0 - 0.10, w1 + 0.10, z1, z1 + 0.10, 0.04), TR, name='lintel')
        part(fbox(w0 - 0.14, w1 + 0.14, z0 - 0.08, z0, 0.08), TR, name='sill')
        part(fbox(w0 - 0.10, w0, z0, z1, 0.04), TR, name='jamb')
        part(fbox(w1, w1 + 0.10, z0, z1, 0.04), TR, name='jamb')
    d0, d1 = -DOOR[0] / 2, DOOR[0] / 2
    part(fbox(d0 - 0.12, d1 + 0.12, DOOR[1], DOOR[1] + 0.12, 0.05), TR, name='dlintel')
    part(fbox(d0 - 0.12, d0, 0.0, DOOR[1], 0.05), TR, name='djamb')
    part(fbox(d1, d1 + 0.12, 0.0, DOOR[1], 0.05), TR, name='djamb')
    # door step
    ya, yb = yo, yo + sy * 0.35
    part(bm_box(d0 - 0.2, d1 + 0.2, min(ya, yb), max(ya, yb), 0.0, 0.08), TR, name='step')

# ---------------------------------------------------------------- roof slab: top = Roof, sides = Trim, underside = Wall
rs = bm_box(-hx - OV, hx + OV, -hy - OV, hy + OV, HW, HW + RT)
rs.normal_update()
for f in rs.faces:
    f.material_index = 0 if f.normal.z > 0.9 else (2 if f.normal.z < -0.9 else 1)
part(rs, [RF, TR, WA], name='roof')
# low parapet lip / drip edge in Trim
part(bm_box(-hx - OV, hx + OV, -hy - OV, -hy - OV + 0.12, HW + RT, HW + RT + 0.0), TR, name='noop') if False else None

ob = finalize('House')
report(ob, 'house', 1500)
export('house')

# ---------------------------------------------------------------- collider boxes (Blender min/max -> Godot centre/size)
boxes = []
def add(name, x0, x1, y0, y1, z0, z1):
    c = ((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
    s = (x1 - x0, y1 - y0, z1 - z0)
    boxes.append(dict(name=name, center=[round(c[0], 4), round(c[2], 4), round(-c[1], 4)],
                      size=[round(s[0], 4), round(s[2], 4), round(s[1], 4)]))
for sy, tag in ((1, 'north_+Y'), (-1, 'south_-Y')):
    y0, y1 = sorted((sy * hy, sy * (hy - T)))
    xs = [-hx, WIN_X[0] - WIN[0] / 2, WIN_X[0] + WIN[0] / 2, -DOOR[0] / 2, DOOR[0] / 2,
          WIN_X[1] - WIN[0] / 2, WIN_X[1] + WIN[0] / 2, hx]
    add(f'{tag}_pier1', xs[0], xs[1], y0, y1, 0, HW)
    add(f'{tag}_win1_below', xs[1], xs[2], y0, y1, 0, WIN[2])
    add(f'{tag}_win1_above', xs[1], xs[2], y0, y1, WIN[2] + WIN[1], HW)
    add(f'{tag}_pier2', xs[2], xs[3], y0, y1, 0, HW)
    add(f'{tag}_door_above', xs[3], xs[4], y0, y1, DOOR[1], HW)
    add(f'{tag}_pier3', xs[4], xs[5], y0, y1, 0, HW)
    add(f'{tag}_win2_below', xs[5], xs[6], y0, y1, 0, WIN[2])
    add(f'{tag}_win2_above', xs[5], xs[6], y0, y1, WIN[2] + WIN[1], HW)
    add(f'{tag}_pier4', xs[6], xs[7], y0, y1, 0, HW)
add('east_+X', hx - T, hx, -hy + T, hy - T, 0, HW)
add('west_-X', -hx, -hx + T, -hy + T, hy - T, 0, HW)
add('roof_slab', -hx - OV, hx + OV, -hy - OV, hy + OV, HW, HW + RT)
save_meta('house', dict(collision_boxes=boxes))
print('collision boxes:', len(boxes))
