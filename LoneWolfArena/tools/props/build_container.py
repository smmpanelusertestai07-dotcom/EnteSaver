"""container.glb - 20 ft ISO container 6.058 x 2.438 x 2.591 m, length along X, doors at +X.
Origin bottom centre."""
import sys
sys.path.insert(0, '/root/work/tools/props')
from lib import *

reset()
PA = mat('Paint', '#cfcfcc', metallic=0.05, rough=0.6)
ME = mat('Metal', '#5f6266', metallic=0.8, rough=0.45)
RU = mat('Rubber', '#191919', metallic=0.0, rough=0.9)

L, W, H = 6.058, 2.438, 2.591
hl, hw = L / 2, W / 2
CX, CY, CZ = 0.178, 0.162, 0.118     # corner casting size


def corrugated(axis_len, a0, a1, z0, z1, n, plane, outer, depth, sign, fo=0.27, s=0.23):
    """Single-sided trapezoid corrugation. Profile runs along `axis_len` ('X' or 'Y') from a0..a1,
    the wall plane is at `outer` (coordinate on the other horizontal axis), valleys at outer - sign*depth.
    sign = +1 if the wall faces +normal axis."""
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
        f = bm.faces.new((a0v, b0v, b1v, a1v))
    bm.normal_update()
    # orient faces to the desired outward direction
    want = Vector((0, sign, 0)) if axis_len == 'X' else Vector((sign, 0, 0))
    for f in bm.faces:
        if f.normal.dot(want) < 0:
            f.normal_flip()
    return bm


def corrugated_roof(x0, x1, y0, y1, ztop, depth, n):
    p = (x1 - x0) / n
    xs = []
    for k in range(n):
        a = x0 + k * p
        xs += [(a, 0), (a + 0.3 * p, 0), (a + 0.5 * p, 1), (a + 0.8 * p, 1)]
    xs.append((x1, 0))
    bm = bmesh.new()
    cols = [(bm.verts.new((a, y0, ztop - depth * i)), bm.verts.new((a, y1, ztop - depth * i))) for a, i in xs]
    for (a0v, a1v), (b0v, b1v) in zip(cols[:-1], cols[1:]):
        bm.faces.new((a0v, b0v, b1v, a1v))
    bm.normal_update()
    for f in bm.faces:
        if f.normal.z < 0:
            f.normal_flip()
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
    res = bmesh.ops.inset_individual(bm, faces=faces, thickness=0.036, depth=0.0)
    for f in faces:
        nrm = f.normal.copy()
        r = bmesh.ops.extrude_discrete_faces(bm, faces=[f])
        for nf in r['faces']:
            nf.material_index = 1
            for v in nf.verts:
                v.co -= nrm * 0.035
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
    y_out = sy * (hw - 0.005)
    y_in = sy * (hw - 0.105)
    cut = []
    for xc in (-1.025, 1.025):   # forklift pockets (recessed openings in the bottom rail)
        ya, yb = sy * (hw - 0.05), sy * (hw + 0.06)
        cut.append((bm_box(xc - 0.18, xc + 0.18, min(ya, yb), max(ya, yb), 0.03, 0.145), ME))
    part(bm_box(xr0, xr1, min(y_out, y_in), max(y_out, y_in), 0.012, 0.16), PA, name='bottom_rail', cutters=cut)
    part(bm_box(xr0, xr1, min(sy * (hw - 0.004), sy * (hw - 0.068)), max(sy * (hw - 0.004), sy * (hw - 0.068)),
                H - 0.085, H - 0.012), PA, name='top_rail')
    for sx in (-1, 1):   # corner posts
        part(bm_box(min(sx * (hl - 0.004), sx * (hl - 0.150)), max(sx * (hl - 0.004), sx * (hl - 0.150)),
                    min(sy * (hw - 0.004), sy * (hw - 0.150)), max(sy * (hw - 0.004), sy * (hw - 0.150)),
                    CZ - 0.01, H - CZ + 0.01), PA, name='post')
yr0, yr1 = -hw + CY - 0.01, hw - CY + 0.01
# front (-X) end rails
part(bm_box(-hl + 0.004, -hl + 0.12, yr0, yr1, 0.012, 0.16), PA, name='front_sill')
part(bm_box(-hl + 0.004, -hl + 0.10, yr0, yr1, H - 0.10, H - 0.012), PA, name='front_header')
# rear (+X) door sill / header
part(bm_box(hl - 0.12, hl - 0.004, yr0, yr1, 0.012, 0.15), PA, name='door_sill')
part(bm_box(hl - 0.12, hl - 0.004, yr0, yr1, H - 0.20, H - 0.012), PA, name='door_header')

# ---------------------------------------------------------------- corrugated walls + roof
for sy in (-1, 1):
    part(corrugated('X', -hl + 0.10, hl - 0.10, 0.16, H - 0.085, 21, 'side', sy * (hw - 0.012), 0.040, sy),
         PA, smooth=50, name='side_wall')
part(corrugated('Y', -hw + 0.10, hw - 0.10, 0.16, H - 0.10, 8, 'end', -(hl - 0.012), 0.040, -1),
     PA, smooth=50, name='front_wall')
part(corrugated_roof(-hl + 0.09, hl - 0.11, -hw + 0.06, hw - 0.06, H - 0.016, 0.014, 13), PA, smooth=50,
     name='roof')

# ---------------------------------------------------------------- doors (+X end)
dz0, dz1 = 0.15, H - 0.20
R = 0.058                              # door recess behind the casting plane
fx0, fx1 = hl - 0.060 - R, hl - 0.012 - R      # door frame depth range
for sy in (-1, 1):
    ya, yb = sy * 0.004, sy * (hw - 0.150)
    y0, y1 = min(ya, yb), max(ya, yb)
    bw = 0.075
    part(bm_box(fx0, fx1, y0, y1, dz1 - bw, dz1), PA, name='door_top')
    part(bm_box(fx0, fx1, y0, y1, dz0, dz0 + bw), PA, name='door_bot')
    part(bm_box(fx0, fx1, y0, y0 + bw, dz0 + bw, dz1 - bw), PA, name='door_side')
    part(bm_box(fx0, fx1, y1 - bw, y1, dz0 + bw, dz1 - bw), PA, name='door_side')
    part(corrugated('Y', y0 + 0.03, y1 - 0.03, dz0 + 0.03, dz1 - 0.03, 3, 'door', hl - 0.022 - R, 0.022, 1),
         PA, smooth=50, name='door_panel')
    # hinges on the outer (hinge) edge
    for hz in (0.42, 0.98, 1.56, 2.12):
        hy = sy * (hw - 0.150)
        part(bm_box(hl - 0.012 - R, hl + 0.018 - R, min(hy - sy * 0.03, hy + sy * 0.07), max(hy - sy * 0.03, hy + sy * 0.07),
                    hz - 0.05, hz + 0.05), ME, name='hinge')
    # rubber gasket on the hinge side
    part(bm_box(hl - 0.05 - R, hl - 0.010 - R, min(yb, yb + sy * 0.012), max(yb, yb + sy * 0.012), dz0, dz1), RU,
         name='gasket_side')
    # lock bars
    leaf = abs(yb - ya)
    for frac in (0.18, 0.62):
        yr = ya + sy * frac * leaf
        rx = hl + 0.016 - R
        part(bm_cyl(0.0135, 0.0135, (rx, yr, dz0), (rx, yr, dz1), sides=8, caps=False), ME, name='lockbar')
        for bz in (0.42, H - 0.62):   # guides
            part(bm_box(hl - 0.012 - R, rx + 0.022, yr - 0.03, yr + 0.03, bz - 0.025, bz + 0.025), ME, name='guide')
        part(bm_box(hl - 0.075, rx + 0.026, yr - 0.04, yr + 0.04, dz0, dz0 + 0.085), ME, name='keeper_b')
        part(bm_box(hl - 0.075, rx + 0.026, yr - 0.04, yr + 0.04, dz1 - 0.085, dz1), ME, name='keeper_t')
        # handle: hub + bar pointing to the hinge side + retainer
        hz = 1.12
        part(bm_box(rx - 0.02, rx + 0.03, yr - 0.025, yr + 0.025, hz - 0.045, hz + 0.045), ME, name='hub')
        ye = yr + sy * 0.30
        part(bm_box(rx + 0.012, rx + 0.032, min(yr, ye), max(yr, ye), hz - 0.018, hz + 0.018), ME, name='handle')
        part(bm_box(hl - 0.012 - R, rx + 0.036, min(ye, ye - sy * 0.05), max(ye, ye - sy * 0.05), hz - 0.035, hz + 0.035),
             ME, name='retainer')
# centre seam gasket
part(bm_box(hl - 0.05 - R, hl - 0.010 - R, -0.008, 0.008, dz0, dz1), RU, name='gasket_mid')
# CSC plate on the left door
part(bm_box(hl - 0.024 - R, hl - 0.010 - R, -0.56, -0.30, 1.62, 1.84), ME, name='plate')

ob = finalize('Container')
report(ob, 'container', 2000)
export('container')
