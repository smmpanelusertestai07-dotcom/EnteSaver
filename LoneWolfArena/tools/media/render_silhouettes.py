"""Renders the HUD's silhouette icons from the game's OWN 3D assets (so every icon is original):
stance icons from the character in its animation poses (stand, crouch, prone, jump) and item /
weapon icons from the prop models. Output: white-on-transparent PNGs in assets/ui/icons/.

usage: blender -b --python tools/media/render_silhouettes.py -- [--only name,name] [--out DIR]
Each icon is framed to fill a square canvas with a margin (stances) or a wide canvas (weapons)."""
import math
import os
import sys

import bpy
from mathutils import Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
ARGS = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []


def arg(name, default=None):
    return ARGS[ARGS.index(name) + 1] if name in ARGS else default


OUT = arg("--out", os.path.join(ROOT, "assets", "ui", "icons"))
ONLY = arg("--only", "")
ONLY = set(ONLY.split(",")) if ONLY else None
CHAR = os.path.join(ROOT, "assets", "character", "character.glb")
EXTRA = os.path.join(ROOT, "assets", "character", "anims_extra.glb")
PROPS = os.path.join(ROOT, "assets", "props")

# name -> (kind, source, action/frame or None, view, canvas (w, h))
# view: "side_r" = camera on the character's right looking at it (character faces screen-left),
#       "side_l" = camera on the character's left (faces screen-right).
ICONS = {
    "stance_stand": ("pose", "idle", 0, "side_r", (256, 256)),
    "stance_crouch": ("pose", "crouch_idle", 0, "side_r", (256, 256)),
    "stance_prone": ("pose", "prone_idle", 0, "side_r", (256, 256)),
    "stance_jump": ("pose", "jump", 7, "side_r", (256, 256)),
    "weapon_ar": ("prop", "weapon_ar", None, "side_l", (512, 192)),
    "weapon_sg": ("prop", "weapon_sg", None, "side_l", (512, 192)),
    "weapon_pistol": ("prop", "weapon_pistol", None, "side_l", (320, 192)),
    "item_grenade": ("prop", "grenade", None, "front3q", (256, 256)),
    "item_medkit": ("prop", "medkit", None, "front3q", (256, 256)),
}


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = 16
    sc.cycles.use_denoising = False
    sc.render.film_transparent = True
    sc.render.fps = 30
    sc.view_settings.view_transform = "Standard"
    sc.render.image_settings.file_format = "PNG"
    sc.render.image_settings.color_mode = "RGBA"
    world = bpy.data.worlds.new("W")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[1].default_value = 0.0
    sc.world = world
    return sc


def white_material():
    m = bpy.data.materials.new("Silhouette")
    m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    em = nt.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (1, 1, 1, 1)
    em.inputs["Strength"].default_value = 1.0
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(em.outputs[0], out.inputs[0])
    return m


def apply_white(objs):
    mat = white_material()
    for ob in objs:
        if ob.type != "MESH":
            continue
        ob.data.materials.clear()
        ob.data.materials.append(mat)


def world_bounds(objs):
    dg = bpy.context.evaluated_depsgraph_get()
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for ob in objs:
        if ob.type != "MESH" or ob.hide_render:
            continue
        ev = ob.evaluated_get(dg)
        me = ev.to_mesh()
        M = ob.matrix_world
        for v in me.vertices:
            p = M @ v.co
            lo = Vector((min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z)))
            hi = Vector((max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z)))
        ev.to_mesh_clear()
    return lo, hi


def ortho_camera(sc, view, lo, hi, canvas, margin=0.08):
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.type = "ORTHO"
    cam = bpy.data.objects.new("Cam", cam_data)
    sc.collection.objects.link(cam)
    sc.camera = cam
    c = (lo + hi) * 0.5
    size = hi - lo
    w, h = canvas
    sc.render.resolution_x = w
    sc.render.resolution_y = h
    aspect = w / h
    if view == "side_l":        # camera on +X (character's left) looking toward -X
        cam.location = c + Vector((5, 0, 0))
        cam.rotation_euler = (math.radians(90), 0, math.radians(90))
        span_w, span_h = size.y, size.z
    elif view == "side_r":
        cam.location = c + Vector((-5, 0, 0))
        cam.rotation_euler = (math.radians(90), 0, math.radians(-90))
        span_w, span_h = size.y, size.z
    else:                       # 3/4 front, slightly from above
        d = Vector((0.6, -1.0, 0.55)).normalized()
        cam.location = c + d * 5
        cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
        r = max(size.x, size.y, size.z)
        span_w, span_h = r * 1.15, r * 1.15
    ortho = max(span_w, span_h * aspect) * (1.0 + 2 * margin)
    cam_data.ortho_scale = ortho
    cam_data.clip_end = 50
    return cam


def render(sc, name):
    os.makedirs(OUT, exist_ok=True)
    sc.render.filepath = os.path.join(OUT, name + ".png")
    bpy.ops.render.render(write_still=True)
    print("ICON", name, sc.render.filepath)


def pose_icon(name, action, frame, view, canvas):
    sc = reset()
    bpy.ops.import_scene.gltf(filepath=CHAR)
    arm = bpy.data.objects["Armature"]
    act = bpy.data.actions.get(action)
    if act is None and os.path.exists(EXTRA):
        before = set(bpy.data.actions.keys())
        bpy.ops.import_scene.gltf(filepath=EXTRA)
        for ob in list(bpy.data.objects):
            if ob.name.startswith("Armature.") or (ob.parent and ob.parent.name.startswith("Armature.")):
                bpy.data.objects.remove(ob, do_unlink=True)
        act = bpy.data.actions.get(action)
    if act is None:
        print("SKIP", name, "missing action", action)
        return
    # Hide every outfit except the default one (ROOKIE look) for a clean, familiar shape.
    for ob in bpy.data.objects:
        if ob.type == "MESH" and ob.name.startswith("Outfit_") and not ob.name.startswith("Outfit_default_"):
            ob.hide_render = True
    arm.animation_data_create()
    arm.animation_data.action = act
    if hasattr(arm.animation_data, "action_slot") and act.slots:
        arm.animation_data.action_slot = act.slots[0]
    sc.frame_set(frame)
    attach_rifle(arm)
    meshes = [o for o in bpy.data.objects if o.type == "MESH" and not o.hide_render]
    apply_white(meshes)
    lo, hi = world_bounds(meshes)
    ortho_camera(sc, view, lo, hi, canvas)
    render(sc, name)


def attach_rifle(arm):
    """Puts the AR in the right hand the way the game does: grip 5.5 cm past the wrist along the
    forearm, barrel pointing where the character faces (-Y; the GLB's barrel is +Y in Blender)."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(PROPS, "weapon_ar.glb"))
    roots = [o for o in bpy.data.objects if o not in before and o.parent is None]
    hand = arm.matrix_world @ arm.pose.bones["hand_r"].head
    fore = arm.matrix_world @ arm.pose.bones["lowerarm_r"].head
    grip = hand + (hand - fore).normalized() * 0.055
    M = Matrix.Rotation(math.pi, 4, "Z")
    M.translation = grip
    for o in roots:
        o.matrix_world = M @ o.matrix_world


def prop_icon(name, prop, view, canvas):
    sc = reset()
    bpy.ops.import_scene.gltf(filepath=os.path.join(PROPS, prop + ".glb"))
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    apply_white(meshes)
    lo, hi = world_bounds(meshes)
    ortho_camera(sc, view, lo, hi, canvas, margin=0.05)
    render(sc, name)


for name, (kind, src, frame, view, canvas) in ICONS.items():
    if ONLY and name not in ONLY:
        continue
    if kind == "pose":
        pose_icon(name, src, frame, view, canvas)
    else:
        prop_icon(name, src, view, canvas)
