"""Renders the HUD's silhouette icons from the game's OWN 3D assets (so every icon is original):
stance icons from the character in its animation poses (stand, crouch, prone, jump, sprint) and item /
weapon icons from the prop models. Output: white-on-transparent PNGs in assets/ui/icons/
(then run tools/media/make_ui_icons.py, which also writes their .import files with mipmaps).

usage: blender -b --python tools/media/render_silhouettes.py -- [--only name,name] [--out DIR]
Each icon is rendered at 3x, cropped to the silhouette and fitted into its canvas with a margin
(square for stances, wide for weapons); stance figures are thickened a little ("bold") so they
still read as solid shapes at button size (~50 px)."""
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

# name -> (kind, source, action/frame or None, view, canvas (w, h)[, options])
# view: "side_r" = camera on the character's right: the character (it faces -Y) faces screen-right,
#       "side_l" = camera on its left: the character faces screen-left, props point screen-right
#       (their muzzle is +Y). Stance buttons sit on the right of the HUD and face left (inward);
#       the sprint button sits on the left and runs right.
# options: "rifle" (pose icons hold the AR, default True), "bold" (thickening, fraction of the
#          canvas height; default 0.022 for poses, 0 for props), "margin" (default 0.06 / 0.04),
#          "aim" (pose tweaks after the frame is set: [(bone, world direction of the bone)]).
SPRINT_POSE = [
    ("spine_01", (0, -0.45, 1)),
    ("thigh_l", (0, -0.95, -0.30)), ("calf_l", (0, 0.25, -1)),
    ("thigh_r", (0, 0.55, -0.83)), ("calf_r", (0, 1.0, -0.20)),
    ("upperarm_l", (0, -1.0, -0.10)), ("lowerarm_l", (0, -0.55, 0.85)),
    ("upperarm_r", (0, 0.95, -0.30)), ("lowerarm_r", (0, 0.80, -0.60)),
]
ICONS = {
    "stance_sprint": ("pose", "idle", 0, "side_r", (256, 256), {"rifle": False, "aim": SPRINT_POSE}),
    "stance_stand": ("pose", "idle", 0, "side_l", (256, 256)),
    "stance_crouch": ("pose", "crouch_idle", 0, "side_l", (256, 256)),
    "stance_prone": ("pose", "prone_idle", 0, "side_l", (256, 256)),
    "stance_jump": ("pose", "jump", 7, "side_l", (256, 256)),
    "weapon_ar": ("prop", "weapon_ar", None, "side_l", (512, 192)),
    "weapon_sg": ("prop", "weapon_sg", None, "side_l", (512, 192)),
    "weapon_smg": ("prop", "weapon_smg", None, "side_l", (512, 192)),
    "weapon_sniper": ("prop", "weapon_sniper", None, "side_l", (512, 192)),
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


def render(sc, name, canvas, margin, bold):
    os.makedirs(OUT, exist_ok=True)
    sc.render.filepath = os.path.join(OUT, name + ".png")
    sc.render.resolution_percentage = 300
    bpy.ops.render.render(write_still=True)
    finish(sc.render.filepath, canvas, margin, bold)
    print("ICON", name, sc.render.filepath)


def finish(path, canvas, margin, bold):
    """Crops the 3x render to the silhouette, thickens it by `bold` (fraction of the canvas
    height), centres it in the canvas with `margin` and writes it back as white RGBA."""
    import numpy as np
    img = bpy.data.images.load(path, check_existing=False)
    w, h = img.size
    px = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(px)
    bpy.data.images.remove(img)
    a = px.reshape(h, w, 4)[:, :, 3]
    ys, xs = np.nonzero(a > 0.01)
    if xs.size == 0:
        return
    a = a[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    cw, ch = canvas
    k = min(cw * (1 - 2 * margin) / a.shape[1], ch * (1 - 2 * margin) / a.shape[0])
    r = int(round(bold * ch / k))
    if r > 0:
        a = np.pad(a, r)
        src = a.copy()
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                if dx * dx + dy * dy <= r * r:
                    a = np.maximum(a, np.roll(np.roll(src, dy, 0), dx, 1))
        k = min(cw * (1 - 2 * margin) / a.shape[1], ch * (1 - 2 * margin) / a.shape[0])
    sw, sh = max(int(round(cw / k)), a.shape[1]), max(int(round(ch / k)), a.shape[0])
    full = np.zeros((sh, sw), dtype=np.float32)
    oy, ox = (sh - a.shape[0]) // 2, (sw - a.shape[1]) // 2
    full[oy:oy + a.shape[0], ox:ox + a.shape[1]] = a
    rgba = np.ones((sh, sw, 4), dtype=np.float32)
    rgba[:, :, 3] = full
    out = bpy.data.images.new("icon_out", sw, sh, alpha=True)
    out.alpha_mode = "STRAIGHT"
    out.pixels.foreach_set(rgba.ravel())
    out.scale(cw, ch)
    out.filepath_raw = path
    out.file_format = "PNG"
    out.save()
    bpy.data.images.remove(out)


def pose_icon(name, action, frame, view, canvas, opts=None):
    opts = opts or {}
    sc = reset()
    bpy.ops.import_scene.gltf(filepath=CHAR)
    arm = bpy.data.objects["Armature"]
    act = bpy.data.actions.get(action)
    if act is None and os.path.exists(EXTRA):
        # Only the actions are wanted from the extra file: drop every object it brings along.
        keep = set(bpy.data.objects)
        bpy.ops.import_scene.gltf(filepath=EXTRA)
        for ob in [o for o in bpy.data.objects if o not in keep]:
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
    if opts.get("aim"):
        # Freeze this frame's pose, drop the action, then point the listed bones.
        mats = {pb.name: pb.matrix_basis.copy() for pb in arm.pose.bones}
        arm.animation_data.action = None
        for pb in arm.pose.bones:
            pb.matrix_basis = mats[pb.name]
        bpy.context.view_layer.update()
        for bone, direction in opts["aim"]:
            aim_bone(arm, bone, direction)
    if opts.get("rifle", True):
        attach_rifle(arm)
    meshes = [o for o in bpy.data.objects if o.type == "MESH" and not o.hide_render]
    apply_white(meshes)
    lo, hi = world_bounds(meshes)
    ortho_camera(sc, view, lo, hi, canvas)
    render(sc, name, canvas, opts.get("margin", 0.06), opts.get("bold", 0.022))


def aim_bone(arm, name, direction):
    """Turns a pose bone about its head (world space) so its head->tail points along direction."""
    pb = arm.pose.bones[name]
    mw = arm.matrix_world
    head = mw @ pb.head
    cur = ((mw @ pb.tail) - head).normalized()
    q = cur.rotation_difference(Vector(direction).normalized())
    R = Matrix.Translation(head) @ q.to_matrix().to_4x4() @ Matrix.Translation(-head)
    pb.matrix = mw.inverted() @ (R @ (mw @ pb.matrix))
    bpy.context.view_layer.update()


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


def prop_icon(name, prop, view, canvas, opts=None):
    opts = opts or {}
    src = os.path.join(PROPS, prop + ".glb")
    if not os.path.exists(src):
        print("SKIP", name, "missing", src)
        return
    sc = reset()
    bpy.ops.import_scene.gltf(filepath=src)
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    apply_white(meshes)
    lo, hi = world_bounds(meshes)
    ortho_camera(sc, view, lo, hi, canvas, margin=0.05)
    render(sc, name, canvas, opts.get("margin", 0.04), opts.get("bold", 0.0))


for name, entry in ICONS.items():
    if ONLY and name not in ONLY:
        continue
    kind, src, frame, view, canvas = entry[:5]
    options = entry[5] if len(entry) > 5 else {}
    if kind == "pose":
        pose_icon(name, src, frame, view, canvas, options)
    else:
        prop_icon(name, src, view, canvas, options)
