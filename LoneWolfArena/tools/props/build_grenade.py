"""grenade.glb - frag grenade ~0.11 m. Origin bottom centre, lever (spoon) on +Y, ring on +X."""
import sys
sys.path.insert(0, '/root/work/tools/props')
from lib import *
reset()
OL = mat('GrenadeBody', '#4f5f32', metallic=0.1, rough=0.6)
ME = mat('Metal', '#9a9ea3', metallic=0.85, rough=0.35)
# body: egg-shaped sphere with shallow pineapple segmentation
bm = bmesh.new()
bmesh.ops.create_uvsphere(bm, u_segments=12, v_segments=9, radius=1.0)
for v in bm.verts:
    x, y, z = v.co
    ring = round((math.asin(max(-1, min(1, z))) / (math.pi / 9)))     # ring index
    seg = round(math.atan2(y, x) / (2 * math.pi / 12))
    k = 1.0
    if abs(z) < 0.95:
        k *= 0.94 if (ring % 2 == 0) else 1.0
        k *= 0.96 if (seg % 2 == 0) else 1.0
    v.co = Vector((x * 0.031 * k, y * 0.031 * k, 0.0385 + z * 0.0385 * (0.97 + 0.03 * k)))
part(bm, OL, smooth=70, name='body')
# neck + fuze
part(bm_cyl(0.0125, 0.0115, (0, 0, 0.070), (0, 0, 0.083), sides=10), ME, name='neck')
part(bm_cyl(0.0105, 0.0105, (0, 0, 0.082), (0, 0, 0.096), sides=10), ME, name='fuze')
part(bm_cyl(0.0085, 0.0070, (0, 0, 0.095), (0, 0, 0.101), sides=10), ME, name='fuzetop')
# spoon / lever: strip hugging the body on +Y
pts = [(0.000, 0.099), (0.012, 0.099), (0.017, 0.093), (0.024, 0.080), (0.032, 0.062), (0.036, 0.045), (0.036, 0.030),
       (0.033, 0.022), (0.030, 0.024), (0.032, 0.032), (0.032, 0.045), (0.028, 0.061), (0.020, 0.077), (0.013, 0.090),
       (0.009, 0.094), (0.000, 0.094)]
part(bm_prism(pts, 'X', -0.0075, 0.0075), ME, name='spoon')
# pin + pull ring on +X
part(bm_cyl(0.0018, 0.0018, (-0.004, 0.0, 0.090), (0.022, 0.0, 0.090), sides=6), ME, name='pin')
ring = []
R, r = 0.0115, 0.0019
for i in range(8):
    a = 2 * math.pi * i / 8
    ring.append((0.022 + R + R * math.cos(a + math.pi), 0.0, 0.090 + R * math.sin(a + math.pi)))
ring.append(ring[0])
part(bm_tube(ring[:-1] + [ring[0]], r, sides=4, caps=False), ME, name='ring')
ob = finalize('Grenade')
report(ob, 'grenade', 500)
export('grenade')
