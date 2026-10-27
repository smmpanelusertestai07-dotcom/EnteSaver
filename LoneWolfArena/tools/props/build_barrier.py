"""barrier.glb - concrete New-Jersey barrier 3.0 x 0.6 x 0.81 m (length X). Origin bottom centre."""
import sys
sys.path.insert(0, '/root/work/tools/props')
from lib import *
reset()
CO = mat('Concrete', '#a8a59d', metallic=0.0, rough=0.9)
ST = mat('Stripe', '#e8b417', metallic=0.0, rough=0.6)
L = 3.0
# half profile (y, z) from bottom outer corner to top centre; stripe band on the upper face
half = [(0.300, 0.0), (0.300, 0.075), (0.1214, 0.330), (0.104, 0.50), (0.093, 0.61), (0.078, 0.765), (0.060, 0.81)]
prof = half + [(-y, z) for (y, z) in reversed(half)]
def section(z_floor=None):
    return prof
def body(x0, x1, cut_bottom=0.0):
    pts = prof if cut_bottom <= 0 else [(y, max(z, cut_bottom)) for (y, z) in prof]
    if cut_bottom > 0:   # drop duplicate bottom points
        pts = [(0.300 - (0.300 - 0.1214) * (cut_bottom - 0.075) / (0.330 - 0.075), cut_bottom)] + prof[2:-2] + \
              [(-(0.300 - (0.300 - 0.1214) * (cut_bottom - 0.075) / (0.330 - 0.075)), cut_bottom)]
    bm = bm_prism(pts, 'X', x0, x1)
    # stripe faces: side faces between z 0.50 and 0.61
    bm.normal_update()
    for f in bm.faces:
        c = f.calc_center_median()
        if abs(f.normal.x) < 0.5 and 0.50 < c.z < 0.61:
            f.material_index = 1
    return bm
segs = [(-1.5, -0.95, 0), (-0.95, -0.55, 0.12), (-0.55, 0.55, 0), (0.55, 0.95, 0.12), (0.95, 1.5, 0)]
for (x0, x1, cb) in segs:
    bm = body(x0, x1, cb)
    if cb > 0:   # interior caps of the slot pieces are hidden by neighbours
        bm.normal_update()
        bmesh.ops.delete(bm, geom=[f for f in bm.faces if abs(f.normal.x) > 0.9], context='FACES')
    part(bm, [CO, ST], name='seg')
ob = finalize('Barrier')
report(ob, 'barrier', 300)
export('barrier')
