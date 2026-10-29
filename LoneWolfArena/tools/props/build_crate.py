"""crate.glb - 1.2 m wooden crate, plank frame + cross braces. Origin bottom centre."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *
reset()
WD = mat('Wood', '#a5743f', metallic=0.0, rough=0.7)
WK = mat('WoodDark', '#6b4524', metallic=0.0, rough=0.75)
S = 1.2; h = S / 2; t = 0.11; pr = 0.02          # frame plank width, frame protrusion over the core
c = h - pr                                         # core half size
part(bm_box(-c, c, -c, c, 0.0, S - pr), WK, name='core')


def raised_strip(axis, sign, a0, a1, lift=0.007):
    """Raised plank strip on a core face (5 faces, no back): horizontal planks on sides, along X on top."""
    if axis == 'Z':
        bm = bm_box(a0, a1, -c, c, S - pr - 0.001, S - pr + lift)
    elif axis == 'X':
        bm = bm_box(min(sign * (c - 0.001), sign * (c + lift)), max(sign * (c - 0.001), sign * (c + lift)), -c, c, a0, a1)
    else:
        bm = bm_box(-c, c, min(sign * (c - 0.001), sign * (c + lift)), max(sign * (c - 0.001), sign * (c + lift)), a0, a1)
    bm.normal_update()
    out = Vector((sign, 0, 0)) if axis == 'X' else (Vector((0, sign, 0)) if axis == 'Y' else Vector((0, 0, 1)))
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.normal.dot(out) < -0.9], context='FACES')
    return bm


n = 6
for axis, sign in (('X', 1), ('X', -1), ('Y', 1), ('Y', -1), ('Z', 1)):
    for i in range(1, n, 2):
        if axis == 'Z':
            a0 = -c + 2 * c * i / n; a1 = -c + 2 * c * (i + 1) / n
        else:
            a0 = 2 * c * i / n; a1 = 2 * c * (i + 1) / n
        part(raised_strip(axis, sign, a0 + 0.004, a1 - 0.004), WK, name='strip')
# frame planks along the 12 edges
for sy in (-1, 1):
    for (z0, z1) in ((0.0, t), (S - t, S)):
        part(bm_box(-h, h, min(sy * h, sy * (h - t)), max(sy * h, sy * (h - t)), z0, z1), WD, name='frame_x')
for sx in (-1, 1):
    for (z0, z1) in ((0.0, t), (S - t, S)):
        part(bm_box(min(sx * (h - 0.003), sx * (h - t)), max(sx * (h - 0.003), sx * (h - t)), -h + 0.003, h - 0.003, z0 + 0.002, z1 - 0.002), WD, name='frame_y')
for sx in (-1, 1):
    for sy in (-1, 1):
        part(bm_box(min(sx * (h - 0.002), sx * (h - t)), max(sx * (h - 0.002), sx * (h - t)),
                    min(sy * (h - 0.002), sy * (h - t)), max(sy * (h - 0.002), sy * (h - t)), t - 0.002, S - t + 0.002), WD, name='frame_z')
# diagonal braces on the 4 sides (corner to corner inside the frame)
span = S - 2 * t
Lb = math.hypot(span, span) - 0.05
ang = math.atan2(span, span)
for k in range(4):
    bm = bm_box(-Lb / 2, Lb / 2, -0.0, pr - 0.002, -0.05, 0.05)
    bm.normal_update()
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if f.normal.y < -0.9], context='FACES')
    bm_transform(bm, Matrix.Rotation(ang if k % 2 == 0 else -ang, 4, 'Y'))       # tilt in the XZ plane
    bm_transform(bm, Matrix.Translation((0, c, h)))                              # onto the +Y face
    bm_transform(bm, Matrix.Rotation(k * math.pi / 2, 4, 'Z'))
    part(bm, WD, name='brace')
ob = finalize('Crate')
report(ob, 'crate', 400)
export('crate')
