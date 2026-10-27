"""weapon_sg.glb - pump shotgun (~0.95 m) with wooden stock & pump. Origin = grip hand point."""
import sys
sys.path.insert(0, '/root/work/tools/props')
from lib import *

reset()
GM = mat('GunMetal', '#4f555d', metallic=0.7, rough=0.4)
PO = mat('Polymer', '#1d1e21', metallic=0.0, rough=0.62)
WD = mat('Wood', '#83502b', metallic=0.0, rough=0.55)

ZB, ZM = 0.075, 0.048          # bore axis / magazine tube axis (design space)
HAND = Vector((0, -0.008, -0.022))  # grip hand point in design space -> becomes origin

# ---------------------------------------------------------------- stock (tapered, wood)
stock = [(0.035, 0.091), (0.010, 0.082), (-0.025, 0.066), (-0.060, 0.068), (-0.110, 0.078), (-0.318, 0.083),
         (-0.334, 0.086), (-0.340, 0.076), (-0.340, -0.096), (-0.327, -0.101), (-0.150, -0.040), (-0.028, -0.008),
         (-0.039, -0.040), (-0.051, -0.075), (-0.044, -0.082), (-0.004, -0.080), (0.011, -0.040), (0.025, 0.000),
         (0.033, 0.018)]
def taper(u, v):
    hw = 0.0158 + min(max(-u, 0.0), 0.34) * 0.016
    return (-hw, hw)
part(bm_prism(stock, 'X', 0, 0, hw_fn=taper), WD, bevel=0.0075, segs=3, name='stock')
part(bm_prism([(-0.338, 0.078), (-0.338, -0.098), (-0.360, -0.103), (-0.364, -0.090), (-0.364, 0.074),
               (-0.358, 0.083)], 'X', -0.0215, 0.0215), PO, bevel=0.005, segs=2, name='pad')
part(bm_prism([(-0.048, -0.0785), (-0.003, -0.0765), (-0.002, -0.0855), (-0.046, -0.0875)], 'X', -0.0158, 0.0158),
     PO, bevel=0.0015, name='gripcap')

# ---------------------------------------------------------------- receiver with ejection port
rec = [(0.035, 0.090), (0.045, 0.094), (0.230, 0.094), (0.236, 0.089), (0.236, 0.016), (0.035, 0.016)]
part(bm_prism(rec, 'X', -0.0185, 0.0185), GM, bevel=0.0025, name='receiver',
     cutters=[(bm_box(0.010, 0.030, 0.110, 0.178, 0.052, 0.080), PO),
              (bm_box(-0.010, 0.010, 0.120, 0.200, 0.000, 0.022), PO)])
# bolt visible in the port
part(bm_box(0.004, 0.0175, 0.112, 0.150, 0.056, 0.076), GM, bevel=0.001, name='bolt')
# trigger plate / guard / trigger / safety
part(bm_box(-0.0165, 0.0165, 0.035, 0.130, 0.008, 0.0175), PO, bevel=0.0015, name='tplate')
guard = [(0.030, 0.018), (0.032, -0.010), (0.045, -0.022), (0.100, -0.022), (0.118, -0.006), (0.125, 0.018),
         (0.112, 0.018), (0.108, -0.002), (0.098, -0.014), (0.050, -0.014), (0.040, -0.006), (0.039, 0.018)]
part(bm_prism(guard, 'X', -0.0068, 0.0068), PO, bevel=0.0015, name='guard')
part(bm_prism([(0.072, 0.010), (0.077, -0.002), (0.075, -0.012), (0.071, -0.015), (0.069, -0.012), (0.071, -0.002),
               (0.068, 0.010)], 'X', -0.003, 0.003), GM, name='trigger')
part(bm_cyl(0.004, 0.004, (-0.010, 0.117, 0.013), (0.010, 0.117, 0.013), sides=8), GM, name='safety')

# ---------------------------------------------------------------- barrel, rib, mag tube
part(bm_cyl(0.0115, 0.0115, (0, 0.236, ZB), (0, 0.582, ZB), sides=12, caps=False), GM, name='barrel')
part(bm_cyl(0.0124, 0.0124, (0, 0.578, ZB), (0, 0.590, ZB), sides=12), GM, bevel=0.0012, name='crown')
part(bm_cyl(0.0060, 0.0060, (0, 0.5905, ZB), (0, 0.5908, ZB), sides=8), PO, name='bore')
part(bm_box(-0.0036, 0.0036, 0.236, 0.585, 0.0850, 0.0905), GM, bevel=0.0008, name='rib')
part(bm_cyl(0.0026, 0.0026, (0, 0.579, 0.089), (0, 0.579, 0.0955), sides=8), GM, name='bead')
part(bm_cyl(0.0108, 0.0108, (0, 0.236, ZM), (0, 0.546, ZM), sides=12, caps=False), GM, name='magtube')
part(bm_cyl(0.0126, 0.0114, (0, 0.545, ZM), (0, 0.567, ZM), sides=12), GM, bevel=0.0015, name='magcap')
part(bm_box(-0.0128, 0.0128, 0.527, 0.541, 0.034, 0.088), GM, bevel=0.003, name='clamp')
for sx in (-1, 1):
    part(bm_box(sx * 0.0115, sx * 0.0142, 0.236, 0.300, 0.039, 0.047) if sx > 0 else
         bm_box(-0.0142, -0.0115, 0.236, 0.300, 0.039, 0.047), GM, name='actionbar')

# ---------------------------------------------------------------- grooved wooden pump
base = rounded_rect(0.0255, 0.0245, 0.011, segs=1)   # octagon-ish section (x, z)
zc = 0.046
st = [(0.290, 0.84), (0.300, 1.0)]
for yg in (0.320, 0.344, 0.368, 0.392, 0.416):
    st += [(yg - 0.005, 1.0), (yg, 0.90), (yg + 0.005, 1.0)]
st += [(0.442, 1.0), (0.454, 0.84)]
rings = [[(x * s, y, zc + z * s) for (x, z) in base] for (y, s) in st]
part(bm_loft(rings), WD, name='pump')

shift_all(-HAND)
ob = finalize('Weapon_SG')
empty('Muzzle', Vector((0, 0.590, ZB)) - HAND)
empty('LeftHand', Vector((0, 0.372, zc)) - HAND)
report(ob, 'weapon_sg', 3000)
export('weapon_sg')
