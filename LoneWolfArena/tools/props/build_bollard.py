"""bollard.glb - steel safety bollard 0.16 m x 1.1 m, alternating 0.15 m Yellow / Black bands,
rounded cap. Origin bottom centre."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *

reset()
YE = mat('Yellow', '#f2c200', metallic=0.2, rough=0.5)
BK = mat('Black', '#1a1a1a', metallic=0.2, rough=0.6)
R = 0.08
z = 0.0
i = 0
while z < 1.0 - 1e-6:
    z1 = min(z + 0.15, 1.0)
    part(bm_cyl(R, R, (0, 0, z), (0, 0, z1), sides=12, caps=(i == 0)), YE if i % 2 == 0 else BK, name='band')
    z = z1
    i += 1
part(bm_cyl(R, R * 0.55, (0, 0, 1.0), (0, 0, 1.08), sides=12, caps=False), YE, name='dome1')
part(bm_cyl(R * 0.55, 0.0, (0, 0, 1.08), (0, 0, 1.1), sides=12, caps=False), YE, name='dome2')
part(bm_cyl(R + 0.04, R + 0.04, (0, 0, 0.0), (0, 0, 0.012), sides=12, caps=True), BK, name='base')
ob = finalize('Bollard')
report(ob, 'bollard', 280)
export('bollard')
