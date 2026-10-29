"""roof_truss.glb - steel roof truss spanning 30 m along X (x -15..+15). Origin at the centre
of the bottom chord underside (z=0); pitched top chord rising to +2.0 m at the centre, Warren
web with verticals every 1.5 m. Material Truss (rust brown). Seen from below at 6-15 m."""
import math
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *

reset()
TR = mat('Truss', '#6e4129', metallic=0.45, rough=0.6)
HALF = 15.0
H_END, H_MID, W = 0.55, 2.0, 0.15
r = W / math.sqrt(2.0)


def top_z(x):
    return H_END + (H_MID - H_END) * (1.0 - abs(x) / HALF)


def beam(p0, p1, w=W):
    part(bm_cyl(w / math.sqrt(2.0), w / math.sqrt(2.0), p0, p1, sides=4, caps=True, rot=math.pi / 4), TR, name='beam')


beam((-HALF, 0, W / 2), (HALF, 0, W / 2), 0.17)                       # bottom chord
beam((-HALF, 0, top_z(-HALF)), (0, 0, H_MID), 0.17)                     # top chords
beam((0, 0, H_MID), (HALF, 0, top_z(HALF)), 0.17)
for s in (-1, 1):                                                       # end posts + plates
    beam((s * HALF, 0, 0.0), (s * HALF, 0, top_z(s * HALF) + 0.08), 0.18)
    part(bm_boxc(s * (HALF - 0.01), 0, 0.3, 0.02, 0.32, 0.6), TR, name='plate')
step = 1.5
n = int(HALF / step)
for k in range(-n + 1, n):                                              # verticals
    x = k * step
    beam((x, 0, W), (x, 0, top_z(x) - 0.02), 0.11)
for k in range(-n, n):                                                  # Warren diagonals
    x0, x1 = k * step, (k + 1) * step
    if k % 2 == 0:
        beam((x0, 0, W), (x1, 0, top_z(x1) - 0.02), 0.1)
    else:
        beam((x0, 0, top_z(x0) - 0.02), (x1, 0, W), 0.1)
ob = finalize('RoofTruss')
report(ob, 'roof_truss', 1600)
export('roof_truss')
