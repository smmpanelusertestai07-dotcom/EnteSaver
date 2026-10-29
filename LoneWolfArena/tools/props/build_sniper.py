"""weapon_sniper.glb - bolt-action sniper rifle (~1.2 m) with a long scope. Origin = pistol grip
hand point. Barrel along +Y, top +Z, right side +X. Markers: Muzzle, LeftHand (forend)."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *

reset()
GM = mat('GunMetal', '#4a5058', metallic=0.7, rough=0.4)
PO = mat('Polymer', '#39452f', metallic=0.0, rough=0.6)
AC = mat('Accent', '#f2781c', metallic=0.1, rough=0.45)
GL = mat('Lens', '#5aa7d8', metallic=0.2, rough=0.08, emit='#2a6f9e', emit_strength=0.6)
ZB = 0.092

# receiver + bolt
part(bm_cyl(0.021, 0.021, (0, -0.060, ZB), (0, 0.230, ZB), sides=12, rot=math.pi / 12), GM, bevel=0.0015,
     name='receiver')
part(bm_cyl(0.0055, 0.0055, (0.012, 0.000, ZB + 0.004), (0.060, -0.012, ZB - 0.020), sides=6), GM, name='bolt')
part(bm_cyl(0.011, 0.011, (0.058, -0.013, ZB - 0.019), (0.072, -0.016, ZB - 0.026), sides=8), AC, name='bolt_knob')
# barrel (fluted look: two diameters) + muzzle brake
part(bm_cyl(0.0125, 0.0105, (0, 0.230, ZB), (0, 0.560, ZB), sides=10, caps=False), GM, name='barrel1')
part(bm_cyl(0.0105, 0.0095, (0, 0.560, ZB), (0, 0.860, ZB), sides=10, caps=False), GM, name='barrel2')
part(bm_box(-0.016, 0.016, 0.860, 0.915, ZB - 0.013, ZB + 0.013), GM, bevel=0.003, name='brake')
for y0 in (0.872, 0.892):
    part(bm_box(-0.0168, 0.0168, y0, y0 + 0.010, ZB - 0.007, ZB + 0.007), AC, name='brake_port')
# stock (thumbhole style) with cheek riser, forend under the barrel
stock = [(0.000, 0.070), (-0.060, 0.072), (-0.090, 0.080), (-0.300, 0.094), (-0.420, 0.104), (-0.432, 0.096),
         (-0.436, -0.040), (-0.420, -0.050), (-0.330, -0.040), (-0.250, -0.012), (-0.150, 0.010), (-0.070, 0.020),
         (-0.030, 0.040)]
part(bm_prism(stock, 'X', -0.019, 0.019), PO, bevel=0.004, name='stock')
part(bm_prism([(-0.140, 0.094), (-0.330, 0.100), (-0.330, 0.128), (-0.170, 0.124)], 'X', -0.016, 0.016), PO,
     bevel=0.004, name='cheek')
part(bm_prism([(-0.436, 0.108), (-0.436, -0.054), (-0.454, -0.056), (-0.458, 0.110)], 'X', -0.021, 0.021), AC,
     bevel=0.003, name='buttpad')
fore = [(0.010, 0.072), (0.520, 0.074), (0.540, 0.066), (0.540, 0.052), (0.300, 0.040), (0.120, 0.034), (0.020, 0.040)]
part(bm_prism(fore, 'X', -0.020, 0.020), PO, bevel=0.004, name='forend')
# grip / guard / trigger / magazine
grip = [(0.040, 0.050), (0.033, 0.036), (0.0258, 0.013), (0.0214, -0.006), (0.0130, -0.022),
        (0.0122, -0.036), (0.0019, -0.054), (-0.003, -0.062), (-0.041, -0.064), (-0.042, -0.056),
        (-0.034, -0.030), (-0.0205, 0.004), (-0.014, 0.028), (-0.012, 0.050)]
part(bm_prism(grip, 'X', -0.0145, 0.0145), PO, bevel=0.003, name='grip')
part(bm_prism([(0.024, 0.026), (0.030, 0.015), (0.082, 0.015), (0.088, 0.021), (0.088, 0.044), (0.082, 0.044),
               (0.082, 0.024), (0.078, 0.020), (0.033, 0.020), (0.028, 0.029)], 'X', -0.0055, 0.0055), GM,
     bevel=0.0012, name='guard')
part(bm_prism([(0.052, 0.046), (0.056, 0.035), (0.055, 0.026), (0.0515, 0.023), (0.0495, 0.026), (0.0515, 0.035),
               (0.048, 0.046)], 'X', -0.003, 0.003), AC, name='trigger')
part(bm_prism([(0.100, 0.050), (0.160, 0.050), (0.158, -0.010), (0.102, -0.010)], 'X', -0.016, 0.016), GM,
     bevel=0.002, name='mag')
# scope: rings, tube, objective bell, eyepiece, turrets
for y in (0.000, 0.160):
    part(bm_box(-0.013, 0.013, y - 0.010, y + 0.010, ZB + 0.018, ZB + 0.056), GM, bevel=0.002, name='ring')
ZS = ZB + 0.072
part(bm_cyl(0.019, 0.019, (0, -0.070, ZS), (0, 0.230, ZS), sides=14), PO, bevel=0.0015, name='scope_tube')
part(bm_cyl(0.019, 0.030, (0, 0.230, ZS), (0, 0.272, ZS), sides=14, caps=False), PO, name='bell_cone')
part(bm_cyl(0.030, 0.030, (0, 0.272, ZS), (0, 0.312, ZS), sides=14), PO, bevel=0.002, name='bell')
part(bm_cyl(0.026, 0.026, (0, 0.311, ZS), (0, 0.313, ZS), sides=14), GL, name='lens_front')
part(bm_cyl(0.019, 0.025, (0, -0.120, ZS), (0, -0.070, ZS), sides=14, caps=False), PO, name='eyepiece_cone')
part(bm_cyl(0.025, 0.025, (0, -0.150, ZS), (0, -0.120, ZS), sides=14), PO, bevel=0.002, name='eyepiece')
part(bm_cyl(0.021, 0.021, (0, -0.152, ZS), (0, -0.150, ZS), sides=14), GL, name='lens_back')
part(bm_cyl(0.011, 0.011, (0, 0.080, ZS + 0.018), (0, 0.080, ZS + 0.040), sides=10), AC, name='turret_top')
part(bm_cyl(0.011, 0.011, (0.018, 0.080, ZS), (0.040, 0.080, ZS), sides=10), GM, name='turret_side')
# folded bipod: mount block under the forend tip, legs folded back flush with the forend
part(bm_box(-0.014, 0.014, 0.492, 0.522, 0.034, 0.054), GM, bevel=0.002, name='bipod_mount')
for x in (-0.010, 0.010):
    part(bm_cyl(0.0045, 0.0045, (x, 0.505, 0.0440), (x, 0.300, 0.0355), sides=6), GM, name='bipod')

ob = finalize('Weapon_Sniper')
empty('Muzzle', (0, 0.915, ZB))
empty('LeftHand', (0, 0.330, 0.050))
report(ob, 'weapon_sniper', 3000)
export('weapon_sniper')
