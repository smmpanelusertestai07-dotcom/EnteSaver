"""container_open.glb - walk-through 20 ft ISO container, outer box 6.058 x 2.438 x 2.591 m like
container.glb (length along X). Both ends are open: no doors at -X; at +X the two door leaves are
swung ~270 deg and rest flat against the OUTSIDE of the side walls (locking gear toward the wall,
gasketed inner face outward). Interior: corrugated inner walls + ceiling (Paint, the same
recolourable material as the outside), wooden plank floor (Wood) with its top at z = 0.12 (one small
step, no ramp; the end sills are flush with it). Clear inside: 2.30 m wide, 2.35 m high.
Materials: Paint, Metal, Rubber (same names/values as container.glb) + Wood. Origin bottom centre.
Also writes assets/props/container_open_colliders.json (Godot axes, origin = prop origin)."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *

reset()
PA = mat('Paint', '#cfcfcc', metallic=0.05, rough=0.6)
ME = mat('Metal', '#5f6266', metallic=0.8, rough=0.45)
RU = mat('Rubber', '#191919', metallic=0.0, rough=0.9)
WD = mat('Wood', '#9a6a3c', metallic=0.0, rough=0.75)

L, W, H = 6.058, 2.438, 2.591
hl, hw = L / 2, W / 2
CX, CY, CZ = 0.178, 0.162, 0.118     # corner casting size
FL = 0.12                             # floor top (single step up, sills flush)
CE = 2.47                             # ceiling, lowest points -> clear height 2.35
YI = 1.15                             # inner wall face, innermost points -> clear width 2.30
YO = hw - 0.012                       # outer corrugation peaks (as container.glb)
DEP = 0.040                           # side corrugation depth (as container.glb)
TS = YO - DEP - YI                    # sheet offset between outer and inner corrugation (0.017)
N_SIDE, N_ROOF = 21, 13               # corrugation periods (as container.glb)


def corrugated(axis_len, a0, a1, z0, z1, n, outer, depth, sign, fo=0.27, s=0.23):
    """Single-sided trapezoid corrugation (from build_container.py). Profile runs along `axis_len`
    ('X' or 'Y') from a0..a1, the sheet plane is at `outer` (coordinate on the other horizontal axis),
    valleys at outer - sign*depth. Faces point to `sign` along the normal axis."""
    p = (a1 - a0) / n
    xs = []
    for k in range(n):
        x0 = a0 + k * p
        xs += [(x0, 0), (x0 + fo * p, 0), (x0 + (fo + s) * p, 1), (x0 + (fo + s + fo) * p, 1)]
    xs.append((a1, 0))
    bm = bmesh.new()
    cols = []
    for (a, inner) in xs:
        o = outer - sign * depth * inner
        if axis_len == 'X':
            v0, v1 = bm.verts.new((a, o, z0)), bm.verts.new((a, o, z1))
        else:
            v0, v1 = bm.verts.new((o, a, z0)), bm.verts.new((o, a, z1))
        cols.append((v0, v1))
    for (a0v, a1v), (b0v, b1v) in zip(cols[:-1], cols[1:]):
        bm.faces.new((a0v, b0v, b1v, a1v))
    bm.normal_update()
    want = Vector((0, sign, 0)) if axis_len == 'X' else Vector((sign, 0, 0))
    for f in bm.faces:
        if f.normal.dot(want) < 0:
            f.normal_flip()
    return bm


def corrugated_roof(x0, x1, y0, y1, z_flat, depth, n, up=True):
    """Roof sheet (from build_container.py): flats at z_flat, dips at z_flat - depth.
    up=False builds the ceiling seen from below: flats at z_flat, ribs hanging down to z_flat - depth."""
    p = (x1 - x0) / n
    xs = []
    for k in range(n):
        a = x0 + k * p
        xs += [(a, 0), (a + 0.3 * p, 0), (a + 0.5 * p, 1), (a + 0.8 * p, 1)]
    xs.append((x1, 0))
    bm = bmesh.new()
    cols = [(bm.verts.new((a, y0, z_flat - depth * i)), bm.verts.new((a, y1, z_flat - depth * i))) for a, i in xs]
    for (a0v, a1v), (b0v, b1v) in zip(cols[:-1], cols[1:]):
        bm.faces.new((a0v, b0v, b1v, a1v))
    bm.normal_update()
    for f in bm.faces:
        if (f.normal.z < 0) == up:
            f.normal_flip()
    return bm


def flip(bm):
    bmesh.ops.reverse_faces(bm, faces=bm.faces[:])
    bm.normal_update()
    return bm


def drop_faces(bm, direction, lim=0.9):
    """Delete faces whose normal points along `direction` (hidden contact faces)."""
    bm.normal_update()
    d = Vector(direction)
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.normal.dot(d) > lim], context='FACES')
    return bm


def box_y(x0, x1, ya, yb, z0, z1):
    return bm_box(x0, x1, min(ya, yb), max(ya, yb), z0, z1)


def beam(p0, p1, w, d):
    """Box of cross-section w x d (d ~ vertical) from p0 to p1."""
    p0, p1 = Vector(p0), Vector(p1)
    v = p1 - p0
    bm = bm_box(-w / 2, w / 2, -d / 2, d / 2, 0.0, v.length)
    bm_transform(bm, Matrix.Translation(p0) @ v.to_track_quat('Z', 'Y').to_matrix().to_4x4())
    return bm


def casting(sx, sy, top):
    """Corner casting with recessed holes on the outward end, side and top faces."""
    x = sx * (hl - CX / 2)
    y = sy * (hw - CY / 2)
    z = (H - CZ / 2) if top else CZ / 2
    bm = bm_boxc(x, y, z, CX, CY, CZ)
    bm.normal_update()
    faces = [f for f in bm.faces if f.normal.dot(Vector((sx, 0, 0))) > 0.9 or
             f.normal.dot(Vector((0, sy, 0))) > 0.9 or (top and f.normal.z > 0.9)]
    bmesh.ops.inset_individual(bm, faces=faces, thickness=0.036, depth=0.0)
    for f in faces:
        nrm = f.normal.copy()
        r = bmesh.ops.extrude_discrete_faces(bm, faces=[f])
        for nf in r['faces']:
            nf.material_index = 1
            for v in nf.verts:
                v.co -= nrm * 0.035
    if not top:
        drop_faces(bm, (0, 0, -1))           # sits on the ground
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


# ---------------------------------------------------------------- corner castings
for sx in (-1, 1):
    for sy in (-1, 1):
        for top in (False, True):
            part(casting(sx, sy, top), [ME, RU], name='casting')

# ---------------------------------------------------------------- frame
xr0, xr1 = -hl + CX - 0.01, hl - CX + 0.01
for sy in (-1, 1):
    # bottom side rail: inner face flush with the inner wall, 4 cm kick lip above the floor
    part(box_y(xr0, xr1, sy * (hw - 0.005), sy * YI, 0.012, 0.16), PA, name='bottom_rail')
    part(box_y(xr0, xr1, sy * (hw - 0.004), sy * (hw - 0.068), H - 0.085, H - 0.012), PA, name='top_rail')
    for sx in (-1, 1):   # corner posts: deep in X, inner face flush with the inner wall
        xa, xb = sx * (hl - 0.004), sx * (hl - 0.150)
        part(box_y(min(xa, xb), max(xa, xb), sy * (hw - 0.004), sy * YI, CZ - 0.01, H - CZ + 0.01), PA, name='post')
yr0, yr1 = -hw + CY - 0.01, hw - CY + 0.01
XR = hl - 0.045                       # rear sill / header outer face (recessed: cam keepers sit on it)
XS = hl - CX                          # end sills reach the castings' inner face (planks stop there)
part(bm_box(-hl + 0.004, -XS, yr0, yr1, 0.012, FL), PA, name='front_sill')
part(bm_box(-hl + 0.004, -hl + 0.12, yr0, yr1, CE, H - 0.012), PA, name='front_header')
part(bm_box(XS, XR, yr0, yr1, 0.012, FL), PA, name='rear_sill')
part(bm_box(hl - 0.12, XR, yr0, yr1, CE, H - 0.012), PA, name='rear_header')

# ---------------------------------------------------------------- walls: outer + inner corrugated sheets
for sy in (-1, 1):
    part(corrugated('X', -hl + 0.10, hl - 0.10, 0.16, H - 0.085, N_SIDE, sy * YO, DEP, sy),
         PA, smooth=50, name='side_wall_out')
    # inner face = the same profile shifted inward (inside ribs sit behind the outside valleys), facing in
    part(flip(corrugated('X', -hl + 0.10, hl - 0.10, 0.16, CE + 0.035, N_SIDE, sy * (YO - TS), DEP, sy)),
         PA, smooth=50, name='side_wall_in')
# roof (outside, as container.glb) + ceiling (inside, ribs hanging to CE)
part(corrugated_roof(-hl + 0.11, hl - 0.11, -hw + 0.06, hw - 0.06, H - 0.016, 0.014, N_ROOF), PA, smooth=50,
     name='roof')
part(corrugated_roof(-hl + 0.10, hl - 0.10, -(YI + 0.045), YI + 0.045, CE + 0.03, 0.03, N_ROOF, up=False), PA,
     smooth=50, name='ceiling')

# ---------------------------------------------------------------- plank floor (top at FL), planks along X
widths = [1.0, 0.86, 1.08, 0.94, 1.04, 0.9, 1.1, 0.96, 1.02, 0.9]
sc_ = 2 * YI / sum(widths)
c = 0.008                              # chamfer -> V-grooves between planks
fb = bmesh.new()
x0f, x1f = -XS, XS
ya = -YI
for wk in widths:
    yb = ya + wk * sc_
    prof = [(ya, FL - c), (ya + c, FL), (yb - c, FL), (yb, FL - c)]
    v0 = [fb.verts.new((x0f, y, z)) for (y, z) in prof]
    v1 = [fb.verts.new((x1f, y, z)) for (y, z) in prof]
    for i in range(3):
        fb.faces.new((v0[i], v0[i + 1], v1[i + 1], v1[i]))
    ya = yb
fb.normal_update()
for f in fb.faces:
    if f.normal.z < 0:
        f.normal_flip()
part(fb, WD, smooth=30, name='floor')
# underside plate (single down-facing quad) so the box never shows its hollow inside from below
ub = bmesh.new()
uf = ub.faces.new([ub.verts.new(p) for p in ((-hl + 0.10, -hw + 0.10, 0.02), (-hl + 0.10, hw - 0.10, 0.02),
                                             (hl - 0.10, hw - 0.10, 0.02), (hl - 0.10, -hw + 0.10, 0.02))])
ub.normal_update()
if uf.normal.z > 0:
    uf.normal_flip()
part(ub, ME, name='underside')

# ---------------------------------------------------------------- doors (+X end), built closed, then swung 270 deg
dz0, dz1 = 0.14, CE - 0.01             # leaf height range
R = 0.058                              # closed door recess behind the casting plane (as container.glb)
fx0, fx1 = hl - 0.060 - R, hl - 0.012 - R   # leaf frame depth range when closed (inner face, outer face)
LF0, LF1 = 0.004, YI + 0.015          # |y| range of a leaf when closed (centre seam .. hinge edge)
DOOR_Y = hw + 0.072                   # opened: leaf outer face plane (gear needs ~0.064 m to the wall)
DOOR_X = hl - 0.10                    # opened: hinge edge of the leaf
# pivot so that the 270 deg swing lands the leaf exactly there (see notes in the docstring)
PX = (DOOR_Y + fx1 + DOOR_X - LF1) / 2
PY = (DOOR_Y + fx1 - DOOR_X + LF1) / 2
HINGE_Z = (0.40, 1.00, 1.60, 2.20)


def swing(sy):
    P = Vector((PX, sy * PY, 0.0))
    return Matrix.Translation(P) @ Matrix.Rotation(-sy * math.pi / 2, 4, 'Z') @ Matrix.Translation(-P)


def door_part(bm, m, sy, name, **kw):
    bm_transform(bm, swing(sy))
    return part(bm, m, name=name, **kw)


for sy in (-1, 1):
    ya, yb = sy * LF0, sy * LF1
    y0, y1 = min(ya, yb), max(ya, yb)
    bw = 0.075
    door_part(bm_box(fx0, fx1, y0, y1, dz1 - bw, dz1), PA, sy, 'door_top')
    door_part(bm_box(fx0, fx1, y0, y1, dz0, dz0 + bw), PA, sy, 'door_bot')
    door_part(bm_box(fx0, fx1, y0, y0 + bw, dz0 + bw, dz1 - bw), PA, sy, 'door_side')
    door_part(bm_box(fx0, fx1, y1 - bw, y1, dz0 + bw, dz1 - bw), PA, sy, 'door_side')
    # outer corrugated panel (as container.glb) and the reversed inner panel
    door_part(corrugated('Y', y0 + 0.03, y1 - 0.03, dz0 + 0.03, dz1 - 0.03, 3, fx1 - 0.010, 0.022, 1),
              PA, sy, 'door_panel_out', smooth=50)
    door_part(flip(corrugated('Y', y0 + 0.03, y1 - 0.03, dz0 + 0.03, dz1 - 0.03, 3, fx1 - 0.020, 0.022, 1)),
              PA, sy, 'door_panel_in', smooth=50)
    # rubber seal ring on the inner face (faces outward once the door is swung open)
    gi, gw, gt = 0.012, 0.030, 0.014
    gx0, gx1 = fx0 - gt, fx0 + 0.002
    for (ga, gb, za, zb) in ((y0 + gi, y1 - gi, dz0 + gi, dz0 + gi + gw), (y0 + gi, y1 - gi, dz1 - gi - gw, dz1 - gi),
                             (y0 + gi, y0 + gi + gw, dz0 + gi + gw, dz1 - gi - gw),
                             (y1 - gi - gw, y1 - gi, dz0 + gi + gw, dz1 - gi - gw)):
        door_part(drop_faces(bm_box(gx0, gx1, ga, gb, za, zb), (1, 0, 0)), RU, sy, 'gasket')
    # hinge blades on the outer face + links to the pivot knuckles
    for hz in HINGE_Z:
        door_part(drop_faces(box_y(fx1 - 0.002, fx1 + 0.012, sy * (LF1 - 0.22), sy * (LF1 + 0.012), hz - 0.04, hz + 0.04),
                             (-1, 0, 0)), ME, sy, 'hinge_blade')
        door_part(beam((fx1 + 0.006, sy * (LF1 + 0.004), hz), (PX, sy * PY, hz), 0.014, 0.07), ME, sy, 'hinge_link')
    # locking gear (as container.glb, now between the leaf and the side wall)
    leaf = LF1 - LF0
    rx = hl + 0.016 - R
    for frac in (0.18, 0.62):
        yr = ya + sy * frac * leaf
        door_part(bm_cyl(0.0135, 0.0135, (rx, yr, dz0 + 0.02), (rx, yr, dz1 - 0.02), sides=8, caps=False), ME, sy,
                  'lockbar', smooth=70)
        for bz in (0.42, H - 0.62):   # guides
            door_part(drop_faces(bm_box(fx1 - 0.002, rx + 0.022, yr - 0.03, yr + 0.03, bz - 0.025, bz + 0.025), (-1, 0, 0)),
                      ME, sy, 'guide')
        for bz in (dz0, dz1 - 0.07):  # cams on the bar ends
            door_part(drop_faces(bm_box(fx1 - 0.002, rx + 0.02, yr - 0.024, yr + 0.024, bz, bz + 0.07), (-1, 0, 0)),
                      ME, sy, 'cam')
        hz = 1.12
        door_part(bm_box(rx - 0.02, rx + 0.03, yr - 0.025, yr + 0.025, hz - 0.045, hz + 0.045), ME, sy, 'hub')
        ye = yr + sy * 0.30
        door_part(box_y(rx + 0.012, rx + 0.032, yr, ye, hz - 0.018, hz + 0.018), ME, sy, 'handle')
        door_part(drop_faces(box_y(fx1 - 0.002, rx + 0.036, ye, ye - sy * 0.05, hz - 0.035, hz + 0.035), (-1, 0, 0)),
                  ME, sy, 'retainer')
        # cam keepers stay on the rear sill / header
        part(drop_faces(bm_box(XR - 0.002, hl - 0.010, yr - 0.04, yr + 0.04, 0.035, FL - 0.01), (-1, 0, 0)), ME,
             name='keeper_b')
        part(drop_faces(bm_box(XR - 0.002, hl - 0.010, yr - 0.04, yr + 0.04, CE + 0.012, CE + 0.092), (-1, 0, 0)), ME,
             name='keeper_t')
    # hinge knuckles at the pivot + lugs welded to the corner post
    for hz in HINGE_Z:
        part(bm_cyl(0.021, 0.021, (PX, sy * PY, hz - 0.055), (PX, sy * PY, hz + 0.055), sides=8), ME, smooth=70,
             name='knuckle')
        part(box_y(PX - 0.022, PX + 0.016, sy * (hw - 0.010), sy * PY, hz - 0.035, hz + 0.035), ME, name='lug')

ob = finalize('ContainerOpen')
report(ob, 'container_open', 3200)
export('container_open')

# ---------------------------------------------------------------- collider boxes (Blender min/max -> Godot centre/size)
boxes = []


def add(name, x0, x1, y0, y1, z0, z1):
    cc = ((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
    s = (x1 - x0, y1 - y0, z1 - z0)
    boxes.append(dict(name=name, center=[round(cc[0], 4), round(cc[2], 4), round(-cc[1], 4)],
                      size=[round(s[0], 4), round(s[2], 4), round(s[1], 4)]))


DOOR_OUT = DOOR_Y + (fx1 - fx0) + gt    # outermost face of an opened leaf (seal ring)
add('side_wall_+Y', -hl, hl, YI, hw, 0.0, H)
add('side_wall_-Y', -hl, hl, -hw, -YI, 0.0, H)
add('roof_slab', -hl, hl, -YI, YI, CE, H)
add('floor_slab', -hl, hl, -YI, YI, 0.0, FL)
add('door_leaf_+Y', DOOR_X - (LF1 - LF0), hl, hw, DOOR_OUT, dz0, dz1)
add('door_leaf_-Y', DOOR_X - (LF1 - LF0), hl, -DOOR_OUT, -hw, dz0, dz1)
with open(os.path.join(OUT_DIR, 'container_open_colliders.json'), 'w') as f:
    json.dump(dict(collision_boxes=boxes), f, indent=1)
print('pivot', round(PX, 4), round(PY, 4), 'collision boxes:', len(boxes))
