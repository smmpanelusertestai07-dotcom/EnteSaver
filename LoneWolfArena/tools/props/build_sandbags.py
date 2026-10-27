"""sandbags.glb - curved sandbag wall 2.5 m wide x 0.9 m tall, convex toward +Y. Origin bottom centre of bbox."""
import sys
sys.path.insert(0, '/root/work/tools/props')
from lib import *
reset()
SB = mat('Sandbag', '#b09a6c', rough=0.92)
random.seed(5)
# pillow template: subdivided cube
tmp = bm_to_obj(bm_box(-0.5, 0.5, -0.5, 0.5, -0.5, 0.5), 'tmpl', None)
m = tmp.modifiers.new('ss', 'SUBSURF'); m.levels = 1; m.render_levels = 1
apply_mods(tmp)
tbm = bmesh.new(); tbm.from_mesh(tmp.data)
bpy.data.objects.remove(tmp)
for v in tbm.verts:     # flatten top/bottom into a pillow
    v.co.z = math.copysign(min(abs(v.co.z) * 1.25, 0.5), v.co.z) if abs(v.co.z) > 0.3 else v.co.z
    v.co.x *= 1.0 + 0.10 * (1 - abs(v.co.z) * 2)
BL, BD, BH = 0.58, 0.31, 0.165     # bag length, depth, height
R, chord = 3.25, 2.5
half_ang = math.asin((chord / 2 - 0.045) / R)
arc = 2 * R * half_ang
layers = 6
dz = (0.90 - BH) / (layers - 1)
bags = []
for L in range(layers):
    n = 5 if L % 2 == 0 else 4
    if L == layers - 1:
        n = 4
    span = arc - (0.0 if L % 2 == 0 else BL * 0.55)
    step = span / n
    setback = -0.022 * L
    for i in range(n):
        s = -span / 2 + step * (i + 0.5) + random.uniform(-0.02, 0.02)
        phi = s / R
        x = R * math.sin(phi)
        y = R * math.cos(phi) - R + setback
        bm = tbm.copy()
        sc = Matrix.Diagonal((BL * random.uniform(0.95, 1.04), BD * random.uniform(0.95, 1.05), BH * random.uniform(0.92, 1.05), 1))
        rot = Matrix.Rotation(-phi + math.radians(random.uniform(-4, 4)), 4, 'Z') @ Matrix.Rotation(math.radians(random.uniform(-3, 3)), 4, 'X')
        bm_transform(bm, Matrix.Translation((x, y, BH / 2 * 0.97 + L * dz)) @ rot @ sc)
        bags.append(bm)
allbm = bm_merge(bags)
part(allbm, SB, smooth=70, name='bags')
ob = PARTS[0]
# centre bbox on X/Y, bottom at z=0
vs = [v.co for v in ob.data.vertices]
cx = (min(v.x for v in vs) + max(v.x for v in vs)) / 2
cy = (min(v.y for v in vs) + max(v.y for v in vs)) / 2
zmin = min(v.z for v in vs)
ob.data.transform(Matrix.Translation((-cx, -cy, -zmin)))
ob = finalize('Sandbags')
report(ob, 'sandbags', 1500)
export('sandbags')
