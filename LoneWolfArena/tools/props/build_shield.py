"""shield_wall.glb - deployable energy barrier, curved (convex toward +Y), 2.4 x 2.0 x 0.15 m.
Built flat, then bent around a vertical axis. Origin bottom centre of the bbox."""
import sys
sys.path.insert(0, '/root/work/tools/props')
from lib import *
reset()
GL = mat('ShieldGlass', '#8fe9ff', metallic=0.0, rough=0.12, emit='#58d8ff', emit_strength=0.8)
FR = mat('ShieldFrame', '#3b434d', metallic=0.75, rough=0.4)
CH = 2.4                               # chord width
R = 3.7                                # bend radius
HA = math.asin(CH / 2 / R)
LA = 2 * R * HA                        # flat (arc) length
T = 0.15
hl = LA / 2


def bend_obj(ob):
    for v in ob.data.vertices:
        x, y, z = v.co
        phi = x / R
        r = R + y
        v.co = Vector((r * math.sin(phi), r * math.cos(phi) - R, z))


def flat_part(bm, material, bevel=0.0, smooth=60, name='p'):
    ob = bm_to_obj(bm, name, material)
    if bevel > 0:
        m = ob.modifiers.new('Bevel', 'BEVEL'); m.width = bevel; m.segments = 1
        m.limit_method = 'ANGLE'; m.angle_limit = math.radians(30); m.use_clamp_overlap = True
        apply_mods(ob)
    bend_obj(ob)
    shade(ob, smooth, True)
    PARTS.append(ob)
    return ob


def xloft(x0, x1, prof_yz, n):
    rings = []
    for i in range(n + 1):
        x = x0 + (x1 - x0) * i / n
        rings.append([(x, y, z) for (y, z) in prof_yz])
    return bm_loft(rings)


def rect(y0, y1, z0, z1):
    return [(y0, z0), (y1, z0), (y1, z1), (y0, z1)]


# side posts with emitter caps
for sx in (-1, 1):
    x0, x1 = (hl - 0.13, hl) if sx > 0 else (-hl, -hl + 0.13)
    flat_part(bm_box(x0, x1, -T / 2, T / 2, 0.0, 2.0), FR, bevel=0.012, name='post')
    flat_part(bm_box(x0 + 0.02, x1 - 0.02, -T / 2 - 0.0, T / 2 + 0.0, 1.70, 1.80) if False else
              bm_box(x0 + 0.03, x1 - 0.03, -0.05, 0.05, 2.0, 2.0) if False else bm_box(x0 + 0.035, x1 - 0.035, T / 2 - 0.01, T / 2 + 0.0, 0.25, 1.75), GL, name='emitter')
# base beam (chamfered profile) + top bar
base_prof = [(-T / 2, 0.0), (T / 2, 0.0), (T / 2, 0.13), (T / 2 - 0.035, 0.18), (-T / 2 + 0.035, 0.18), (-T / 2, 0.13)]
flat_part(xloft(-hl + 0.12, hl - 0.12, base_prof, 16), FR, bevel=0.008, name='base')
top_prof = [(-0.05, 1.93), (0.05, 1.93), (0.05, 1.975), (0.03, 2.0), (-0.03, 2.0), (-0.05, 1.975)]
flat_part(xloft(-hl + 0.12, hl - 0.12, top_prof, 16), FR, name='topbar')
# thin glass sheet
flat_part(xloft(-hl + 0.12, hl - 0.12, rect(-0.018, 0.018, 0.17, 1.94), 16), GL, smooth=40, name='sheet')
# hex tiles (flat-top), slightly thicker than the sheet
rh, gap = 0.165, 0.028
tile_r = rh - gap / math.sqrt(3)
dx, dz = 1.5 * rh, math.sqrt(3) * rh
x_lo, x_hi, z_lo, z_hi = -hl + 0.13, hl - 0.13, 0.19, 1.92
tiles = []
ncols = int((x_hi - x_lo) / dx) + 2
for ci in range(-ncols, ncols + 1):
    cx = ci * dx
    for ri in range(-2, 12):
        cz = 0.19 + dz / 2 + ri * dz + (dz / 2 if ci % 2 else 0)
        pts = [(cx + tile_r * math.cos(math.radians(60 * k)), cz + tile_r * math.sin(math.radians(60 * k))) for k in range(6)]
        if all(x_lo <= px <= x_hi and z_lo <= pz <= z_hi for px, pz in pts):
            tiles.append(bm_prism(pts, 'Y', -0.042, 0.042))
flat_part(bm_merge(tiles), GL, smooth=30, name='hex')
ob = PARTS[0]
ob = finalize('ShieldWall')
vs = [v.co for v in ob.data.vertices]
cy = (min(v.y for v in vs) + max(v.y for v in vs)) / 2
ob.data.transform(Matrix.Translation((0, -cy, 0)))
box_uv(ob)
print('hex tiles:', len(tiles))
report(ob, 'shield_wall', 2000)
export('shield_wall')
