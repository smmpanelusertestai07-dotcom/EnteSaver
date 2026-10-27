"""watchtower.glb - wooden lookout tower, 3x3 m platform at 4 m, railing, 4 legs, ladder on +Y, metal roof.
Origin at the ground centre of the tower."""
import sys
sys.path.insert(0, '/root/work/tools/props')
from lib import *
reset()
WD = mat('Wood', '#8a6038', metallic=0.0, rough=0.8)
ME = mat('Metal', '#6c7177', metallic=0.75, rough=0.45)


def beam(p0, p1, w, d, roll=0.0):
    p0, p1 = Vector(p0), Vector(p1)
    v = p1 - p0
    bm = bm_box(-w / 2, w / 2, -d / 2, d / 2, 0.0, v.length)
    q = v.to_track_quat('Z', 'Y')
    bm_transform(bm, Matrix.Translation(p0) @ q.to_matrix().to_4x4() @ Matrix.Rotation(roll, 4, 'Z'))
    return bm


PF = 4.0          # platform top
B0, B1 = 1.72, 1.40   # leg half-spread at ground / at platform
corners = [(1, 1), (-1, 1), (-1, -1), (1, -1)]
def leg_at(sx, sy, z):
    s = B0 + (B1 - B0) * (z / PF)
    return Vector((sx * s, sy * s, z))
for sx, sy in corners:
    part(beam(leg_at(sx, sy, 0), leg_at(sx, sy, PF - 0.12), 0.20, 0.20), WD, bevel=0.015, name='leg')
    part(beam((sx * B1, sy * B1, PF - 0.12), (sx * B1, sy * B1, 6.25), 0.16, 0.16), WD, bevel=0.012, name='post')
# girts + X braces on each side
for i in range(4):
    (ax, ay), (bx, by) = corners[i], corners[(i + 1) % 4]
    for z in (1.9, PF - 0.24):
        part(beam(leg_at(ax, ay, z), leg_at(bx, by, z), 0.12, 0.14), WD, name='girt')
    part(beam(leg_at(ax, ay, 0.35), leg_at(bx, by, 1.75), 0.09, 0.11), WD, name='brace')
    part(beam(leg_at(bx, by, 0.35), leg_at(ax, ay, 1.75), 0.09, 0.11), WD, name='brace')
    part(beam(leg_at(ax, ay, 2.05), leg_at(bx, by, PF - 0.40), 0.09, 0.11), WD, name='brace')
    part(beam(leg_at(bx, by, 2.05), leg_at(ax, ay, PF - 0.40), 0.09, 0.11), WD, name='brace')
# platform: joists + planks
for y in (-0.9, 0.0, 0.9):
    part(bm_box(-1.5, 1.5, y - 0.07, y + 0.07, PF - 0.26, PF - 0.11), WD, name='joist')
np_ = 7
pw = 3.0 / np_
for k in range(np_):
    x0 = -1.5 + k * pw
    part(bm_box(x0 + 0.008, x0 + pw - 0.008, -1.5, 1.5, PF - 0.11, PF), WD, bevel=0.01, name='plank')
# railing (opening on +Y for the ladder)
for z, hgt in ((PF + 1.0, 0.10), (PF + 0.52, 0.08)):
    part(bm_box(-1.48, 1.48, -1.48, -1.38, z - hgt, z), WD, bevel=0.01, name='rail')
    part(bm_box(-1.48, -1.38, -1.40, 1.40, z - hgt, z), WD, bevel=0.01, name='rail')
    part(bm_box(1.38, 1.48, -1.40, 1.40, z - hgt, z), WD, bevel=0.01, name='rail')
    part(bm_box(-1.40, -0.42, 1.38, 1.48, z - hgt, z), WD, bevel=0.01, name='rail')
    part(bm_box(0.42, 1.40, 1.38, 1.48, z - hgt, z), WD, bevel=0.01, name='rail')
for (x, y) in ((0, -1.43), (-1.43, 0), (1.43, 0), (-0.42, 1.43), (0.42, 1.43)):
    part(bm_box(x - 0.05, x + 0.05, y - 0.05, y + 0.05, PF, PF + 1.0), WD, name='rpost')
# kick boards
part(bm_box(-1.48, 1.48, -1.49, -1.43, PF, PF + 0.16), WD, name='kick')
part(bm_box(-1.49, -1.43, -1.43, 1.43, PF, PF + 0.16), WD, name='kick')
part(bm_box(1.43, 1.49, -1.43, 1.43, PF, PF + 0.16), WD, name='kick')
# roof: ring beams + metal pyramid
for i in range(4):
    (ax, ay), (bx, by) = corners[i], corners[(i + 1) % 4]
    part(beam((ax * B1, ay * B1, 6.18), (bx * B1, by * B1, 6.18), 0.12, 0.14), WD, name='rbeam')
RS = 1.85
part(bm_box(-RS, RS, -RS, RS, 6.25, 6.31), ME, bevel=0.01, name='eave')
bm = bmesh.new()
vs = [bm.verts.new((sx * RS, sy * RS, 6.31)) for sx, sy in corners]
ap = bm.verts.new((0, 0, 7.15))
for i in range(4):
    bm.faces.new((vs[i], vs[(i + 1) % 4], ap))
bm.normal_update()
for f in bm.faces:
    if f.normal.z < 0:
        f.normal_flip()
part(bm, ME, name='roof')
part(bm_cyl(0.05, 0.0, (0, 0, 7.10), (0, 0, 7.35), sides=6), ME, name='finial')
# ladder (metal) on +Y
yb, yt = 2.20, 1.53
for x in (-0.26, 0.26):
    part(beam((x, yb, 0.0), (x, yt, PF), 0.05, 0.07), ME, name='lrail')
    part(beam((x, yt, PF - 0.02), (x, yt + 0.03, PF + 0.95), 0.05, 0.07), ME, name='grab')
z = 0.30
while z < PF - 0.1:
    y = yb + (yt - yb) * z / PF
    part(bm_cyl(0.017, 0.017, (-0.26, y, z), (0.26, y, z), sides=6, caps=False), ME, name='rung')
    z += 0.30
ob = finalize('Watchtower')
for v in ob.data.vertices:      # cut tilted leg / ladder feet flat on the ground
    if v.co.z < 0.0:
        v.co.z = 0.0
ob.data.update()
report(ob, 'watchtower', 2000)
export('watchtower')
