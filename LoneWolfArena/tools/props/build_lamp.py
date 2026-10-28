"""lamp_post.glb - 5 m street light, arm toward +Y. Origin at the pole base centre."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *
reset()
ME = mat('Metal', '#3c4548', metallic=0.7, rough=0.45)
CO = mat('Concrete', '#a8a59d', metallic=0.0, rough=0.9)
LL = mat('LampLight', '#fff4d6', metallic=0.0, rough=0.3, emit='#ffefc4', emit_strength=5.0)
part(bm_cyl(0.24, 0.20, (0, 0, 0), (0, 0, 0.35), sides=8, rot=math.pi / 8), CO, bevel=0.02, name='base')
part(bm_cyl(0.10, 0.10, (0, 0, 0.35), (0, 0, 0.42), sides=8, rot=math.pi / 8), ME, bevel=0.01, name='flange')
part(bm_cyl(0.085, 0.075, (0, 0, 0.42), (0, 0, 0.95), sides=8, rot=math.pi / 8), ME, name='collar')
part(bm_cyl(0.068, 0.044, (0, 0, 0.95), (0, 0, 4.78), sides=8, rot=math.pi / 8, caps=False), ME, name='pole')
part(bm_cyl(0.052, 0.0, (0, 0, 4.76), (0, 0, 4.86), sides=8, rot=math.pi / 8), ME, name='cap')
part(bm_tube([(0, 0.0, 4.55), (0, 0.04, 4.80), (0, 0.18, 4.97), (0, 0.45, 5.04), (0, 0.80, 5.03)], 0.034, sides=6, caps=False),
     ME, smooth=70, name='arm')
head = [(-0.075, 4.93), (0.075, 4.93), (0.14, 4.88), (0.14, 4.86), (-0.14, 4.86), (-0.14, 4.88)]
part(bm_prism(head, 'Y', 0.74, 1.30), ME, bevel=0.012, name='head')
part(bm_box(-0.115, 0.115, 0.78, 1.26, 4.852, 4.862), LL, name='light')
ob = finalize('LampPost')
report(ob, 'lamp_post', 400)
export('lamp_post')
