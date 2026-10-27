"""Re-import exported GLBs and render preview strips.

usage: xvfb-run -a python3 preview.py [--cycles] [--res 512] name [name ...]
Writes /root/work/assets/props/previews/<name>.png
"""
import bpy, sys, os, math, json
from mathutils import Vector
from PIL import Image, ImageDraw

PROPS = '/root/work/assets/props'
PREV = os.path.join(PROPS, 'previews')
os.makedirs(PREV, exist_ok=True)
TMP = '/root/work/tools/props/_render_tmp'
os.makedirs(TMP, exist_ok=True)

args = sys.argv[1:]
CYCLES = '--cycles' in args
CULL = '--cull' in args
RES = 480
if '--res' in args:
    RES = int(args[args.index('--res') + 1])
names = [a for i, a in enumerate(args) if not a.startswith('--') and (i == 0 or args[i - 1] != '--res')]

WEAPONS = {'weapon_ar', 'weapon_sg', 'weapon_pistol'}
# (azimuth deg: 0 = camera in front (+Y), 90 = right side (+X)), elevation deg
VIEWS = {
    'weapon': [(90, 4), (50, 22), (235, 25)],
    'prop': [(40, 24), (220, 28)],
    'mountains': [('top',), ('inside',)],
    'house': [(40, 30), (220, 34), ('topcut',)],
}


def setup_world(cy):
    sc = bpy.context.scene
    w = bpy.data.worlds.new('W')
    sc.world = w
    w.use_nodes = True
    bg = w.node_tree.nodes.get('Background')
    g = 0.42
    bg.inputs[0].default_value = (g, g, g, 1)
    bg.inputs[1].default_value = 1.0 if cy else 1.0
    w.color = (g, g, g)
    sc.view_settings.view_transform = 'Standard'
    sc.render.resolution_x = int(RES * 4 / 3)
    sc.render.resolution_y = RES
    if cy:
        sc.render.engine = 'CYCLES'
        sc.cycles.device = 'CPU'
        sc.cycles.samples = 24
        try:
            sc.cycles.use_denoising = True
        except Exception:
            pass
        sun = bpy.data.lights.new('Sun', 'SUN')
        sun.energy = 3.2
        sun.angle = math.radians(4)
        so = bpy.data.objects.new('Sun', sun)
        so.rotation_euler = (math.radians(40), math.radians(0), math.radians(35))
        sc.collection.objects.link(so)
    else:
        sc.render.engine = 'BLENDER_WORKBENCH'
        sh = sc.display.shading
        sh.light = 'STUDIO'
        sh.color_type = 'MATERIAL'
        sh.show_shadows = True
        sh.shadow_intensity = 0.5
        sh.show_cavity = True
        sh.cavity_type = 'BOTH'
        sh.show_specular_highlight = True
        sc.display.render_aa = '8'
        sc.display.light_direction = (0.4, -0.35, 0.85)
        sh.show_backface_culling = CULL


def import_glb(name):
    path = os.path.join(PROPS, name + '.glb')
    bpy.ops.import_scene.gltf(filepath=path)
    for m in bpy.data.materials:
        if m.node_tree:
            for n in m.node_tree.nodes:
                if n.type == 'BSDF_PRINCIPLED':
                    c = n.inputs['Base Color'].default_value
                    m.diffuse_color = (c[0], c[1], c[2], 1)
                    m.metallic = n.inputs['Metallic'].default_value
                    m.roughness = n.inputs['Roughness'].default_value
    meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
    empties = [o for o in bpy.context.scene.objects if o.type == 'EMPTY']
    return meshes, empties


def bbox(objs):
    pts = []
    for o in objs:
        for v in o.data.vertices:
            pts.append(o.matrix_world @ v.co)
    mn = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    mx = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return mn, mx


def look_at(cam, target):
    d = (target - cam.location)
    cam.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()


def marker(loc, col, r):
    bpy.ops.mesh.primitive_uv_sphere_add(radius=r, location=loc, segments=12, ring_count=8)
    o = bpy.context.object
    m = bpy.data.materials.new('mk')
    m.diffuse_color = (*col, 1)
    try:
        m.use_nodes = True
        b = [n for n in m.node_tree.nodes if n.type == 'BSDF_PRINCIPLED'][0]
        b.inputs['Base Color'].default_value = (*col, 1)
        b.inputs['Emission Color'].default_value = (*col, 1)
        b.inputs['Emission Strength'].default_value = 2.0
    except Exception:
        pass
    o.data.materials.append(m)
    return o


def render_views(name, kind, mn, mx):
    sc = bpy.context.scene
    c = (mn + mx) / 2
    rad = (mx - mn).length / 2
    cam_d = bpy.data.cameras.new('Cam')
    cam_d.lens = 50
    cam_d.clip_start = 0.01
    cam_d.clip_end = 5000
    cam = bpy.data.objects.new('Cam', cam_d)
    sc.collection.objects.link(cam)
    sc.camera = cam
    files = []
    for i, v in enumerate(VIEWS[kind]):
        if v[0] == 'top':
            cam.location = c + Vector((0, -rad * 1.2, rad * 1.5))
            look_at(cam, c)
        elif v[0] == 'inside':
            cam_d.lens = 18
            cam.location = Vector((0, 0, 6))
            look_at(cam, Vector((0, 400, 60)))
        elif v[0] == 'topcut':
            cam_d.type = 'ORTHO'
            cam_d.ortho_scale = max(mx.x - mn.x, mx.y - mn.y) * 1.25
            cam.location = Vector((c.x, c.y, mx.z - 0.25))
            cam.rotation_euler = (0, 0, 0)
            cam_d.clip_start = 0.01
            cam_d.clip_end = 100
        else:
            az, el = math.radians(v[0]), math.radians(v[1])
            dvec = Vector((math.sin(az) * math.cos(el), math.cos(az) * math.cos(el), math.sin(el)))
            # fit projected bbox corners
            fwd = -dvec
            right = fwd.cross(Vector((0, 0, 1))).normalized()
            up = right.cross(fwd).normalized()
            corners = [Vector((x, y, z)) for x in (mn.x, mx.x) for y in (mn.y, mx.y) for z in (mn.z, mx.z)]
            ex = max(abs((p - c).dot(right)) for p in corners)
            ey = max(abs((p - c).dot(up)) for p in corners)
            ez = max(abs((p - c).dot(fwd)) for p in corners)
            aspect = sc.render.resolution_x / sc.render.resolution_y
            tan_h = 18 / cam_d.lens
            tan_v = tan_h / aspect
            dist = max(ex / tan_h, ey / tan_v) * 1.12 + ez
            cam.location = c + dvec * dist
            look_at(cam, c)
        f = os.path.join(TMP, f'prev_{name}_{i}.png')
        sc.render.filepath = f
        bpy.ops.render.render(write_still=True)
        files.append(f)
        cam_d.type = 'PERSP'
        cam_d.lens = 50
        cam_d.clip_end = 5000
    return files


def main():
    report = {}
    for name in names:
        bpy.ops.wm.read_factory_settings(use_empty=True)
        setup_world(CYCLES)
        meshes, empties = import_glb(name)
        mn, mx = bbox(meshes)
        tris = 0
        for o in meshes:
            o.data.calc_loop_triangles()
            tris += len(o.data.loop_triangles)
        g_size = (mx.x - mn.x, mx.z - mn.z, mx.y - mn.y)
        g_center = ((mx.x + mn.x) / 2, (mx.z + mn.z) / 2, -(mx.y + mn.y) / 2)
        print(f'== {name}: tris={tris} meshes={[o.name for o in meshes]}')
        print(f'   blender bbox min={tuple(round(x, 3) for x in mn)} max={tuple(round(x, 3) for x in mx)}')
        print(f'   godot size={tuple(round(x, 3) for x in g_size)} center={tuple(round(x, 3) for x in g_center)}')
        for e in empties:
            p = e.matrix_world.translation
            print(f'   empty {e.name}: blender={tuple(round(x, 4) for x in p)} godot={(round(p.x, 4), round(p.z, 4), round(-p.y, 4))}')
        kind = 'weapon' if name in WEAPONS else ('mountains' if name == 'mountains' else ('house' if name == 'house' else 'prop'))
        if kind == 'weapon':
            r = (mx - mn).length * 0.012
            for e in empties:
                col = (1, 0.1, 0.1) if e.name.startswith('Muzzle') else (0.1, 0.4, 1)
                marker(e.matrix_world.translation, col, r)
            marker(Vector((0, 0, 0)), (0.1, 1, 0.2), r)
        elif kind in ('prop', 'house'):
            bpy.ops.mesh.primitive_plane_add(size=max(40, (mx - mn).length * 6), location=(0, 0, 0))
            pl = bpy.context.object
            pm = bpy.data.materials.new('ground')
            pm.diffuse_color = (0.33, 0.33, 0.33, 1)
            try:
                pm.use_nodes = True
                b = [n for n in pm.node_tree.nodes if n.type == 'BSDF_PRINCIPLED'][0]
                b.inputs['Base Color'].default_value = (0.3, 0.3, 0.3, 1)
            except Exception:
                pass
            pl.data.materials.append(pm)
        files = render_views(name, kind, mn, mx)
        ims = [Image.open(f).convert('RGB') for f in files]
        W = sum(im.width for im in ims)
        H = max(im.height for im in ims)
        sheet = Image.new('RGB', (W, H + 26), (60, 60, 60))
        x = 0
        for im in ims:
            sheet.paste(im, (x, 26))
            x += im.width
        d = ImageDraw.Draw(sheet)
        d.text((8, 6), f'{name}   tris={tris}   size(godot xyz)={tuple(round(s, 3) for s in g_size)}', fill=(255, 255, 255))
        sheet.save(os.path.join(PREV if not CULL else TMP, name + ('_cull' if CULL else '') + '.png'))
        report[name] = dict(tris=tris)
    print(json.dumps(report))


main()
