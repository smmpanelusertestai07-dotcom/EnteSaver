"""lamp_tube.glb - hanging double fluorescent fixture. Origin at the ceiling hook (z=0), the
fixture hangs down to z=-1.2: two rods, a white reflector housing 1.4 x 0.26 x 0.08 and two
emissive tubes underneath (material Lamp)."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *

reset()
HO = mat('LampHousing', '#e9ecef', metallic=0.3, rough=0.4)
ST = mat('Steel', '#474c54', metallic=0.7, rough=0.45)
LA = mat('Lamp', '#ffffff', metallic=0.0, rough=0.3, emit='#e8f4ff', emit_strength=4.0)
for x in (-0.55, 0.55):
    part(bm_cyl(0.008, 0.008, (x, 0, 0.0), (x, 0, -1.12), sides=4, caps=False), ST, name='rod')
part(bm_box(-0.7, 0.7, -0.13, 0.13, -1.2, -1.12), HO, name='housing')
for y in (-0.06, 0.06):
    part(bm_cyl(0.019, 0.019, (-0.66, y, -1.215), (0.66, y, -1.215), sides=8, caps=True), LA, name='tube')
ob = finalize('LampTube')
report(ob, 'lamp_tube', 260)
export('lamp_tube')
