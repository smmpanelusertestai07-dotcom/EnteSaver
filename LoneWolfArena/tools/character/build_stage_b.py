"""Stage B: turn the MPFB scene into game-ready meshes.
 - bake MakeHuman targets, delete helper geometry, strip MPFB extras
 - rename Root -> root
 - ROOKIE shorts: cut the wool pants above the knee (with a folded hem)
 - subdivide the very low-poly cargo pants, decimate heavy meshes (symmetric collapse)
 - limit weights to 4 / normalise
 - paint a dark short-hair tone on the scalp under the hair cards
 - split body into 8 skinned parts by dominant bone weights, with custom normals copied
   from the unsplit body so the seams are invisible
 - simple Principled BSDF materials with processed, downscaled textures
 - per-bundle coverage analysis -> which body parts can be hidden
Saves WORK/stage_b.blend and WORK/coverage.json"""
import os
import sys
import json
import math
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import bmesh
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree
from PIL import Image, ImageDraw

import char_config as CFG
import textures as TX

t0 = time.time()
bpy.ops.wm.open_mainfile(filepath=os.path.join(CFG.WORK, "stage_a.blend"))
arm = bpy.data.objects["Armature"]
body = bpy.data.objects["Human"]

# ----------------------------------------------------------------------------- helpers


def override(ob):
    return bpy.context.temp_override(object=ob, active_object=ob, selected_objects=[ob],
                                     selected_editable_objects=[ob])


def tri_count(ob):
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


def apply_shape_keys(ob):
    if ob.data.shape_keys:
        bpy.context.view_layer.objects.active = ob
        with override(ob):
            bpy.ops.object.shape_key_remove(all=True, apply_mix=True)


def strip_modifiers(ob):
    for m in list(ob.modifiers):
        ob.modifiers.remove(m)


def apply_modifier(ob, mod):
    bpy.context.view_layer.objects.active = ob
    with override(ob):
        bpy.ops.object.modifier_apply(modifier=mod.name)


BONES = set(b.name for b in arm.data.bones)
if "Root" in arm.data.bones:
    arm.data.bones["Root"].name = "root"
    BONES = set(b.name for b in arm.data.bones)


def clean_vgroups(ob, keep_delete=False):
    for g in list(ob.vertex_groups):
        if g.name == "Root":
            g.name = "root"
        if keep_delete and g.name.startswith("Delete."):
            continue
        if g.name not in BONES:
            ob.vertex_groups.remove(g)


def decimate(ob, target_tris, symmetric=True, vgroup=None, factor=1.0):
    n = tri_count(ob)
    if n <= target_tris:
        return n
    m = ob.modifiers.new("Decimate", 'DECIMATE')
    m.decimate_type = 'COLLAPSE'
    m.ratio = target_tris / n
    m.use_symmetry = symmetric
    m.symmetry_axis = 'X'
    m.use_collapse_triangulate = False
    if vgroup:
        m.vertex_group = vgroup
        m.vertex_group_factor = factor
    apply_modifier(ob, m)
    return tri_count(ob)


def limit_normalize(ob, limit=4):
    me = ob.data
    nv = len(me.vertices)
    gidx = {g.index: g.name for g in ob.vertex_groups}
    bone_gi = set(g.index for g in ob.vertex_groups if g.name in BONES)
    for v in me.vertices:
        ws = [(g.group, g.weight) for g in v.groups if g.weight > 1e-4 and g.group in bone_gi]
        ws.sort(key=lambda x: -x[1])
        keep = ws[:limit]
        tot = sum(w for _, w in keep)
        drop = [gi for gi, _ in ws[limit:]] + [g.group for g in v.groups if g.weight <= 1e-4 and g.group in bone_gi]
        for gi in drop:
            ob.vertex_groups[gi].remove([v.index])
        if tot > 0:
            for gi, w in keep:
                ob.vertex_groups[gi].add([v.index], w / tot, 'REPLACE')
        else:
            # unweighted vertex: bind to nearest sensible bone later (head for face parts)
            pass


def world_co(ob):
    me = ob.data
    co = np.empty(len(me.vertices) * 3, dtype=np.float64)
    me.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    M = np.array(ob.matrix_world)
    return co @ M[:3, :3].T + M[:3, 3]


# ----------------------------------------------------------------------------- body cleanup
apply_shape_keys(body)
strip_modifiers(body)
me = body.data
vg_body = body.vertex_groups["body"].index
keep = np.zeros(len(me.vertices), dtype=bool)
for v in me.vertices:
    for g in v.groups:
        if g.group == vg_body and g.weight > 0.5:
            keep[v.index] = True
bm = bmesh.new()
bm.from_mesh(me)
bm.verts.ensure_lookup_table()
bmesh.ops.delete(bm, geom=[bm.verts[i] for i in np.where(~keep)[0]], context='VERTS')
bm.to_mesh(me)
bm.free()
clean_vgroups(body, keep_delete=True)
print("body verts", len(me.vertices), "tris", tri_count(body))

# ----------------------------------------------------------------------------- other meshes
others = [o for o in bpy.data.objects if o.type == 'MESH' and o != body]
for ob in others:
    apply_shape_keys(ob)
    strip_modifiers(ob)
    clean_vgroups(ob)
    ob.parent = None
    ob.matrix_world = ob.matrix_world.copy()

# --- consistent outward winding for garments (some source meshes contain flipped faces that a
#     single-sided game material would cull, showing as holes)
for ob in [o for o in others if o.name.startswith("Outfit_")]:
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    bm.to_mesh(ob.data)
    bm.free()
    ob.data.update()

# knee height from the rig
knee_z = (arm.matrix_world @ arm.data.bones["calf_l"].head_local).z
ankle_z = (arm.matrix_world @ arm.data.bones["foot_l"].head_local).z
print("knee z %.3f ankle z %.3f" % (knee_z, ankle_z))

# --- ROOKIE shorts: cut the wool pants above the knee + inward folded hem
sh = bpy.data.objects["Outfit_default_Shorts"]
cut_z = knee_z + 0.075
bm = bmesh.new()
bm.from_mesh(sh.data)
bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], plane_co=(0, 0, cut_z),
                       plane_no=(0, 0, 1), clear_inner=True)
bm.normal_update()
boundary = [e for e in bm.edges if e.is_boundary and all(abs(v.co.z - cut_z) < 0.01 for v in e.verts)]
res = bmesh.ops.extrude_edge_only(bm, edges=boundary)
new_verts = [g for g in res["geom"] if isinstance(g, bmesh.types.BMVert)]
for v in new_verts:
    # move inward (towards the leg centre) and up: an inner hem visible from below
    cx = 0.10 if v.co.x > 0 else -0.10
    d = Vector((cx - v.co.x, 0.0 - v.co.y, 0.0))
    d.z = 0
    if d.length > 1e-6:
        d.normalize()
    v.co += d * 0.006 + Vector((0, 0, 0.025))
bm.to_mesh(sh.data)
bm.free()
print("shorts cut at %.3f, tris %d" % (cut_z, tri_count(sh)))

# --- subdivide the very low-poly cargo pants (MPFB would subdivide them at render time)
for name in ["Outfit_desert_Pants", "Outfit_shadow_Pants"]:
    ob = bpy.data.objects[name]
    m = ob.modifiers.new("Subsurf", 'SUBSURF')
    m.levels = 1
    m.render_levels = 1
    m.quality = 3
    apply_modifier(ob, m)
    # compensate subdivision shrink: push 4 mm along normals
    me2 = ob.data
    for v in me2.vertices:
        v.co += v.normal * 0.004
    print(name, "subdivided ->", tri_count(ob))

# --- helmet: remove the dense camouflage-net shell (largest loose part), keep shell/band/strap/buckles
hel = bpy.data.objects["Outfit_shadow_Helmet"]
bm = bmesh.new()
bm.from_mesh(hel.data)
bm.verts.ensure_lookup_table()
seen = set()
comps = []
for v in bm.verts:
    if v.index in seen:
        continue
    stack, comp = [v], []
    seen.add(v.index)
    while stack:
        x = stack.pop()
        comp.append(x)
        for e in x.link_edges:
            o = e.other_vert(x)
            if o.index not in seen:
                seen.add(o.index)
                stack.append(o)
    comps.append(comp)
comps.sort(key=len, reverse=True)
if len(comps[0]) > 20000:
    bmesh.ops.delete(bm, geom=comps[0], context='VERTS')
bm.to_mesh(hel.data)
bm.free()
print("helmet after net removal tris", tri_count(hel))

# --- eyes: delete the cornea shell (faces whose UVs sample the transparent part of the iris texture)
eyes_ob = bpy.data.objects["Eyes"]
eye_rgba = TX.load_rgba(CFG.EYE_TEXTURE)
eh, ew = eye_rgba.shape[:2]
emesh = eyes_ob.data
euv = emesh.uv_layers.active.data
kill = []
for p in emesh.polygons:
    u = sum(euv[li].uv[0] for li in p.loop_indices) / p.loop_total
    v = sum(euv[li].uv[1] for li in p.loop_indices) / p.loop_total
    px = min(ew - 1, max(0, int(u * ew)))
    py = min(eh - 1, max(0, int((1 - v) * eh)))
    if eye_rgba[py, px, 3] < 0.5:
        kill.append(p.index)
bm = bmesh.new()
bm.from_mesh(emesh)
bm.faces.ensure_lookup_table()
bmesh.ops.delete(bm, geom=[bm.faces[i] for i in kill], context='FACES')
bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context='VERTS')
bm.to_mesh(emesh)
bm.free()
print("eyes: removed %d cornea faces, tris now %d" % (len(kill), tri_count(eyes_ob)))

# --- face mask: pull it 55%% of the way towards a 7 mm offset from the face so it reads as fitted
mask_ob = bpy.data.objects.get("Outfit_neon_Mask")
if mask_ob is not None:
    face_bvh = BVHTree.FromObject(body, bpy.context.evaluated_depsgraph_get())
    mw = mask_ob.matrix_world
    for v in mask_ob.data.vertices:
        w = mw @ v.co
        loc, nrm_, idx_, dist = face_bvh.find_nearest(w)
        if loc is None or dist > 0.08:
            continue
        target = loc + (w - loc).normalized() * 0.007
        v.co = mw.inverted() @ (w.lerp(target, 0.55))

# --- helmet: make it a deeper M1-style shell (stretch downwards from the crown), strap unscaled
hel = bpy.data.objects["Outfit_shadow_Helmet"]
bm = bmesh.new()
bm.from_mesh(hel.data)
bm.verts.ensure_lookup_table()
seen = set()
for v in bm.verts:
    if v.index in seen:
        continue
    stack, comp = [v], []
    seen.add(v.index)
    while stack:
        x = stack.pop()
        comp.append(x)
        for e in x.link_edges:
            o = e.other_vert(x)
            if o.index not in seen:
                seen.add(o.index)
                stack.append(o)
    if min(c.co.z for c in comp) < 1.60:      # chin strap: leave as is
        continue
    for c in comp:
        c.co.x = c.co.x * 1.10
        c.co.y = -0.061 + (c.co.y + 0.061) * 1.08
        c.co.z = 1.797 + (c.co.z - 1.797) * 1.25
bm.to_mesh(hel.data)
bm.free()


def resolve_layers(outer, inner, margin=0.006, reach=0.03):
    """Push vertices of `outer` garment outside the `inner` garment surface (rest pose)."""
    dg = bpy.context.evaluated_depsgraph_get()
    bvh = BVHTree.FromObject(inner, dg)
    me_ = outer.data
    n = len(me_.vertices)
    push = np.zeros(n)
    dirs = np.zeros((n, 3))
    for v in me_.vertices:
        loc, nrm_, idx_, dist = bvh.find_nearest(v.co, reach)
        if loc is None:
            continue
        side = (v.co - loc).dot(nrm_)
        if side < margin:
            push[v.index] = margin - side
            # push along the garment's own normal (pushing along the inner surface normal can fold
            # faces inside concavities such as the navel); fall back to the inner normal
            vn = v.normal
            dirs[v.index] = vn if vn.dot(nrm_) > 0.3 else nrm_
    # falloff to neighbours so the push is smooth
    adj = [[] for _ in range(n)]
    for e in me_.edges:
        a, b = e.vertices
        adj[a].append(b)
        adj[b].append(a)
    for it in range(4):
        newp = push.copy()
        for i in range(n):
            if adj[i]:
                m = max(push[j] for j in adj[i]) * 0.6
                if m > newp[i]:
                    newp[i] = m
                    if not dirs[i].any():
                        j = max(adj[i], key=lambda j: push[j])
                        dirs[i] = dirs[j]
        push = newp
    cnt = 0
    for v in me_.vertices:
        if push[v.index] > 0 and dirs[v.index].any():
            v.co += Vector(dirs[v.index]) * push[v.index]
            cnt += 1
    print("resolve_layers %s over %s: moved %d verts" % (outer.name, inner.name, cnt))


def fix_dents(ob, thresh=0.006, iters=4):
    """Pull vertices that sit noticeably inward of their neighbours (e.g. pinned into the navel
    cavity by the clothes fitting) back to the neighbour average."""
    me_ = ob.data
    adj = [[] for _ in me_.vertices]
    for e in me_.edges:
        a, b = e.vertices
        adj[a].append(b)
        adj[b].append(a)
    moved = 0
    for it in range(iters):
        me_.update()
        co = [v.co.copy() for v in me_.vertices]
        for v in me_.vertices:
            if len(adj[v.index]) < 3:
                continue
            avg = sum((co[j] for j in adj[v.index]), Vector()) / len(adj[v.index])
            d = (avg - co[v.index]).dot(v.normal)
            if d > thresh:
                v.co = co[v.index].lerp(avg, 0.85)
                moved += 1
    print("fix_dents %s: %d moves" % (ob.name, moved))


for ob in [o for o in bpy.data.objects if o.name.startswith("Outfit_")]:
    fix_dents(ob)

for outer_n, inner_n in [("Outfit_default_Top", "Outfit_default_Shorts"), ("Outfit_desert_Shirt", "Outfit_desert_Pants"),
                         ("Outfit_shadow_Top", "Outfit_shadow_Pants"), ("Outfit_desert_Pants", "Outfit_desert_Boots"),
                         ("Outfit_shadow_Pants", "Outfit_shadow_Boots"), ("Outfit_shadow_Top", "Outfit_shadow_Gloves")]:
    resolve_layers(bpy.data.objects[outer_n], bpy.data.objects[inner_n])

# --- footwear: lift so the sole sits exactly on Z=0 (feet are always hidden under footwear)
for nm in [o.name for o in bpy.data.objects if o.name.startswith("Outfit_") and o.name.split("_")[-1] in ("Shoes", "Boots")]:
    ob = bpy.data.objects[nm]
    mz = min(v.co.z for v in ob.data.vertices)
    if mz < -0.002:
        for v in ob.data.vertices:
            v.co.z -= mz
        print("lifted %s by %.3f m" % (nm, -mz))

# --- decimate heavy meshes
DEC_TARGETS = {
    "Outfit_shadow_Helmet": 2600, "Outfit_desert_Cap": 1800, "Outfit_royal_Suit": 7600, "Outfit_desert_Shirt": 3000,
    "Outfit_shadow_Gloves": 1800, "Outfit_desert_Boots": 2400, "Outfit_shadow_Boots": 2400,
    "Outfit_royal_Shoes": 2200, "Outfit_default_Shoes": 2200, "Outfit_neon_Shoes": 2200,
    "Outfit_neon_Jacket": 5200, "Outfit_shadow_Top": 3600, "Hair_Default": 3500,
}
for name, tgt in DEC_TARGETS.items():
    ob = bpy.data.objects.get(name)
    if ob is None:
        continue
    before = tri_count(ob)
    after = decimate(ob, tgt, symmetric=True)
    print("decimate %s %d -> %d" % (name, before, after))

# --- body decimation by region (hands / head+neck / rest), each pass only touches its region
def region_of_vertex(v, gnames):
    acc = {"hands": 0.0, "head": 0.0, "rest": 0.0}
    for g in v.groups:
        n = gnames.get(g.group)
        if n is None or n not in BONES:
            continue
        if n.startswith(CFG.HAND_BONE_PREFIXES):
            acc["hands"] += g.weight
        elif n in ("head", "neck_01"):
            acc["head"] += g.weight
        elif n.startswith(("foot_", "ball_")):
            acc["feet"] = acc.get("feet", 0.0) + g.weight
        else:
            acc["rest"] += g.weight
    return max(acc, key=acc.get)


def region_tris(ob, region):
    gn = {g.index: g.name for g in ob.vertex_groups}
    reg = [region_of_vertex(v, gn) for v in ob.data.vertices]
    n = 0
    for p in ob.data.polygons:
        if all(reg[i] == region for i in p.vertices):
            n += len(p.vertices) - 2
    return n, reg


REGION_TARGETS = [("hands", 3900), ("head", 6900), ("feet", 1000), ("rest", 8700)]
before = tri_count(body)
for region, tgt in REGION_TARGETS:
    cur, reg = region_tris(body, region)
    if cur <= tgt:
        continue
    vg = body.vertex_groups.new(name="_decimate")
    for v in body.data.vertices:
        vg.add([v.index], 1.0 if reg[v.index] == region else 0.0, 'REPLACE')
    total = tri_count(body)
    want = total - (cur - tgt)
    m = body.modifiers.new("Decimate", 'DECIMATE')
    m.decimate_type = 'COLLAPSE'
    m.ratio = want / total
    m.use_symmetry = True
    m.symmetry_axis = 'X'
    m.vertex_group = "_decimate"
    m.vertex_group_factor = 1.0
    apply_modifier(body, m)
    body.vertex_groups.remove(body.vertex_groups["_decimate"])
    print("body region %s: %d -> %d (total %d)" % (region, cur, region_tris(body, region)[0], tri_count(body)))
print("decimate body %d -> %d" % (before, tri_count(body)))

# --- garments vs the final (decimated) body: push garment verts that sit inside the skin outwards
for gname in ["Outfit_default_Top", "Outfit_default_Shorts", "Outfit_desert_Shirt", "Outfit_desert_Pants",
              "Outfit_neon_Jacket", "Outfit_shadow_Top", "Outfit_shadow_Pants", "Outfit_royal_Suit",
              "Outfit_shadow_Gloves", "Outfit_neon_Mask"]:
    resolve_layers(bpy.data.objects[gname], body, margin=0.007, reach=0.03)
# the thin, skin-tight ROOKIE tee: inflate it away from the skin so it never intersects when posed
def inflate_from_body(ob, amount):
    bvh_b = BVHTree.FromObject(body, bpy.context.evaluated_depsgraph_get())
    for v in ob.data.vertices:
        loc, nrm_, idx_, dist = bvh_b.find_nearest(v.co, 0.15)
        if loc is None:
            continue
        d = (v.co - loc)
        dirv = d.normalized() if d.length > 0.001 and d.normalized().dot(nrm_) > 0 else nrm_
        v.co += dirv * amount


inflate_from_body(bpy.data.objects["Outfit_default_Top"], 0.008)

# re-run the garment-over-garment pass so the outer layers stay outside after the body pass
for outer_n, inner_n in [("Outfit_default_Top", "Outfit_default_Shorts"), ("Outfit_desert_Shirt", "Outfit_desert_Pants"),
                         ("Outfit_shadow_Top", "Outfit_shadow_Pants")]:
    resolve_layers(bpy.data.objects[outer_n], bpy.data.objects[inner_n], margin=0.012, reach=0.045)

# --- inner garments: delete faces that are deeply covered by the outer garment (the outer layer
#     extends >= 4.5 cm below them), so waistbands can never poke through shirt hems when posed
def cull_hidden_inner(inner, outer, below=0.03, reach=0.06):
    dg = bpy.context.evaluated_depsgraph_get()
    bvh = BVHTree.FromObject(outer, dg)
    me_ = inner.data
    cov = np.zeros(len(me_.vertices), dtype=bool)
    for v in me_.vertices:
        n = v.normal
        ok = True
        for dz in (0.0, -below):
            o = v.co + Vector((0, 0, dz)) - n * 0.002
            if bvh.ray_cast(o, n, reach)[0] is None:
                ok = False
                break
        cov[v.index] = ok
    bm_ = bmesh.new()
    bm_.from_mesh(me_)
    bm_.faces.ensure_lookup_table()
    kill = [f for f in bm_.faces if all(cov[v.index] for v in f.verts)]
    bmesh.ops.delete(bm_, geom=kill, context='FACES')
    bmesh.ops.delete(bm_, geom=[v for v in bm_.verts if not v.link_faces], context='VERTS')
    bm_.to_mesh(me_)
    bm_.free()
    print("cull_hidden_inner %s under %s: removed %d faces" % (inner.name, outer.name, len(kill)))


for inner_n, outer_n in [("Outfit_default_Shorts", "Outfit_default_Top"), ("Outfit_desert_Pants", "Outfit_desert_Shirt"),
                         ("Outfit_shadow_Pants", "Outfit_shadow_Top")]:
    cull_hidden_inner(bpy.data.objects[inner_n], bpy.data.objects[outer_n])

# --- reverse pass: body vertices that poke through the interior of (large) garment faces push
#     that face's vertices outwards
def resolve_inner_points(outer, inner, margin=0.006, reach=0.04, iters=3):
    me_o = outer.data
    ivs = inner.data.vertices
    for it in range(iters):
        me_o.update()
        bvh_o = BVHTree.FromObject(outer, bpy.context.evaluated_depsgraph_get())
        push = {}
        for v in ivs:
            loc, n_o, fidx, dist = bvh_o.find_nearest(v.co, reach)
            if loc is None:
                continue
            n_out = v.normal
            side = (v.co - loc).dot(n_out)          # > 0: body point is outside the garment surface
            if side > -margin:
                amt = side + margin
                for vi in me_o.polygons[fidx].vertices:
                    if amt > push.get(vi, (0.0, None))[0]:
                        push[vi] = (amt, n_out.copy())
        for vi, (amt, d) in push.items():
            me_o.vertices[vi].co += d * amt
        print("resolve_inner_points %s (pass %d): pushed %d verts" % (outer.name, it, len(push)))
        if not push:
            break


for nm in ["Outfit_default_Top", "Outfit_desert_Shirt", "Outfit_shadow_Top", "Outfit_neon_Jacket", "Outfit_royal_Suit",
           "Outfit_default_Shorts", "Outfit_desert_Pants", "Outfit_shadow_Pants"]:
    resolve_inner_points(bpy.data.objects[nm], body)
for outer_n, inner_n in [("Outfit_default_Top", "Outfit_default_Shorts"), ("Outfit_desert_Shirt", "Outfit_desert_Pants"),
                         ("Outfit_shadow_Top", "Outfit_shadow_Pants")]:
    resolve_inner_points(bpy.data.objects[outer_n], bpy.data.objects[inner_n], margin=0.006, iters=2)

# --- tight tops: copy skin weights from the nearest body surface so they deform exactly with the
#     skin underneath (keeps the rest-pose clearance in every pose)
def transfer_weights_from_body(ob, max_dist=0.08):
    bvh_b = BVHTree.FromObject(body, bpy.context.evaluated_depsgraph_get())
    bgn = {g.index: g.name for g in body.vertex_groups if g.name in BONES}
    bw = [dict() for _ in body.data.vertices]
    for v in body.data.vertices:
        for g in v.groups:
            if g.group in bgn and g.weight > 1e-4:
                bw[v.index][bgn[g.group]] = g.weight
    newval = {}
    for v in ob.data.vertices:
        loc, nrm_, fidx, dist = bvh_b.find_nearest(v.co, max_dist)
        if loc is None:
            continue
        poly = body.data.polygons[fidx]
        acc = {}
        tw = 0.0
        for vi in poly.vertices:
            w = 1.0 / max(1e-4, (body.data.vertices[vi].co - loc).length)
            tw += w
            for n, x in bw[vi].items():
                acc[n] = acc.get(n, 0.0) + x * w
        newval[v.index] = {n: x / tw for n, x in acc.items()}
    for g in list(ob.vertex_groups):
        if g.name in BONES:
            ob.vertex_groups.remove(g)
    for vi, ws in newval.items():
        for n, x in ws.items():
            g = ob.vertex_groups.get(n) or ob.vertex_groups.new(name=n)
            g.add([vi], x, 'REPLACE')
    print("transfer_weights_from_body %s: %d verts" % (ob.name, len(newval)))


for nm in ["Outfit_default_Top", "Outfit_desert_Shirt", "Outfit_shadow_Top"]:
    transfer_weights_from_body(bpy.data.objects[nm])

# triangulate nothing; limit/normalise weights everywhere
for ob in [body] + others:
    limit_normalize(ob)

# ----------------------------------------------------------------------------- skin texture + scalp
skin, ref = TX.grade_skin(CFG.SKIN_SRC)
H, W = skin.shape[:2]
print("skin ref colour", ref)

hair = bpy.data.objects["Hair_Default"]
hair_bvh = BVHTree.FromObject(hair, bpy.context.evaluated_depsgraph_get())
bco = world_co(body)
bme = body.data
bme.update()
nrm = np.empty(len(bme.vertices) * 3)
bme.vertices.foreach_get("normal", nrm)
nrm = nrm.reshape(-1, 3)
head_z = (arm.matrix_world @ arm.data.bones["head"].head_local).z
covered = np.zeros(len(bco))
for i in np.where(bco[:, 2] > head_z)[0]:
    o = Vector(bco[i]) - Vector(nrm[i]) * 0.002
    hit = hair_bvh.ray_cast(o, Vector(nrm[i]), 0.06)
    if hit[0] is not None:
        covered[i] = 1.0
uv = bme.uv_layers.active.data
mask_im = Image.new("L", (W, H), 0)
dr = ImageDraw.Draw(mask_im)
for p in bme.polygons:
    vals = [covered[bme.loops[li].vertex_index] for li in p.loop_indices]
    val = sum(vals) / len(vals)
    if val <= 0:
        continue
    pts = [(uv[li].uv[0] * W, (1 - uv[li].uv[1]) * H) for li in p.loop_indices]
    dr.polygon(pts, fill=int(val * 255))
from PIL import ImageFilter
mask = np.asarray(mask_im.filter(ImageFilter.GaussianBlur(22))).astype(np.float32) / 255.0
mask = np.clip((mask - 0.25) / 0.5, 0, 1)
mask = mask * mask * (3 - 2 * mask)   # smoothstep -> soft, clean hairline
skin = TX.paint_scalp(skin, mask)
print("scalp verts covered", int(covered.sum()))

# ----------------------------------------------------------------------------- body split
# store original (full body) vertex normals
full_normals = nrm.copy()
oi = bme.attributes.new("orig_idx", 'INT', 'POINT')
oi.data.foreach_set("value", np.arange(len(bme.vertices), dtype=np.int32))

gnames = {g.index: g.name for g in body.vertex_groups}
part_names = CFG.BODY_PARTS
pidx = {n: i for i, n in enumerate(part_names)}
vpart = np.zeros((len(bme.vertices), len(part_names)))
for v in bme.vertices:
    for g in v.groups:
        if gnames[g.group] in BONES:
            vpart[v.index, pidx[CFG.part_for_bone(gnames[g.group])]] += g.weight
fpart = np.zeros(len(bme.polygons), dtype=np.int32)
fscore = np.zeros((len(bme.polygons), len(part_names)))
for p in bme.polygons:
    s = vpart[list(p.vertices)].sum(axis=0)
    fscore[p.index] = s
    fpart[p.index] = int(np.argmax(s))
# majority smoothing over edge-adjacent faces (removes jagged islands)
edge_faces = {}
for p in bme.polygons:
    for ek in p.edge_keys:
        edge_faces.setdefault(ek, []).append(p.index)
nbrs = [[] for _ in bme.polygons]
for fl in edge_faces.values():
    if len(fl) == 2:
        a, b = fl
        nbrs[a].append(b)
        nbrs[b].append(a)
for it in range(3):
    newp = fpart.copy()
    for f in range(len(fpart)):
        if not nbrs[f]:
            continue
        cnt = np.bincount(fpart[nbrs[f]], minlength=len(part_names))
        best = int(np.argmax(cnt))
        if best != fpart[f] and cnt[best] > len(nbrs[f]) / 2 and fscore[f, best] > 0.05:
            newp[f] = best
    fpart = newp
print("faces per part", {part_names[i]: int((fpart == i).sum()) for i in range(len(part_names))})

parts = {}
for i, pname in enumerate(part_names):
    ob = body.copy()
    ob.data = body.data.copy()
    ob.name = pname
    ob.data.name = pname
    bpy.context.scene.collection.objects.link(ob)
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    bm.faces.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[f for f in bm.faces if fpart[f.index] != i], context='FACES')
    loose = [v for v in bm.verts if not v.link_faces]
    bmesh.ops.delete(bm, geom=loose, context='VERTS')
    bm.to_mesh(ob.data)
    bm.free()
    m2 = ob.data
    idx = np.empty(len(m2.vertices), dtype=np.int32)
    m2.attributes["orig_idx"].data.foreach_get("value", idx)
    m2.normals_split_custom_set_from_vertices([Vector(full_normals[j]) for j in idx])
    m2.attributes.remove(m2.attributes["orig_idx"])
    parts[pname] = ob
bpy.data.objects.remove(body, do_unlink=True)

# ----------------------------------------------------------------------------- materials


def make_mat(name, tex=None, color=(1, 1, 1, 1), alpha=False, rough=0.8, metal=0.0, double=False, spec=0.5):
    mat = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    p = nt.nodes.new("ShaderNodeBsdfPrincipled")
    p.location = (-300, 0)
    out.location = (100, 0)
    nt.links.new(p.outputs[0], out.inputs[0])
    p.inputs["Base Color"].default_value = color
    p.inputs["Roughness"].default_value = rough
    p.inputs["Metallic"].default_value = metal
    if "Specular IOR Level" in p.inputs:
        p.inputs["Specular IOR Level"].default_value = spec
    if tex:
        img = bpy.data.images.load(tex, check_existing=True)
        t = nt.nodes.new("ShaderNodeTexImage")
        t.image = img
        t.location = (-700, 0)
        nt.links.new(t.outputs["Color"], p.inputs["Base Color"])
        if alpha:
            mth = nt.nodes.new("ShaderNodeMath")
            mth.operation = 'GREATER_THAN'
            mth.inputs[1].default_value = 0.5
            mth.location = (-480, -200)
            nt.links.new(t.outputs["Alpha"], mth.inputs[0])
            nt.links.new(mth.outputs[0], p.inputs["Alpha"])
    mat.use_backface_culling = not double
    try:
        mat.surface_render_method = 'DITHERED'
    except Exception:
        pass
    return mat


def set_mat(ob, mat):
    ob.data.materials.clear()
    ob.data.materials.append(mat)
    for p in ob.data.polygons:
        p.material_index = 0


# skin: body atlas 1024 + head crop
skin_body_path = TX.save(skin, "skin_body", 1024, quality=90)
M_SKIN = make_mat("M_Skin_Body", skin_body_path, rough=0.55, spec=0.45)
for pname, ob in parts.items():
    set_mat(ob, M_SKIN)

head = parts["Body_Head"]
hm = head.data
huv = hm.uv_layers.active.data
head_faces = []
for p in hm.polygons:
    c = sum((huv[li].uv[0] for li in p.loop_indices)) / p.loop_total
    if c > 0.55:
        head_faces.append(p.index)
us = [huv[li].uv[0] for f in head_faces for li in hm.polygons[f].loop_indices]
vs = [huv[li].uv[1] for f in head_faces for li in hm.polygons[f].loop_indices]
u0, u1, v0, v1 = min(us) - 0.004, max(us) + 0.004, min(vs) - 0.004, max(vs) + 0.004
u0, v0 = max(0.0, u0), max(0.0, v0)
u1, v1 = min(1.0, u1), min(1.0, v1)
print("head uv box", u0, u1, v0, v1)
x0, x1 = int(u0 * W), int(math.ceil(u1 * W))
y0, y1 = int((1 - v1) * H), int(math.ceil((1 - v0) * H))
crop = skin[y0:y1, x0:x1]
skin_head_path = TX.save(crop, "skin_head", 1024, quality=92)
# exact UV box of the crop in pixel units
cu0, cu1 = x0 / W, x1 / W
cv0, cv1 = 1 - y1 / H, 1 - y0 / H
M_HEAD = make_mat("M_Skin_Head", skin_head_path, rough=0.5, spec=0.45)
hm.materials.append(M_HEAD)
done = set()
for f in head_faces:
    p = hm.polygons[f]
    p.material_index = 1
    for li in p.loop_indices:
        if li in done:
            continue
        done.add(li)
        u, v = huv[li].uv
        huv[li].uv = ((u - cu0) / (cu1 - cu0), (v - cv0) / (cv1 - cv0))
# loops shared between head-island faces and others are not possible (UVs are per loop), fine.

# eyes / brows / lashes / hair
eyes = bpy.data.objects["Eyes"]
eye_tex = TX.load_rgba(CFG.EYE_TEXTURE)
eye_tex[..., 3] = 1.0
set_mat(eyes, make_mat("M_Eyes", TX.save(eye_tex, "eyes", 512, quality=92), rough=0.15, spec=0.6))


def mhmat_textures(mhclo_path):
    d = os.path.dirname(mhclo_path)
    mat = None
    for line in open(mhclo_path, errors="ignore"):
        if line.startswith("material "):
            mat = os.path.join(d, line.split(None, 1)[1].strip())
    tex = {}
    if mat and os.path.exists(mat):
        md = os.path.dirname(mat)
        for line in open(mat, errors="ignore"):
            parts_ = line.strip().split(None, 1)
            if len(parts_) == 2 and parts_[0] in ("diffuseTexture", "normalmapTexture"):
                tex[parts_[0]] = os.path.join(md, parts_[1].strip())
    return tex


brow = bpy.data.objects["Eyebrows"]
t = mhmat_textures(CFG.BODYPARTS["Eyebrows"])["diffuseTexture"]
a = TX.load_rgba(t)
a[..., 3] = np.clip(a[..., 3] * 1.6, 0, 1)        # slightly bolder brows after alpha clipping
a[..., :3] = np.array([0.05, 0.038, 0.03]) * (0.7 + 0.6 * TX.luminance(a[..., :3])[..., None])
set_mat(brow, make_mat("M_Eyebrows", TX.save(a, "eyebrows", 256, alpha=True), alpha=True, rough=0.9, double=True))

lash = bpy.data.objects["Eyelashes"]
t = mhmat_textures(CFG.BODYPARTS["Eyelashes"])["diffuseTexture"]
a = TX.load_rgba(t)
a[..., :3] = np.array([0.03, 0.025, 0.02])
set_mat(lash, make_mat("M_Eyelashes", TX.save(a, "eyelashes", 256, alpha=True), alpha=True, rough=0.9, double=True))

t = mhmat_textures(CFG.BODYPARTS["Hair"])["diffuseTexture"]
a = TX.load_rgba(t)
lum = TX.luminance(a[..., :3])
lum = lum / max(np.percentile(lum[a[..., 3] > 0.5], 90), 1e-3)
base = np.array([0.055, 0.04, 0.03])
a[..., :3] = np.clip(base[None, None, :] * (0.55 + 0.9 * lum[..., None]), 0, 1)
set_mat(hair, make_mat("M_Hair", TX.save(a, "hair", 512, alpha=True), alpha=True, rough=0.6, double=True, spec=0.35))

# ----------------------------------------------------------------------------- clothes materials
import recolor  # noqa: E402  (bundle specific recolour recipes)
for ob in [o for o in bpy.data.objects if o.name.startswith("Outfit_")]:
    texs = mhmat_textures(ob["mhclo"])
    spec_ = recolor.recipe(ob.name, texs)
    mat = make_mat("M_" + ob.name[len("Outfit_"):], spec_.get("tex"), color=spec_.get("color", (1, 1, 1, 1)),
                   rough=spec_.get("rough", 0.8), metal=spec_.get("metal", 0.0), double=True)   # garments: double-sided
    set_mat(ob, mat)

# ----------------------------------------------------------------------------- re-attach to armature
for ob in [o for o in bpy.data.objects if o.type == 'MESH']:
    ob.parent = arm
    ob.matrix_parent_inverse = arm.matrix_world.inverted()
    m = ob.modifiers.new("Armature", 'ARMATURE')
    m.object = arm
    # any vertex without weights -> bind to head (face parts) or nearest bone heuristic
    unweighted = [v.index for v in ob.data.vertices if len(v.groups) == 0]
    if unweighted:
        print("WARNING unweighted verts", ob.name, len(unweighted))
        gname = "head" if ob.name in ("Eyes", "Eyebrows", "Eyelashes", "Hair_Default", "Body_Head") else "pelvis"
        g = ob.vertex_groups.get(gname) or ob.vertex_groups.new(name=gname)
        g.add(unweighted, 1.0, 'REPLACE')

# ----------------------------------------------------------------------------- coverage per bundle
deps = bpy.context.evaluated_depsgraph_get()
coverage = {}
for bid, disp, plist in CFG.BUNDLES:
    obs = [bpy.data.objects["Outfit_%s_%s" % (bid, p)] for p, _ in plist]
    # merged BVH of the bundle (rest pose, world space)
    verts, polys = [], []
    for o in obs:
        co = world_co(o)
        off = len(verts)
        verts.extend([tuple(c) for c in co])
        polys.extend([tuple(off + i for i in p.vertices) for p in o.data.polygons])
    bvh = BVHTree.FromPolygons(verts, polys)
    cov = {}
    dgroups = set()
    for p_, path_ in plist:
        if bid == "default" and p_ == "Shorts":
            continue   # pants were cut into shorts: their delete group no longer applies
        dgroups.add("Delete." + os.path.basename(path_).replace(".mhclo", "").replace(" ", "_"))
    for pname, ob in parts.items():
        gi = [g.index for g in ob.vertex_groups if g.name in dgroups]
        nin = 0
        for v in ob.data.vertices:
            if any(g.group in gi and g.weight > 0.5 for g in v.groups):
                nin += 1
        cov[pname + "#del"] = nin / max(1, len(ob.data.vertices))
    for pname, ob in list(parts.items()) + [("Hair_Default", hair)]:
        co = world_co(ob)
        m2 = ob.data
        nn = np.empty(len(m2.vertices) * 3)
        m2.vertices.foreach_get("normal", nn)
        nn = nn.reshape(-1, 3)
        hits = 0
        for i in range(len(co)):
            n = Vector(nn[i])
            o = Vector(co[i]) - n * 0.003
            h = bvh.ray_cast(o, n, 0.09)
            if h[0] is not None:
                hits += 1
        cov[pname] = hits / max(1, len(co))
    coverage[bid] = cov
    print(bid, {k: round(v, 3) for k, v in cov.items()})
with open(os.path.join(CFG.WORK, "coverage.json"), "w") as f:
    json.dump(coverage, f, indent=1)
for ob in parts.values():
    for g in list(ob.vertex_groups):
        if g.name.startswith("Delete."):
            ob.vertex_groups.remove(g)

# report
tot = {o.name: tri_count(o) for o in bpy.data.objects if o.type == 'MESH'}
print("TRIS", json.dumps(tot, indent=0))
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(CFG.WORK, "stage_b.blend"))
print("STAGE B DONE %.1fs" % (time.time() - t0))
