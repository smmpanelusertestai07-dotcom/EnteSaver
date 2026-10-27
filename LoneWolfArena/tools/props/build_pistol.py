"""weapon_pistol.glb - semi-auto pistol (~0.21 m). Origin = grip hand point."""
import sys
sys.path.insert(0, '/root/work/tools/props')
from lib import *

reset()
GM = mat('GunMetal', '#4f555d', metallic=0.7, rough=0.4)
PO = mat('Polymer', '#1d1e21', metallic=0.0, rough=0.62)
AC = mat('Accent', '#f2781c', metallic=0.1, rough=0.45)
ZB = 0.0795

frame = [(0.140, 0.0625), (0.140, 0.047), (0.104, 0.046), (0.094, 0.041), (0.040, 0.040), (0.036, 0.040),
         (0.027, 0.012), (0.0224, -0.008), (0.0148, -0.022), (0.0131, -0.035), (0.0048, -0.056),
         (-0.0412, -0.056), (-0.030, -0.020), (-0.0155, 0.020), (-0.017, 0.032), (-0.033, 0.045),
         (-0.036, 0.052), (-0.036, 0.0625)]
part(bm_prism(frame, 'X', -0.0145, 0.0145), PO, bevel=0.0025, name='frame')
panel = [(0.020, 0.025), (0.017, 0.005), (0.010, -0.015), (0.008, -0.042), (-0.034, -0.046), (-0.025, -0.010),
         (-0.012, 0.025)]
part(bm_prism(panel, 'X', -0.0153, 0.0153), PO, bevel=0.0008, name='grippanel')
guard = [(0.030, 0.044), (0.036, 0.012), (0.048, 0.004), (0.085, 0.004), (0.094, 0.012), (0.098, 0.030),
         (0.097, 0.044), (0.090, 0.044), (0.089, 0.024), (0.083, 0.011), (0.052, 0.011), (0.044, 0.018),
         (0.040, 0.044)]
part(bm_prism(guard, 'X', -0.0062, 0.0062), PO, bevel=0.0012, name='guard')
part(bm_prism([(0.062, 0.042), (0.066, 0.030), (0.065, 0.020), (0.061, 0.016), (0.059, 0.019), (0.061, 0.029),
               (0.058, 0.042)], 'X', -0.003, 0.003), AC, name='trigger')
part(bm_prism([(0.006, -0.0545), (0.0055, -0.062), (0.001, -0.065), (-0.044, -0.065), (-0.0425, -0.0545)],
              'X', -0.0155, 0.0155), AC, bevel=0.0015, name='magbase')

# slide with ejection port (boolean) + barrel hood
slide = [(-0.0125, 0.0625), (0.0125, 0.0625), (0.0125, 0.089), (0.0088, 0.0965), (-0.0088, 0.0965), (-0.0125, 0.089)]
part(bm_prism(slide, 'Y', -0.040, 0.166), GM, bevel=0.0022, name='slide',
     cutters=[(bm_box(-0.0035, 0.020, 0.052, 0.092, 0.0885, 0.110), PO)])
part(bm_box(-0.0065, 0.0065, 0.050, 0.094, 0.080, 0.0925), GM, name='hood')
for k in range(5):
    y = -0.034 + k * 0.0058
    part(bm_box(-0.0131, 0.0131, y, y + 0.0026, 0.067, 0.0875), GM, name='serration')
part(bm_cyl(0.0062, 0.0062, (0, 0.158, ZB), (0, 0.1675, ZB), sides=10), GM, name='barrel')
part(bm_cyl(0.0036, 0.0036, (0, 0.1676, ZB), (0, 0.1680, ZB), sides=8), PO, name='bore')
# sights
part(bm_box(-0.0085, -0.0024, -0.035, -0.025, 0.096, 0.1035), PO, name='rsight_l')
part(bm_box(0.0024, 0.0085, -0.035, -0.025, 0.096, 0.1035), PO, name='rsight_r')
part(bm_box(-0.0085, 0.0085, -0.035, -0.025, 0.096, 0.0985), PO, name='rsight_b')
part(bm_box(-0.0022, 0.0022, 0.150, 0.157, 0.096, 0.1035), AC, name='fsight')
# slide stop (left) + takedown
part(bm_box(-0.0158, -0.0140, 0.020, 0.050, 0.058, 0.0645), GM, bevel=0.0005, name='slidestop')
part(bm_box(-0.0152, 0.0152, 0.070, 0.078, 0.054, 0.059), GM, name='takedown')

ob = finalize('Weapon_Pistol')
empty('Muzzle', (0, 0.168, ZB))
empty('LeftHand', (-0.012, 0.0, -0.010))
report(ob, 'weapon_pistol', 1200)
export('weapon_pistol')
