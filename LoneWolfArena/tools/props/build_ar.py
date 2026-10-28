"""weapon_ar.glb - modern assault rifle (~0.85 m). Origin = pistol grip hand point.
Barrel along +Y, top +Z, right side +X."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *

reset()
GM = mat('GunMetal', '#4f555d', metallic=0.7, rough=0.4)
PO = mat('Polymer', '#1d1e21', metallic=0.0, rough=0.62)
AC = mat('Accent', '#f2781c', metallic=0.1, rough=0.45)

ZB = 0.095  # bore axis height above the grip point

# ---------------------------------------------------------------- receiver
part(bm_prism([(-0.062, 0.074), (-0.062, 0.113), (-0.055, 0.1205), (0.214, 0.1205), (0.214, 0.074)],
              'X', -0.0165, 0.0165), GM, bevel=0.0022, name='upper')
part(bm_prism([(-0.058, 0.0745), (0.172, 0.0745), (0.172, 0.052), (0.166, 0.030), (0.080, 0.030),
               (0.076, 0.044), (0.034, 0.044), (0.022, 0.048), (-0.006, 0.048), (-0.030, 0.052),
               (-0.050, 0.060)], 'X', -0.0152, 0.0152), GM, bevel=0.002, name='lower')
# mag-well flare lip
part(bm_prism([(0.077, 0.044), (0.169, 0.044), (0.167, 0.029), (0.079, 0.029)], 'X', -0.0168, 0.0168),
     GM, bevel=0.0015, name='magwell')
# ejection-port dust cover (right) + forward assist + brass deflector
part(bm_box(0.0155, 0.0178, 0.030, 0.095, 0.083, 0.107), GM, bevel=0.0008, name='dustcover')
part(bm_cyl(0.0062, 0.0062, (0.0175, -0.044, 0.103), (0.0175, -0.020, 0.103), sides=8), GM,
     name='fwd_assist')
part(bm_box(0.0150, 0.0205, -0.016, -0.004, 0.096, 0.112), GM, bevel=0.001, name='deflector')
# charging handle
part(bm_box(-0.021, 0.021, -0.075, -0.064, 0.108, 0.1175), GM, bevel=0.0012, name='charging')
# selector + bolt catch (left)
part(bm_box(-0.0185, -0.0145, -0.016, 0.000, 0.060, 0.067), AC, bevel=0.0008, name='selector')
part(bm_box(-0.0175, -0.0145, 0.062, 0.078, 0.060, 0.070), GM, bevel=0.0008, name='boltcatch')

# ---------------------------------------------------------------- grip / trigger
grip = [(0.040, 0.056), (0.033, 0.040), (0.0258, 0.015), (0.0214, -0.005), (0.0130, -0.022),
        (0.0122, -0.036), (0.0019, -0.056), (-0.003, -0.064), (-0.043, -0.066), (-0.044, -0.058),
        (-0.036, -0.030), (-0.0215, 0.005), (-0.014, 0.030), (-0.012, 0.056)]
part(bm_prism(grip, 'X', -0.0145, 0.0145), PO, bevel=0.003, name='grip')
guard = [(0.024, 0.022), (0.030, 0.011), (0.080, 0.011), (0.087, 0.018), (0.087, 0.040),
         (0.081, 0.040), (0.081, 0.021), (0.077, 0.017), (0.033, 0.017), (0.028, 0.026)]
part(bm_prism(guard, 'X', -0.0055, 0.0055), GM, bevel=0.0012, name='guard')
trig = [(0.050, 0.046), (0.054, 0.034), (0.053, 0.024), (0.0495, 0.020), (0.0475, 0.023),
        (0.0495, 0.033), (0.046, 0.046)]
part(bm_prism(trig, 'X', -0.003, 0.003), AC, name='trigger')

# ---------------------------------------------------------------- magazine
mag = [(0.084, 0.062), (0.160, 0.062), (0.162, 0.025), (0.167, -0.015), (0.176, -0.050), (0.188, -0.080),
       (0.197, -0.097), (0.124, -0.109), (0.114, -0.082), (0.104, -0.048), (0.096, -0.012), (0.089, 0.028)]
part(bm_prism(mag, 'X', -0.0125, 0.0125), PO, bevel=0.002, name='mag')
magpanel = [(0.102, 0.012), (0.156, 0.012), (0.161, -0.018), (0.169, -0.048), (0.179, -0.074),
            (0.130, -0.082), (0.120, -0.056), (0.110, -0.024)]
part(bm_prism(magpanel, 'X', -0.0135, 0.0135), PO, bevel=0.0009, name='magpanel')
magbase = [(0.120, -0.104), (0.198, -0.093), (0.202, -0.104), (0.199, -0.113), (0.126, -0.124), (0.117, -0.118)]
part(bm_prism(magbase, 'X', -0.0148, 0.0148), AC, bevel=0.0018, name='magbase')

# ---------------------------------------------------------------- handguard with M-LOK style slots
hw, hh, ch = 0.0235, 0.0245, 0.0085
prof = [(hw, ZB - 0.004), (hw, ZB + 0.004), (hw, ZB + hh - ch), (hw - ch, ZB + hh), (-hw + ch, ZB + hh),
        (-hw, ZB + hh - ch), (-hw, ZB + 0.004), (-hw, ZB - 0.004), (-hw, ZB - hh + ch), (-hw + ch, ZB - hh),
        (hw - ch, ZB - hh), (hw, ZB - hh + ch)]
stations = [0.212, 0.245, 0.277, 0.293, 0.325, 0.341, 0.373, 0.389, 0.421, 0.440]
slots = [(0.245, 0.277), (0.293, 0.325), (0.341, 0.373), (0.389, 0.421)]
rings = [[(x, y, z) for (x, z) in prof] for y in stations]
bm = bm_loft(rings)
bm.faces.ensure_lookup_table()
sel = []
for f in bm.faces:
    c = f.calc_center_median()
    n = f.normal
    if abs(n.x) > 0.9 and abs(c.z - ZB) < 0.0035 and any(a < c.y < b for a, b in slots):
        sel.append(f)
res = bmesh.ops.extrude_discrete_faces(bm, faces=sel)
for f in res['faces']:
    d = -f.normal * 0.0035
    for v in f.verts:
        v.co += d
bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
part(bm, GM, name='handguard')
# bottom slots: recessed dark strips under the handguard
for a, b in slots:
    part(bm_box(-0.0045, 0.0045, a + 0.004, b - 0.004, ZB - hh - 0.0006, ZB - hh + 0.002), PO, name='bslot')
# accent front ring
fr = [(x * 1.06, ZB + (z - ZB) * 1.06) for (x, z) in prof]
part(bm_prism(fr, 'Y', 0.440, 0.452), AC, name='hg_ring')
# hand stop under handguard
part(bm_prism([(0.384, 0.0725), (0.410, 0.0725), (0.403, 0.057), (0.391, 0.057)], 'X', -0.0095, 0.0095),
     PO, bevel=0.0018, name='handstop')

# ---------------------------------------------------------------- top rail (picatinny)
part(bm_prism([(-0.0080, 0.1195), (0.0080, 0.1195), (0.0106, 0.1230), (0.0106, 0.1262), (-0.0106, 0.1262),
               (-0.0106, 0.1230)], 'Y', -0.058, 0.452), GM, bevel=0.0007, name='rail')
y = -0.052
teeth = []
while y < 0.446:
    teeth.append(bm_box(-0.0106, 0.0106, y, y + 0.0085, 0.1255, 0.1318))
    y += 0.020
tb = bm_merge(teeth)
bmesh.ops.delete(tb, geom=[f for f in tb.faces if f.normal.z < -0.9], context='FACES')
part(tb, GM, name='teeth')

# ---------------------------------------------------------------- optic (red dot)
part(bm_box(-0.0118, 0.0118, 0.030, 0.086, 0.1255, 0.1445), GM, bevel=0.0018, name='optic_mount')
part(bm_cyl(0.0168, 0.0168, (0, 0.026, 0.159), (0, 0.090, 0.159), sides=12, rot=math.pi / 12), PO,
     bevel=0.0018, name='optic_body')
part(bm_cyl(0.0188, 0.0188, (0, 0.084, 0.159), (0, 0.097, 0.159), sides=12, rot=math.pi / 12), AC,
     bevel=0.0012, name='optic_hood')
part(bm_cyl(0.0060, 0.0060, (0.012, 0.058, 0.159), (0.0225, 0.058, 0.159), sides=8), GM,
     name='optic_knob')
part(bm_cyl(0.0060, 0.0060, (0, 0.058, 0.170), (0, 0.058, 0.1805), sides=8), GM, name='optic_knob2')

# ---------------------------------------------------------------- barrel / muzzle
part(bm_cyl(0.0085, 0.0085, (0, 0.440, ZB), (0, 0.524, ZB), sides=12, caps=False), GM, name='barrel')
part(bm_box(-0.0105, 0.0105, 0.452, 0.468, ZB - 0.013, ZB + 0.012), GM, bevel=0.0015, name='gasblock')
part(bm_cyl(0.0118, 0.0118, (0, 0.522, ZB), (0, 0.538, ZB), sides=12), GM, bevel=0.0012, name='muz1')
part(bm_cyl(0.0098, 0.0098, (0, 0.537, ZB), (0, 0.551, ZB), sides=12, caps=False), GM, name='muz2')
part(bm_cyl(0.0118, 0.0110, (0, 0.550, ZB), (0, 0.565, ZB), sides=12), GM, bevel=0.0012, name='muz3')

# ---------------------------------------------------------------- buffer tube + stock
part(bm_cyl(0.0140, 0.0140, (0, -0.205, ZB), (0, -0.060, ZB), sides=12, caps=False), GM, name='buffer')
part(bm_cyl(0.0168, 0.0168, (0, -0.073, ZB), (0, -0.061, ZB), sides=8, rot=math.pi / 8), GM,
     name='castle')
stock = [(-0.148, 0.118), (-0.148, 0.074), (-0.160, 0.062), (-0.214, 0.046), (-0.256, 0.020), (-0.268, -0.006),
         (-0.270, -0.024), (-0.270, 0.122), (-0.258, 0.130), (-0.220, 0.126), (-0.180, 0.122)]
part(bm_prism(stock, 'X', -0.0165, 0.0165), PO, bevel=0.003, name='stock')
part(bm_prism([(-0.166, 0.111), (-0.252, 0.117), (-0.258, 0.101), (-0.171, 0.097)], 'X', -0.0173, 0.0173), AC,
     bevel=0.0009, name='stock_stripe')
part(bm_prism([(-0.270, 0.124), (-0.270, -0.027), (-0.283, -0.030), (-0.286, -0.020), (-0.286, 0.120),
               (-0.282, 0.128)], 'X', -0.0178, 0.0178), PO, bevel=0.0025, name='buttpad')
# stock latch underneath tube
part(bm_box(-0.006, 0.006, -0.150, -0.125, 0.074, 0.082), GM, bevel=0.001, name='latch')

ob = finalize('Weapon_AR')
empty('Muzzle', (0, 0.565, ZB))
empty('LeftHand', (0, 0.330, ZB - 0.012))
report(ob, 'weapon_ar', 3000)
export('weapon_ar')
