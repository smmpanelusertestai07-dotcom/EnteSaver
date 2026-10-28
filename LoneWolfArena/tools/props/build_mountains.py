"""mountains.glb - distant backdrop ring of low-poly mountains, inner radius ~350 m, peaks 60-140 m.
Origin at the ring centre (arena centre), open in the middle."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *
from mathutils import noise
reset()
MT = mat('Mountain', '#6c7464', metallic=0.0, rough=0.95)
SN = mat('Snow', '#eef2f6', metallic=0.0, rough=0.7)
random.seed(42)
N, M = 150, 12
R0, R1 = 345.0, 700.0
radii = [R0 + (R1 - R0) * (i / (M - 1)) ** 1.25 for i in range(M)]
peaks = []
k = 0
while k < 30:
    th = 2 * math.pi * k / 30 + random.uniform(-0.08, 0.08)
    peaks.append((th, random.uniform(60, 140), random.uniform(0.09, 0.2), random.uniform(430, 540)))
    k += 1


def height(th, r):
    h = 0.0
    for (pt, ph, pw, pr) in peaks:
        d = math.atan2(math.sin(th - pt), math.cos(th - pt))
        h = max(h, ph * math.exp(-(d / pw) ** 2) * math.exp(-((r - pr) / 150.0) ** 2))
    base = 28 * math.exp(-((r - 520) / 160.0) ** 2)
    h = max(h, base) + 9 * noise.noise(Vector((math.cos(th) * 3.1, math.sin(th) * 3.1, r / 90.0)))
    ramp = min(1.0, max(0.0, (r - R0) / 45.0))
    return -4.0 + (h + 4.0) * ramp


bm = bmesh.new()
grid = []
for i, r in enumerate(radii):
    row = []
    for j in range(N):
        th = 2 * math.pi * j / N + (0.5 * 2 * math.pi / N if i % 2 else 0.0)
        jr = r + (random.uniform(-8, 8) if 0 < i < M - 1 else 0.0)
        jt = th + (random.uniform(-0.008, 0.008) if 0 < i < M - 1 else 0.0)
        row.append(bm.verts.new((jr * math.cos(jt), jr * math.sin(jt), height(jt, jr))))
    grid.append(row)
for i in range(M - 1):
    a, b = grid[i], grid[i + 1]
    for j in range(N):
        jn = (j + 1) % N
        if i % 2 == 0:   # row i+1 is shifted half a step forward
            bm.faces.new((a[j], a[jn], b[j]))
            bm.faces.new((a[jn], b[jn], b[j]))
        else:
            bm.faces.new((a[j], a[jn], b[jn]))
            bm.faces.new((a[j], b[jn], b[j]))
bm.normal_update()
for f in bm.faces:
    if f.normal.z < 0:
        f.normal_flip()
    c = f.calc_center_median()
    f.material_index = 1 if (c.z > 92 + 10 * noise.noise(c * 0.02)) else 0
part(bm, [MT, SN], smooth=1, wn=False, name='ring')
ob = finalize('Mountains', uv_scale=0.1)
report(ob, 'mountains', 6000)
export('mountains')
