"""barrel.glb - 200 l steel drum 0.585 x 0.88 m, two rolling ribs, rolled rims, two bung caps.
Paint = recolourable body, Metal = rims and caps. Origin bottom centre."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *

reset()
PA = mat('Paint', '#2b5fa8', metallic=0.35, rough=0.5)
ME = mat('Metal', '#8a9098', metallic=0.8, rough=0.4)
R, H, S = 0.585 / 2, 0.88, 16
part(bm_cyl(R, R, (0, 0, 0.025), (0, 0, H - 0.025), sides=S, caps=True), PA, name='body')
part(bm_cyl(R + 0.01, R + 0.01, (0, 0, 0.0), (0, 0, 0.035), sides=S, caps=True), ME, name='rim_b')
part(bm_cyl(R + 0.01, R + 0.006, (0, 0, H - 0.035), (0, 0, H), sides=S, caps=True), ME, name='rim_t')
for z in (H * 0.34, H * 0.66):
    part(bm_cyl(R + 0.013, R + 0.013, (0, 0, z - 0.014), (0, 0, z + 0.014), sides=S, caps=False), PA, name='rib')
for (x, y, r) in ((0.15, 0.02, 0.034), (-0.16, 0.06, 0.022)):
    part(bm_cyl(r, r * 0.9, (x, y, H - 0.004), (x, y, H + 0.014), sides=8, caps=True), ME, name='bung')
ob = finalize('Barrel')
report(ob, 'barrel', 360)
export('barrel')
