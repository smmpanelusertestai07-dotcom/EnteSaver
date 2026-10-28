"""weapon_smg.glb - compact submachine gun (~0.6 m with the folding stock). Origin = pistol grip
hand point. Barrel along +Y, top +Z, right side +X. Markers: Muzzle, LeftHand (front grip)."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *

reset()
GM = mat('GunMetal', '#4f555d', metallic=0.7, rough=0.4)
PO = mat('Polymer', '#1d1e21', metallic=0.0, rough=0.62)
AC = mat('Accent', '#f2c200', metallic=0.1, rough=0.45)
ZB = 0.088

# receiver (upper + lower)
part(bm_prism([(-0.060, 0.070), (-0.060, 0.110), (-0.052, 0.118), (0.205, 0.118), (0.212, 0.110), (0.212, 0.070)],
              'X', -0.017, 0.017), GM, bevel=0.002, name='upper')
part(bm_prism([(-0.056, 0.071), (0.160, 0.071), (0.160, 0.050), (0.150, 0.040), (0.030, 0.040), (0.010, 0.046),
               (-0.040, 0.052)], 'X', -0.0155, 0.0155), PO, bevel=0.002, name='lower')
part(bm_box(0.0160, 0.0185, 0.020, 0.090, 0.080, 0.104), GM, bevel=0.0008, name='port')
part(bm_box(-0.020, -0.016, -0.010, 0.010, 0.058, 0.066), AC, bevel=0.0008, name='selector')
part(bm_cyl(0.006, 0.006, (-0.026, 0.150, 0.100), (-0.017, 0.150, 0.100), sides=8), GM, name='cocking')
# grip / guard / trigger
grip = [(0.040, 0.050), (0.033, 0.036), (0.0258, 0.013), (0.0214, -0.006), (0.0130, -0.022),
        (0.0122, -0.036), (0.0019, -0.054), (-0.003, -0.062), (-0.041, -0.064), (-0.042, -0.056),
        (-0.034, -0.030), (-0.0205, 0.004), (-0.014, 0.028), (-0.012, 0.050)]
part(bm_prism(grip, 'X', -0.0145, 0.0145), PO, bevel=0.003, name='grip')
part(bm_prism([(0.024, 0.024), (0.030, 0.013), (0.076, 0.013), (0.082, 0.019), (0.082, 0.040), (0.076, 0.040),
               (0.076, 0.022), (0.072, 0.018), (0.033, 0.018), (0.028, 0.027)], 'X', -0.0055, 0.0055), GM,
     bevel=0.0012, name='guard')
part(bm_prism([(0.050, 0.044), (0.054, 0.033), (0.053, 0.024), (0.0495, 0.021), (0.0475, 0.024), (0.0495, 0.033),
               (0.046, 0.044)], 'X', -0.003, 0.003), AC, name='trigger')
# long stick magazine (slightly raked forward)
mag = [(0.100, 0.050), (0.146, 0.050), (0.150, -0.020), (0.156, -0.100), (0.162, -0.170), (0.120, -0.176),
       (0.112, -0.104), (0.106, -0.024)]
part(bm_prism(mag, 'X', -0.012, 0.012), PO, bevel=0.002, name='mag')
part(bm_prism([(0.116, -0.168), (0.166, -0.162), (0.168, -0.178), (0.118, -0.186)], 'X', -0.0138, 0.0138), AC,
     bevel=0.0015, name='magbase')
# barrel shroud with vent holes (dark strips), barrel and muzzle
part(bm_cyl(0.0175, 0.0175, (0, 0.205, ZB), (0, 0.345, ZB), sides=10, rot=math.pi / 10), GM, bevel=0.0015,
     name='shroud')
for y0 in (0.225, 0.255, 0.285, 0.315):
    part(bm_box(-0.0185, 0.0185, y0, y0 + 0.016, ZB - 0.004, ZB + 0.004), PO, name='vent')
part(bm_cyl(0.0085, 0.0085, (0, 0.345, ZB), (0, 0.392, ZB), sides=10, caps=False), GM, name='barrel')
part(bm_cyl(0.0125, 0.0115, (0, 0.388, ZB), (0, 0.412, ZB), sides=10), GM, bevel=0.0012, name='muzzle')
# front vertical grip
part(bm_prism([(0.252, 0.072), (0.282, 0.072), (0.286, 0.020), (0.282, 0.000), (0.258, 0.000), (0.252, 0.020)],
              'X', -0.0125, 0.0125), PO, bevel=0.003, name='frontgrip')
part(bm_prism([(0.246, 0.072), (0.292, 0.072), (0.292, 0.064), (0.246, 0.064)], 'X', -0.014, 0.014), AC,
     bevel=0.001, name='grip_ring')
# top rail + small reflex sight
part(bm_box(-0.0095, 0.0095, -0.040, 0.200, 0.118, 0.125), GM, bevel=0.0007, name='rail')
part(bm_box(-0.011, 0.011, 0.040, 0.080, 0.125, 0.137), GM, bevel=0.0012, name='sight_base')
part(bm_prism([(0.044, 0.137), (0.078, 0.137), (0.078, 0.172), (0.070, 0.176), (0.050, 0.176), (0.044, 0.168)],
              'X', -0.0145, 0.0145), PO, bevel=0.0015, name='sight_hood')
# folding wire stock (two rods + butt plate)
for z in (0.104, 0.070):
    part(bm_cyl(0.0055, 0.0055, (0, -0.060, z), (0, -0.270, z - 0.006), sides=6), GM, name='stock_rod')
part(bm_prism([(-0.262, 0.118), (-0.262, 0.040), (-0.284, 0.036), (-0.288, 0.046), (-0.288, 0.114), (-0.284, 0.122)],
              'X', -0.017, 0.017), PO, bevel=0.0025, name='buttplate')
part(bm_box(-0.0175, 0.0175, -0.272, -0.266, 0.064, 0.096), AC, bevel=0.001, name='butt_stripe')

ob = finalize('Weapon_SMG')
empty('Muzzle', (0, 0.412, ZB))
empty('LeftHand', (0, 0.268, 0.045))
report(ob, 'weapon_smg', 2000)
export('weapon_smg')
