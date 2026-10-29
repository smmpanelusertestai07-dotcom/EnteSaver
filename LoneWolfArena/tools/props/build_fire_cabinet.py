"""fire_cabinet.glb - red wall-mounted fire hose cabinet (0.75 w x 0.95 h x 0.22 d, bottom at
0.9 m, back on the wall plane y=0, FRONT toward +Y) with a window, a handle and a hose reel
behind it, plus a red extinguisher on the floor at x=+0.55. Origin bottom centre at the wall."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *

reset()
RD = mat('RedPaint', '#c81e1e', metallic=0.3, rough=0.45)
GL = mat('Glass', '#bcd3e0', metallic=0.1, rough=0.1)
ME = mat('Metal', '#8a9098', metallic=0.8, rough=0.35)
BK = mat('Black', '#1a1a1a', metallic=0.1, rough=0.6)
W, H, D, Z0 = 0.75, 0.95, 0.22, 0.9
part(bm_box(-W / 2, W / 2, 0.0, D, Z0, Z0 + H), RD, bevel=0.012, segs=1, name='body')
part(bm_box(-W / 2 + 0.05, W / 2 - 0.05, D, D + 0.012, Z0 + 0.05, Z0 + H - 0.05), RD, bevel=0.006, name='door')
part(bm_box(-W / 2 + 0.1, W / 2 - 0.1, D + 0.012, D + 0.016, Z0 + 0.32, Z0 + H - 0.1), GL, name='window')
part(bm_cyl(0.24, 0.24, (0, D + 0.017, Z0 + 0.6), (0, D + 0.019, Z0 + 0.6), sides=16, caps=True), RD, name='reel')
part(bm_cyl(0.07, 0.07, (0, D + 0.019, Z0 + 0.6), (0, D + 0.024, Z0 + 0.6), sides=10, caps=True), ME, name='hub')
part(bm_box(W / 2 - 0.1, W / 2 - 0.07, D + 0.012, D + 0.045, Z0 + 0.42, Z0 + 0.6), ME, bevel=0.005, name='handle')
# extinguisher on the floor beside it
ex, ey = 0.58, 0.14
part(bm_cyl(0.085, 0.085, (ex, ey, 0.0), (ex, ey, 0.46), sides=12, caps=True), RD, bevel=0.01, name='ext')
part(bm_cyl(0.085, 0.03, (ex, ey, 0.46), (ex, ey, 0.52), sides=12, caps=False), RD, name='ext_top')
part(bm_cyl(0.022, 0.022, (ex, ey, 0.52), (ex, ey, 0.58), sides=8, caps=True), BK, name='valve')
part(bm_tube([(ex + 0.02, ey, 0.57), (ex + 0.1, ey + 0.02, 0.55), (ex + 0.11, ey + 0.03, 0.3)], 0.012, sides=6), BK, name='hose')
ob = finalize('FireCabinet')
report(ob, 'fire_cabinet', 700)
export('fire_cabinet')
