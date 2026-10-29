"""pallet.glb - wooden EUR pallet 1.2 x 0.8 x 0.144 m (5 top boards, 3 stringers, 9 blocks,
3 bottom boards). Wood / WoodDark. Origin bottom centre, long side along X."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *

reset()
WD = mat('Wood', '#b98a52', metallic=0.0, rough=0.75)
WK = mat('WoodDark', '#7a5530', metallic=0.0, rough=0.8)
L, W = 1.2, 0.8
ys = (-0.3275, 0.0, 0.3275)
xs = (-0.525, 0.0, 0.525)
for y in ys:                                   # bottom boards along X
    part(bm_boxc(0, y, 0.011, L, 0.1 if y else 0.145, 0.022), WK, name='bottom')
for x in xs:                                   # 9 blocks
    for y in ys:
        part(bm_boxc(x, y, 0.022 + 0.039, 0.145 if x == 0 else 0.1, 0.1 if y else 0.145, 0.078), WK, name='block')
for y in ys:                                   # stringer boards along X on top of the blocks
    part(bm_boxc(0, y, 0.1 + 0.011, L, 0.1 if y else 0.145, 0.022), WD, name='stringer')
for x in (-0.5275, -0.264, 0.0, 0.264, 0.5275):                  # top boards run across the stringers (along Y)
    part(bm_boxc(x, 0, 0.122 + 0.011, 0.145 if abs(x) > 0.5 or x == 0 else 0.1, W, 0.022), WD, name='top')
ob = finalize('Pallet')
report(ob, 'pallet', 320)
export('pallet')
