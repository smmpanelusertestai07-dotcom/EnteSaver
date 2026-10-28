"""tree_pine.glb / tree_round.glb - stylized low-poly trees. Origin at trunk base."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import *
from mathutils import noise


def trunk(rings_def, sides=7, seed=0):
    random.seed(seed)
    rings = []
    for (z, r) in rings_def:
        rings.append([(r * math.cos(2 * math.pi * k / sides), r * math.sin(2 * math.pi * k / sides), z) for k in range(sides)])
    return bm_loft(rings, cap0=False, cap1=True)


def pine():
    reset()
    BK = mat('Bark', '#5b3d26', rough=0.9)
    LV = mat('Leaves', '#2e6b37', rough=0.8)
    part(trunk([(0.0, 0.32), (0.35, 0.21), (3.0, 0.16), (7.2, 0.05)]), BK, smooth=70, name='trunk')
    random.seed(3)
    tiers = [(1.45, 2.15, 2.6), (2.75, 1.80, 2.35), (3.95, 1.45, 2.15), (5.05, 1.10, 1.95), (6.05, 0.74, 2.05)]
    n = 14
    for ti, (zb, r, hgt) in enumerate(tiers):
        rot = random.random() * math.pi
        bm = bmesh.new()
        bot, mid, mid2 = [], [], []
        for k in range(n):
            a = rot + 2 * math.pi * k / n
            rr = r * (1.0 if k % 2 == 0 else 0.80) * (0.93 + 0.14 * random.random())
            zz = zb - (0.18 if k % 2 == 0 else 0.02)
            bot.append(bm.verts.new((rr * math.cos(a), rr * math.sin(a), zz)))
            a2 = a + math.pi / n
            mid.append(bm.verts.new((0.70 * r * math.cos(a2), 0.70 * r * math.sin(a2), zb + 0.30 * hgt)))
            mid2.append(bm.verts.new((0.36 * r * math.cos(a), 0.36 * r * math.sin(a), zb + 0.64 * hgt)))
        apex = bm.verts.new((random.uniform(-0.05, 0.05), random.uniform(-0.05, 0.05), zb + hgt))
        under = bm.verts.new((0, 0, zb + 0.30))
        for k in range(n):
            j = (k + 1) % n
            bm.faces.new((bot[k], bot[j], mid[k]))
            bm.faces.new((mid[k], bot[j], mid[j])) if False else None
        # rebuild properly: band bot->mid as quads (mid is rotated half a step)
        for f in list(bm.faces):
            bm.faces.remove(f)
        for k in range(n):
            j = (k + 1) % n
            bm.faces.new((bot[k], bot[j], mid[k]))
            bm.faces.new((mid[k], bot[j], mid[j]))
            bm.faces.new((mid[k], mid[j], mid2[j], mid2[k]))
            bm.faces.new((mid2[k], mid2[j], apex))
            bm.faces.new((bot[j], bot[k], under))
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        part(bm, LV, smooth=55, name='tier')
    ob = finalize('TreePine')
    report(ob, 'tree_pine', 800)
    export('tree_pine')


def round_tree():
    reset()
    BK = mat('Bark', '#5b3d26', rough=0.9)
    LV = mat('Leaves', '#3d7a34', rough=0.8)
    part(trunk([(0.0, 0.30), (0.30, 0.21), (2.4, 0.16), (3.3, 0.12)], seed=1), BK, smooth=70, name='trunk')
    random.seed(11)
    for k in range(3):
        a = 2 * math.pi * k / 3 + 0.4
        p0 = (0, 0, 2.3 + 0.2 * k)
        p1 = (0.45 * math.cos(a), 0.45 * math.sin(a), 3.3 + 0.2 * k)
        p2 = (1.0 * math.cos(a), 1.0 * math.sin(a), 4.3 + 0.15 * k)
        part(bm_tube([p0, p1, p2], [0.12, 0.09, 0.05], sides=5, caps=False), BK, smooth=70, name='branch')
    clumps = [((0.0, 0.0, 5.3), 2.05), ((1.25, 0.45, 4.55), 1.45), ((-1.05, 0.85, 4.65), 1.5), ((0.15, -1.25, 4.55), 1.42),
              ((-0.35, 0.2, 6.45), 1.35), ((0.85, -0.45, 5.95), 1.2)]
    for i, (c, r) in enumerate(clumps):
        bm = bmesh.new()
        bmesh.ops.create_icosphere(bm, subdivisions=2, radius=1.0)
        for v in bm.verts:
            p = v.co.copy()
            nz = noise.noise(p * 1.7 + Vector((i * 3.3, i * 1.1, 0.5)))
            p *= r * (1.0 + 0.16 * nz)
            p.z *= 0.86
            v.co = Vector(c) + p
        part(bm, LV, smooth=40, name='clump')
    ob = finalize('TreeRound')
    report(ob, 'tree_round', 800)
    export('tree_round')


pine()
round_tree()
