"""rock.glb - low-poly boulder ~1.6 m. Origin bottom centre."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *
reset()
RK = mat('Rock', '#7f7b74', metallic=0.0, rough=0.85)
random.seed(7)
bm = bmesh.new()
bmesh.ops.create_icosphere(bm, subdivisions=3, radius=1.0)
from mathutils import noise
for v in bm.verts:
    p = v.co.copy()
    n = noise.fractal(p * 1.3 + Vector((3.1, 1.7, 0.4)), 0.6, 2.0, 3)
    p *= 1.0 + 0.22 * n
    v.co = Vector((p.x * 0.74, p.y * 0.60, p.z * 0.58))
# flatten the bottom and sit on the ground
for v in bm.verts:
    if v.co.z < -0.30:
        v.co.z = -0.30 + (v.co.z + 0.30) * 0.15
bmesh.ops.dissolve_degenerate(bm, dist=0.001, edges=bm.edges)
ob = bm_to_obj(bm, 'rock', RK)
m = ob.modifiers.new('dec', 'DECIMATE'); m.ratio = 0.86
apply_mods(ob)
zmin = min(v.co.z for v in ob.data.vertices)
ob.data.transform(Matrix.Translation((0, 0, -zmin)))
shade(ob, angle=1, weighted=False)
ob = finalize('Rock', [ob])
report(ob, 'rock', 300)
export('rock')
