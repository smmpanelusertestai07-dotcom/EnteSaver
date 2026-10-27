"""Preview rendering helpers (Cycles CPU, headless)."""
import math
import bpy
from mathutils import Vector


def setup_scene(res=768, samples=24, engine="CYCLES"):
    sc = bpy.context.scene
    sc.render.engine = engine
    sc.render.resolution_x = res
    sc.render.resolution_y = res
    sc.render.resolution_percentage = 100
    sc.render.film_transparent = False
    if engine == "CYCLES":
        sc.cycles.device = 'CPU'
        sc.cycles.samples = samples
        sc.cycles.use_denoising = True
        try:
            sc.cycles.denoiser = 'OPENIMAGEDENOISE'
        except Exception:
            pass
        sc.cycles.max_bounces = 4
        sc.cycles.transparent_max_bounces = 16
    sc.view_settings.view_transform = 'AgX'
    try:
        sc.view_settings.look = 'AgX - Base Contrast'
    except Exception:
        pass
    # world
    world = bpy.data.worlds.get("PreviewWorld") or bpy.data.worlds.new("PreviewWorld")
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs[0].default_value = (0.32, 0.36, 0.42, 1.0)
    bg.inputs[1].default_value = 0.35
    sc.world = world
    # lights
    for name, loc, energy, size, color in [
        ("KeyLight", (-2.5, -3.0, 3.2), 380.0, 2.0, (1.0, 0.96, 0.9)),
        ("FillLight", (3.0, -2.0, 1.8), 120.0, 3.0, (0.85, 0.9, 1.0)),
        ("RimLight", (0.8, 3.0, 2.8), 260.0, 1.5, (1.0, 1.0, 1.0)),
    ]:
        ob = bpy.data.objects.get(name)
        if ob is None:
            ld = bpy.data.lights.new(name, 'AREA')
            ob = bpy.data.objects.new(name, ld)
            sc.collection.objects.link(ob)
        ob.data.energy = energy
        ob.data.size = size
        ob.data.color = color
        ob.location = loc
        look_at(ob, Vector((0, 0, 1.0)))
    # ground
    if bpy.data.objects.get("PreviewGround") is None:
        me = bpy.data.meshes.new("PreviewGround")
        s = 6.0
        me.from_pydata([(-s, -s, 0), (s, -s, 0), (s, s, 0), (-s, s, 0)], [], [(0, 1, 2, 3)])
        ob = bpy.data.objects.new("PreviewGround", me)
        mat = bpy.data.materials.new("PreviewGroundMat")
        mat.use_nodes = True
        p = mat.node_tree.nodes.get("Principled BSDF")
        p.inputs["Base Color"].default_value = (0.22, 0.22, 0.24, 1)
        p.inputs["Roughness"].default_value = 0.9
        me.materials.append(mat)
        sc.collection.objects.link(ob)
    return sc


def look_at(ob, target):
    d = (target - ob.location)
    ob.rotation_euler = d.to_track_quat('-Z', 'Y').to_euler()


def set_camera(azimuth_deg=30.0, dist=3.4, height=1.05, target_z=0.92, lens=50.0, target_xy=(0.0, 0.0)):
    """azimuth 0 = straight in front of the character (character faces -Y);
    positive azimuth moves the camera toward the character's right side (-X)."""
    sc = bpy.context.scene
    cam = bpy.data.objects.get("PreviewCam")
    if cam is None:
        cd = bpy.data.cameras.new("PreviewCam")
        cam = bpy.data.objects.new("PreviewCam", cd)
        sc.collection.objects.link(cam)
    cam.data.lens = lens
    a = math.radians(azimuth_deg)
    cam.location = Vector((target_xy[0] - math.sin(a) * dist, target_xy[1] - math.cos(a) * dist, height))
    look_at(cam, Vector((target_xy[0], target_xy[1], target_z)))
    sc.camera = cam
    return cam


def render(path):
    sc = bpy.context.scene
    sc.render.filepath = path
    sc.render.image_settings.file_format = 'PNG'
    bpy.ops.render.render(write_still=True)


def show_only(visible_names, all_mesh_names):
    for n in all_mesh_names:
        ob = bpy.data.objects.get(n)
        if ob is None:
            continue
        vis = n in visible_names
        ob.hide_render = not vis
        ob.hide_viewport = not vis
