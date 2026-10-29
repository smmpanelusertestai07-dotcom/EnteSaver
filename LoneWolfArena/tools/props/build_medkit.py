"""medkit.glb - first-aid case 0.32 x 0.22 x 0.12 m (X x Y x Z). Origin bottom centre, handle on +Y."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *
reset()
WH = mat('MedWhite', '#ececea', metallic=0.0, rough=0.45)
RD = mat('MedRed', '#d42a2a', metallic=0.0, rough=0.5)
PO = mat('Polymer', '#2a2b2e', metallic=0.0, rough=0.6)
X, Y, Z = 0.32, 0.22, 0.12
# lower shell, seam groove, lid
part(bm_box(-X / 2, X / 2, -Y / 2, Y / 2, 0.0, 0.074), WH, bevel=0.014, segs=2, name='shell')
part(bm_box(-X / 2 + 0.005, X / 2 - 0.005, -Y / 2 + 0.005, Y / 2 - 0.005, 0.06, 0.09), PO, name='seam')
part(bm_box(-X / 2, X / 2, -Y / 2, Y / 2, 0.079, Z), WH, bevel=0.014, segs=2, name='lid')
# red cross on the lid (raised) and on the front (+Y)
c = 0.026; a = 0.075
cross = [(c, a), (c, c), (a, c), (a, -c), (c, -c), (c, -a), (-c, -a), (-c, -c), (-a, -c), (-a, c), (-c, c), (-c, a)]
part(bm_prism(cross, 'Z', Z - 0.002, Z + 0.003), RD, name='cross_top')
c2, a2 = 0.010, 0.028
cross2 = [(c2, a2), (c2, c2), (a2, c2), (a2, -c2), (c2, -c2), (c2, -a2), (-c2, -a2), (-c2, -c2), (-a2, -c2), (-a2, c2), (-c2, c2), (-c2, a2)]
for sx in (-1, 1):   # small crosses on the short ends
    pts = [(y, 0.06 + z) for (y, z) in cross2]
    part(bm_prism(pts, 'X', sx * X / 2 - 0.002 if sx > 0 else -X / 2 - 0.003, X / 2 + 0.003 if sx > 0 else -X / 2 + 0.002), RD, name='cross_end')
# handle on the front (+Y) side + latches
part(bm_box(-0.075, -0.055, Y / 2 - 0.004, Y / 2 + 0.020, 0.052, 0.084), PO, bevel=0.004, name='hmount')
part(bm_box(0.055, 0.075, Y / 2 - 0.004, Y / 2 + 0.020, 0.052, 0.084), PO, bevel=0.004, name='hmount')
part(bm_box(-0.075, 0.075, Y / 2 + 0.014, Y / 2 + 0.030, 0.056, 0.080), PO, bevel=0.005, name='handle')
for sx in (-1, 1):
    part(bm_box(sx * 0.125 - 0.016, sx * 0.125 + 0.016, Y / 2 - 0.003, Y / 2 + 0.008, 0.050, 0.098), RD, bevel=0.003, name='latch')
ob = finalize('Medkit')
report(ob, 'medkit', 600)
export('medkit')
