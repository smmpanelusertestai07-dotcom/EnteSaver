"""Shared bpy helpers for building low-poly game props.

Conventions: Blender Z-up, meters. Every part is built in place (identity object
transform), bevelled + shaded individually, then joined into one mesh per asset.
"""
import bpy, bmesh, math, os, json, random
from mathutils import Vector, Matrix
import numpy as np

OUT_DIR = '/root/work/assets/props'
META_DIR = '/root/work/tools/props/meta'
os.makedirs(OUT_DIR, exist_ok=True)
os.makedirs(META_DIR, exist_ok=True)

PARTS = []


# ----------------------------------------------------------------- scene / materials
def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    PARTS.clear()


def _lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hex2lin(h):
    h = h.lstrip('#')
    return tuple(_lin(int(h[i:i + 2], 16) / 255.0) for i in (0, 2, 4))


def mat(name, hexcol, metallic=0.0, rough=0.5, emit=None, emit_strength=1.0):
    m = bpy.data.materials.get(name)
    if m is not None:
        return m
    m = bpy.data.materials.new(name)
    try:
        m.use_nodes = True
    except Exception:
        pass
    nt = m.node_tree
    bsdf = [n for n in nt.nodes if n.type == 'BSDF_PRINCIPLED']
    if not bsdf:
        bsdf = nt.nodes.new('ShaderNodeBsdfPrincipled')
        out = [n for n in nt.nodes if n.type == 'OUTPUT_MATERIAL'] or [nt.nodes.new('ShaderNodeOutputMaterial')]
        nt.links.new(bsdf.outputs[0], out[0].inputs[0])
    else:
        bsdf = bsdf[0]
    c = hex2lin(hexcol)
    bsdf.inputs['Base Color'].default_value = (*c, 1.0)
    bsdf.inputs['Metallic'].default_value = metallic
    bsdf.inputs['Roughness'].default_value = rough
    if emit:
        e = hex2lin(emit)
        bsdf.inputs['Emission Color'].default_value = (*e, 1.0)
        bsdf.inputs['Emission Strength'].default_value = emit_strength
    m.diffuse_color = (*c, 1.0)
    m.metallic = metallic
    m.roughness = rough
    return m


# ----------------------------------------------------------------- object plumbing
def link(ob):
    bpy.context.scene.collection.objects.link(ob)
    return ob


def bm_to_obj(bm, name, material):
    me = bpy.data.meshes.new(name)
    bm.normal_update()
    bm.to_mesh(me)
    bm.free()
    ob = link(bpy.data.objects.new(name, me))
    if material is not None:
        for m in (material if isinstance(material, (list, tuple)) else [material]):
            me.materials.append(m)
    return ob


def apply_mods(ob):
    dg = bpy.context.evaluated_depsgraph_get()
    ev = ob.evaluated_get(dg)
    me = bpy.data.meshes.new_from_object(ev, preserve_all_data_layers=True, depsgraph=dg)
    old = ob.data
    ob.modifiers.clear()
    ob.data = me
    nm = old.name
    bpy.data.meshes.remove(old)
    me.name = nm


def shade(ob, angle=60.0, weighted=True):
    """Smooth shading, edges sharper than `angle` marked sharp, weighted normals."""
    me = ob.data
    bm = bmesh.new()
    bm.from_mesh(me)
    lim = math.radians(angle)
    for f in bm.faces:
        f.smooth = True
    for e in bm.edges:
        if len(e.link_faces) == 2:
            e.smooth = e.calc_face_angle(math.pi) <= lim
        else:
            e.smooth = False
    bm.to_mesh(me)
    bm.free()
    if weighted:
        m = ob.modifiers.new('WN', 'WEIGHTED_NORMAL')
        m.keep_sharp = True
        m.mode = 'FACE_AREA'
        m.weight = 50
        apply_mods(ob)


def bool_cut(ob, cutters):
    for bm_c, m in cutters:
        co = bm_to_obj(bm_c, 'cutter', m)
        co.hide_render = True
        mod = ob.modifiers.new('Bool', 'BOOLEAN')
        mod.operation = 'DIFFERENCE'
        mod.solver = 'EXACT'
        mod.object = co
        try:
            mod.material_mode = 'TRANSFER'
        except Exception:
            pass
        apply_mods(ob)
        bpy.data.objects.remove(co)


def part(bm, material, bevel=0.0, segs=1, bevel_angle=30.0, smooth=60.0, wn=True,
         name='part', clamp=True, profile=0.5, register=True, cutters=None):
    ob = bm_to_obj(bm, name, material)
    if bevel > 0:
        m = ob.modifiers.new('Bevel', 'BEVEL')
        m.width = bevel
        m.segments = segs
        m.limit_method = 'ANGLE'
        m.angle_limit = math.radians(bevel_angle)
        m.use_clamp_overlap = clamp
        m.profile = profile
        apply_mods(ob)
    if cutters:
        bool_cut(ob, cutters)
    shade(ob, smooth, wn)
    if register:
        PARTS.append(ob)
    return ob


def join(objs, name):
    objs = [o for o in objs if o is not None]
    if len(objs) > 1:
        ctx = dict(active_object=objs[0], object=objs[0], selected_objects=objs,
                   selected_editable_objects=objs)
        with bpy.context.temp_override(**ctx):
            bpy.ops.object.join()
    ob = objs[0]
    ob.name = name
    ob.data.name = name
    return ob


def empty(name, loc, size=0.03):
    e = bpy.data.objects.new(name, None)
    e.empty_display_type = 'PLAIN_AXES'
    e.empty_display_size = size
    e.location = loc
    return link(e)


def box_uv(ob, scale=1.0):
    """World-space box-projected UVs, 1 UV unit = 1/scale meters (tileable textures)."""
    me = ob.data
    if not me.uv_layers:
        me.uv_layers.new(name='UVMap')
    uvl = me.uv_layers[0]
    nv, nl, npoly = len(me.vertices), len(me.loops), len(me.polygons)
    co = np.zeros(nv * 3, dtype=np.float64); me.vertices.foreach_get('co', co); co = co.reshape(-1, 3)
    lv = np.zeros(nl, dtype=np.int64); me.loops.foreach_get('vertex_index', lv)
    pn = np.zeros(npoly * 3, dtype=np.float64); me.polygons.foreach_get('normal', pn); pn = pn.reshape(-1, 3)
    lt = np.zeros(npoly, dtype=np.int64); me.polygons.foreach_get('loop_total', lt)
    pol = np.repeat(np.arange(npoly), lt)
    n = pn[pol]
    an = np.abs(n)
    p = co[lv]
    ax = np.argmax(an, axis=1)
    # X-facing -> (y, z), Y-facing -> (x, z), Z-facing -> (x, y); mirror by normal sign
    u = np.where(ax == 0, p[:, 1] * np.sign(n[:, 0] + 1e-9), np.where(ax == 1, -p[:, 0] * np.sign(n[:, 1] + 1e-9), p[:, 0]))
    v = np.where(ax == 2, p[:, 1] * np.sign(n[:, 2] + 1e-9), p[:, 2])
    uv = np.stack([u, v], axis=1) * scale
    uvl.data.foreach_set('uv', uv.astype(np.float32).ravel())


def tri_count(ob):
    me = ob.data
    me.calc_loop_triangles()
    return len(me.loop_triangles)


def finalize(name, objs=None, uv_scale=1.0):
    objs = PARTS if objs is None else objs
    ob = join(objs, name)
    box_uv(ob, uv_scale)
    return ob


def export(name):
    path = os.path.join(OUT_DIR, name + '.glb')
    bpy.ops.export_scene.gltf(
        filepath=path, export_format='GLB', use_selection=False, export_apply=True,
        export_yup=True, export_texcoords=True, export_normals=True, export_tangents=False,
        export_materials='EXPORT', export_cameras=False, export_lights=False,
        export_animations=False, export_skins=False, export_morph=False, export_extras=False)
    return path


def report(ob, name, budget):
    t = tri_count(ob)
    mats = [m.name for m in ob.data.materials]
    bb = [ob.matrix_world @ Vector(c) for c in ob.bound_box]
    mn = Vector((min(v.x for v in bb), min(v.y for v in bb), min(v.z for v in bb)))
    mx = Vector((max(v.x for v in bb), max(v.y for v in bb), max(v.z for v in bb)))
    flag = 'OK' if t <= budget else 'OVER BUDGET'
    print(f'[{name}] tris={t} / {budget} {flag}  mats={mats}')
    print(f'[{name}] bbox min={tuple(round(x, 4) for x in mn)} max={tuple(round(x, 4) for x in mx)} size={tuple(round(x, 4) for x in (mx - mn))}')
    return t


def save_meta(name, data):
    with open(os.path.join(META_DIR, name + '.json'), 'w') as f:
        json.dump(data, f, indent=1)


# ----------------------------------------------------------------- bmesh primitives
def bm_box(x0, x1, y0, y1, z0, z1):
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    sx, sy, sz = x1 - x0, y1 - y0, z1 - z0
    cx, cy, cz = (x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2
    for v in bm.verts:
        v.co = Vector((v.co.x * sx + cx, v.co.y * sy + cy, v.co.z * sz + cz))
    return bm


def bm_boxc(cx, cy, cz, sx, sy, sz):
    return bm_box(cx - sx / 2, cx + sx / 2, cy - sy / 2, cy + sy / 2, cz - sz / 2, cz + sz / 2)


def _P(axis, u, v, w):
    if axis == 'X':
        return Vector((w, u, v))
    if axis == 'Y':
        return Vector((u, w, v))
    return Vector((u, v, w))


def bm_prism(pts, axis, a0, a1, hw_fn=None):
    """Extrude a simple 2D polygon. axis 'X': pts=(y,z) extruded x in [a0,a1];
    'Y': pts=(x,z) along y; 'Z': pts=(x,y) along z.  hw_fn(u,v)->(a0,a1) optional taper."""
    bm = bmesh.new()
    b, t = [], []
    for (u, v) in pts:
        lo, hi = (a0, a1) if hw_fn is None else hw_fn(u, v)
        b.append(bm.verts.new(_P(axis, u, v, lo)))
        t.append(bm.verts.new(_P(axis, u, v, hi)))
    n = len(pts)
    bm.faces.new(b[::-1])
    bm.faces.new(t)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((b[i], b[j], t[j], t[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


def bm_cyl(r1, r2, p0, p1, sides=12, caps=True, rot=0.0):
    """Cylinder/cone between points p0 and p1 (radius r1 at p0, r2 at p1)."""
    p0, p1 = Vector(p0), Vector(p1)
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=caps, cap_tris=False, segments=sides,
                          radius1=r1, radius2=r2, depth=1.0)
    d = p1 - p0
    L = d.length
    R = Matrix.Rotation(rot, 4, 'Z')
    M = Matrix.Translation((p0 + p1) / 2) @ d.to_track_quat('Z', 'Y').to_matrix().to_4x4() \
        @ Matrix.Diagonal((1, 1, L, 1)) @ R
    bmesh.ops.transform(bm, matrix=M, verts=bm.verts)
    return bm


def bm_loft(rings, cap0=True, cap1=True, closed=True):
    bm = bmesh.new()
    vr = [[bm.verts.new(Vector(p)) for p in ring] for ring in rings]
    n = len(rings[0])
    for a, b in zip(vr[:-1], vr[1:]):
        rng = range(n) if closed else range(n - 1)
        for i in rng:
            j = (i + 1) % n
            bm.faces.new((a[i], a[j], b[j], b[i]))
    if cap0:
        bm.faces.new(vr[0][::-1])
    if cap1:
        bm.faces.new(vr[-1])
    if cap0 or cap1:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


def bm_tube(path, radius, sides=8, caps=True, rot=0.0):
    """Sweep a circle along a polyline (list of 3D points). radius can be list."""
    path = [Vector(p) for p in path]
    rad = radius if isinstance(radius, (list, tuple)) else [radius] * len(path)
    rings = []
    up = Vector((0, 0, 1))
    prev_n = None
    for i, p in enumerate(path):
        if i == 0:
            t = (path[1] - path[0]).normalized()
        elif i == len(path) - 1:
            t = (path[-1] - path[-2]).normalized()
        else:
            t = ((path[i] - path[i - 1]).normalized() + (path[i + 1] - path[i]).normalized()).normalized()
        if prev_n is None:
            ref = up if abs(t.dot(up)) < 0.9 else Vector((1, 0, 0))
            n = (ref - t * ref.dot(t)).normalized()
        else:
            n = (prev_n - t * prev_n.dot(t)).normalized()
        prev_n = n
        b = t.cross(n)
        ring = []
        for k in range(sides):
            a = rot + 2 * math.pi * k / sides
            ring.append(p + rad[i] * (math.cos(a) * n + math.sin(a) * b))
        rings.append(ring)
    return bm_loft(rings, cap0=caps, cap1=caps)


def bm_merge(bms):
    """Merge several bmeshes into one (geometry only)."""
    out = bmesh.new()
    for bm in bms:
        me = bpy.data.meshes.new('_tmp')
        bm.to_mesh(me)
        out.from_mesh(me)
        bpy.data.meshes.remove(me)
        bm.free()
    return out


def bm_transform(bm, M):
    bmesh.ops.transform(bm, matrix=M, verts=bm.verts)
    return bm


def rounded_rect(hw, hh, r, segs=2, cx=0.0, cy=0.0):
    """2D rounded rectangle points (counter-clockwise)."""
    pts = []
    corners = [(hw - r, hh - r, 0), (-hw + r, hh - r, 90), (-hw + r, -hh + r, 180), (hw - r, -hh + r, 270)]
    for (x, y, a0) in corners:
        for k in range(segs + 1):
            a = math.radians(a0 + 90.0 * k / segs)
            pts.append((cx + x + r * math.cos(a), cy + y + r * math.sin(a)))
    return pts


def circle_pts(r, n, cx=0.0, cy=0.0, rot=0.0):
    return [(cx + r * math.cos(rot + 2 * math.pi * k / n), cy + r * math.sin(rot + 2 * math.pi * k / n)) for k in range(n)]


def shift_all(offset):
    """Translate every mesh part (in PARTS) by offset - used to put a hand point at the origin."""
    M = Matrix.Translation(Vector(offset))
    for o in PARTS:
        o.data.transform(M)
