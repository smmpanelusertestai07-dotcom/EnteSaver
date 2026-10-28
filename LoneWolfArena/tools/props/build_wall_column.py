"""wall_column.glb - steel H-beam column 0.32 x 0.32 m, 9.0 m tall, all 'Steel'.
Flanges face front/back (Blender +Y/-Y = Godot -Z/+Z), web along Y, open channels face +-X.
Base plate 0.52 x 0.44 m with 4 anchor nuts and 4 stiffener fins, cap plate on top.
Origin: bottom centre (column axis, Z = 0 = floor)."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *

reset()
ST = mat('Steel', '#474c54', metallic=0.5, rough=0.45)

H = 9.0
B = 0.32                  # flange width (x) and section depth (y)
TF, TW = 0.028, 0.018     # flange / web thickness
BP = (0.52, 0.44, 0.035)  # base plate x, y, thickness
CP = (0.36, 0.36, 0.03)   # cap plate
hb, tf, tw = B / 2, TF, TW / 2

DIRS = {'+x': Vector((1, 0, 0)), '-x': Vector((-1, 0, 0)), '+y': Vector((0, 1, 0)),
        '-y': Vector((0, -1, 0)), '+z': Vector((0, 0, 1)), '-z': Vector((0, 0, -1))}


def drop_faces(bm, drop):
    bm.normal_update()
    dels = [f for f in bm.faces if any(f.normal.dot(DIRS[d]) > 0.95 for d in drop)]
    bmesh.ops.delete(bm, geom=dels, context='FACES')
    return bm


# H section (x, y), counter-clockwise
sec = [(-hb, -hb), (hb, -hb), (hb, -hb + tf), (tw, -hb + tf), (tw, hb - tf), (hb, hb - tf),
       (hb, hb), (-hb, hb), (-hb, hb - tf), (-tw, hb - tf), (-tw, -hb + tf), (-hb, -hb + tf)]
z0, z1 = BP[2], H - CP[2]
part(drop_faces(bm_prism(sec, 'Z', z0, z1), ('-z', '+z')), ST, name='hbeam')
# base + cap plates
part(drop_faces(bm_box(-BP[0] / 2, BP[0] / 2, -BP[1] / 2, BP[1] / 2, 0.0, BP[2]), ('-z',)), ST, name='base_plate')
part(bm_box(-CP[0] / 2, CP[0] / 2, -CP[1] / 2, CP[1] / 2, H - CP[2], H), ST, name='cap_plate')

# stiffener fins: in the web plane beyond both flanges (+-Y) and across both channels (+-X)
FT = 0.016                # fin thickness


def fin(axis, sign):
    """Truncated triangular fin standing on the base plate; profile in (r, z), r = distance from the axis."""
    if axis == 'Y':
        r0, r1, top = hb, BP[1] / 2 - 0.01, 0.20
    else:
        r0, r1, top = tw, BP[0] / 2 - 0.012, 0.26
    prof = [(r0, BP[2]), (r1, BP[2]), (r1, BP[2] + 0.035), (r0, top)]
    if axis == 'Y':
        bm = bm_prism([(sign * r, z) for r, z in prof], 'X', -FT / 2, FT / 2)
        drop = ('-z', '-y' if sign > 0 else '+y')
    else:
        bm = bm_prism([(sign * r, z) for r, z in prof], 'Y', -FT / 2, FT / 2)
        drop = ('-z', '-x' if sign > 0 else '+x')
    return drop_faces(bm, drop)


for axis in ('X', 'Y'):
    for s in (-1, 1):
        part(fin(axis, s), ST, name='fin')

# anchor nuts (square, 4 sides) in the plate corners beyond the flange tips
for sx in (-1, 1):
    for sy in (-1, 1):
        cx, cy = sx * 0.212, sy * 0.15
        part(drop_faces(bm_box(cx - 0.024, cx + 0.024, cy - 0.024, cy + 0.024, BP[2], BP[2] + 0.03), ('-z',)),
             ST, name='nut')

ob = finalize('WallColumn')
report(ob, 'wall_column', 120)
export('wall_column')
