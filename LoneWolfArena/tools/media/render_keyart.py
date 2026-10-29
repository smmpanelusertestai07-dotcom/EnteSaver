"""Renders the game's key art and the wardrobe portraits from its OWN 3D assets (character GLB,
rifle and container props), with Cycles. Text, logo and grading are added afterwards by
tools/media/make_keyart.py, which also calls this script (see its header).

Scenes:
  hero      the key art: our character on the left third of the frame, low hero angle, facing
            into the frame with the rifle at the ready; a container yard at sunset behind
            (warm sky, sun glow behind the stacks, cyan + orange rim lights, shallow depth of
            field) and the opponent standing on a container stack in the distance (a duel).
  portrait  one outfit (bundle) full body, 3/4 front, on a transparent background, studio key
            + rim lights: the item art of the wardrobe cards.
  faceoff   the mode art (lobby mode card, match loading card): two fighters squaring up across
            a hazard line inside a slice of the Cargo Cage hall, built from the map's own props
            (wall bays with high windows, columns, roof trusses, hanging tubes, containers,
            crates), blue rim light on the left fighter and orange on the right one.

usage: blender -b --python tools/media/render_keyart.py -- --scene hero --out art.png
           [--bundle shadow] [--opponent desert|none] [--res 1920x1080] [--samples 64]
       blender -b --python tools/media/render_keyart.py -- --scene portrait --bundle neon --out p.png
           [--res 360x480] [--samples 48]
       blender -b --python tools/media/render_keyart.py -- --scene faceoff --out duel.png
           [--bundle neon] [--opponent desert] [--res 1280x720] [--samples 48]"""
import json
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


SCENE = arg("--scene", "hero")
BUNDLE = arg("--bundle", "neon" if SCENE in ("hero", "faceoff") else "default")
OPPONENT = arg("--opponent", "desert" if SCENE == "faceoff" else "shadow")
OUT = arg("--out", os.path.join(HERE, "_work", "keyart.png"))   # default: outside res://
os.makedirs(os.path.dirname(os.path.abspath(OUT)), exist_ok=True)
RES = [int(v) for v in arg("--res", {"hero": "1920x1080", "faceoff": "1280x720"}.get(SCENE, "360x480")).split("x")]
SAMPLES = int(arg("--samples", "64" if SCENE == "hero" else "48"))
CHAR = os.path.join(ROOT, "assets", "character", "character.glb")
PROPS = os.path.join(ROOT, "assets", "props")
MANIFEST = json.load(open(os.path.join(ROOT, "assets", "character", "manifest.json")))

bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
sc.render.engine = "CYCLES"
sc.cycles.device = "CPU"
sc.cycles.samples = SAMPLES
sc.cycles.use_denoising = True
sc.cycles.max_bounces = 6
sc.render.resolution_x, sc.render.resolution_y = RES
sc.render.resolution_percentage = 100
sc.render.fps = 30
sc.view_settings.view_transform = "AgX"
try:
    sc.view_settings.look = "AgX - Punchy" if SCENE in ("hero", "faceoff") else "AgX - Medium High Contrast"
except Exception:
    pass


def base_name(name):
    """Object name without Blender's .001 duplicate suffix."""
    return name.rsplit(".", 1)[0] if len(name) > 4 and name[-4] == "." and name[-3:].isdigit() else name


def add_character(bundle_id, loc, turn_deg, action="idle", frame=0, rifle=True):
    """Imports the character GLB (again), shows one bundle's outfit, poses it and puts the AR in
    its hands. Returns the armature."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=CHAR)
    new = [o for o in bpy.data.objects if o not in before]
    arm = next(o for o in new if o.type == "ARMATURE")
    bundle = next((b for b in MANIFEST["bundles"] if b["id"] == bundle_id), MANIFEST["bundles"][0])
    for ob in new:
        if ob.type != "MESH":
            continue
        n = base_name(ob.name)
        if n.startswith("Outfit_"):
            ob.hide_render = n not in bundle["meshes"]
        elif n in bundle.get("hide", []):
            ob.hide_render = True
    # The first import owns the clean action names; later imports add suffixed copies.
    act = bpy.data.actions.get(action)
    arm.animation_data_create()
    arm.animation_data.action = act
    if hasattr(arm.animation_data, "action_slot") and act is not None and act.slots:
        arm.animation_data.action_slot = act.slots[0]
    arm.location = Vector(loc)
    arm.rotation_mode = "XYZ"           # imported as quaternion: euler edits would be ignored
    arm.rotation_euler = (0, 0, math.radians(turn_deg))
    sc.frame_set(frame)
    bpy.context.view_layer.update()
    if rifle:
        attach_rifle(arm)
    return arm


def attach_rifle(arm):
    """The AR in the right hand, barrel toward the left hand (like the game's held weapon)."""
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(PROPS, "weapon_ar.glb"))
    gun_roots = [o for o in bpy.data.objects if o not in before and o.parent is None]
    hand = arm.matrix_world @ arm.pose.bones["hand_r"].head
    fore = arm.matrix_world @ arm.pose.bones["lowerarm_r"].head
    grip = hand + (hand - fore).normalized() * 0.055
    lh = arm.matrix_world @ arm.pose.bones["hand_l"].head
    aim = lh - grip
    aim.z *= 0.35
    aim = aim.normalized() if aim.length > 0.01 else Vector((0, -1, 0))
    y_axis = aim
    x_axis = y_axis.cross(Vector((0, 0, 1))).normalized()
    z_axis = x_axis.cross(y_axis).normalized()
    g = Matrix((x_axis, y_axis, z_axis)).transposed().to_4x4()
    g.translation = grip
    for o in gun_roots:
        o.matrix_world = g @ o.matrix_world


def add_prop(name, loc, rot_deg, scale=1.0, color=None):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(PROPS, name + ".glb"))
    roots = [o for o in bpy.data.objects if o not in before and o.parent is None]
    m = Matrix.Translation(Vector(loc)) @ Matrix.Rotation(math.radians(rot_deg), 4, "Z") @ Matrix.Scale(scale, 4)
    for o in roots:
        o.matrix_world = m @ o.matrix_world
    if color:
        for o in bpy.data.objects:
            if o in before or o.type != "MESH":
                continue
            for slot in o.material_slots:
                mat = slot.material
                if mat and "paint" in mat.name.lower():
                    mat = mat.copy()
                    slot.material = mat
                    bsdf = mat.node_tree.nodes.get("Principled BSDF") if mat.use_nodes else None
                    if bsdf:
                        bsdf.inputs["Base Color"].default_value = color


def flat_material(name, color, rough=0.6, emit=None, strength=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = color
    b.inputs["Roughness"].default_value = rough
    if emit is not None:
        b.inputs["Emission Color"].default_value = emit
        b.inputs["Emission Strength"].default_value = strength
    return m


def add_box(name, center, size, mat):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=center)
    ob = bpy.context.active_object
    ob.name = name
    ob.scale = size
    ob.data.materials.append(mat)
    return ob


def light(name, kind, loc, target, energy, color, size=1.0, spot=None):
    ld = bpy.data.lights.new(name, kind)
    ld.energy = energy
    ld.color = color
    if kind == "AREA":
        ld.size = size
    if kind == "SUN":
        ld.angle = math.radians(size)
    if kind == "SPOT" and spot:
        ld.spot_size = math.radians(spot)
        ld.spot_blend = 0.4
    ob = bpy.data.objects.new(name, ld)
    sc.collection.objects.link(ob)
    ob.location = loc
    d = Vector(target) - Vector(loc)
    ob.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    return ob


def camera(loc, look, lens, fstop=None, focus=None):
    cd = bpy.data.cameras.new("Cam")
    cd.lens = lens
    cam = bpy.data.objects.new("Cam", cd)
    sc.collection.objects.link(cam)
    sc.camera = cam
    cam.location = Vector(loc)
    cam.rotation_euler = (Vector(look) - cam.location).to_track_quat("-Z", "Y").to_euler()
    if fstop:
        cd.dof.use_dof = True
        cd.dof.aperture_fstop = fstop
        cd.dof.focus_distance = (Vector(focus) - cam.location).length
    return cam


def srgb(c):
    """8-bit sRGB colour -> linear RGBA (shader colours are linear)."""
    out = []
    for v in c:
        v = v / 255.0
        out.append(v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4)
    return (*out, 1.0)


def sunset_world(sun_dir):
    """Sky by view direction: warm horizon -> rose -> violet zenith, a glow around the sun and
    faint streaky clouds above the horizon."""
    world = bpy.data.worlds.new("Sky")
    world.use_nodes = True
    nt = world.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    tex = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(tex.outputs["Generated"], sep.inputs[0])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    stops = [(0.0, (255, 176, 84)), (0.05, (255, 124, 52)), (0.14, (236, 84, 84)), (0.27, (132, 62, 150)),
             (0.42, (52, 58, 150)), (0.66, (18, 30, 92))]
    els = ramp.color_ramp.elements
    while len(els) < len(stops):
        els.new(0.5)
    for e, (pos, col) in zip(els, stops):
        e.position = pos
        e.color = srgb(col)
    nt.links.new(sep.outputs["Z"], ramp.inputs[0])
    # sun glow: (dot(view, sun) ^ k) in warm yellow
    dot = nt.nodes.new("ShaderNodeVectorMath")
    dot.operation = "DOT_PRODUCT"
    dot.inputs[1].default_value = Vector(sun_dir).normalized()
    nt.links.new(tex.outputs["Generated"], dot.inputs[0])
    clamp = nt.nodes.new("ShaderNodeMath")
    clamp.operation = "MAXIMUM"
    clamp.inputs[1].default_value = 0.0
    nt.links.new(dot.outputs["Value"], clamp.inputs[0])
    pw = nt.nodes.new("ShaderNodeMath")
    pw.operation = "POWER"
    pw.inputs[1].default_value = 48.0
    nt.links.new(clamp.outputs[0], pw.inputs[0])
    halo = nt.nodes.new("ShaderNodeMixRGB")
    halo.blend_type = "ADD"
    halo.inputs["Color2"].default_value = srgb((255, 150, 60))
    nt.links.new(pw.outputs[0], halo.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], halo.inputs["Color1"])
    pw2 = nt.nodes.new("ShaderNodeMath")
    pw2.operation = "POWER"
    pw2.inputs[1].default_value = 900.0
    nt.links.new(clamp.outputs[0], pw2.inputs[0])
    core = nt.nodes.new("ShaderNodeMath")
    core.operation = "MULTIPLY"
    core.inputs[1].default_value = 6.0
    nt.links.new(pw2.outputs[0], core.inputs[0])
    glow = nt.nodes.new("ShaderNodeMixRGB")
    glow.blend_type = "ADD"
    glow.inputs["Color2"].default_value = srgb((255, 236, 190))
    nt.links.new(core.outputs[0], glow.inputs["Fac"])
    nt.links.new(halo.outputs["Color"], glow.inputs["Color1"])
    # clouds: stretched noise, only in a band above the horizon
    mapping = nt.nodes.new("ShaderNodeMapping")
    mapping.inputs["Scale"].default_value = (1.2, 1.2, 9.0)
    nt.links.new(tex.outputs["Generated"], mapping.inputs["Vector"])
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 2.2
    noise.inputs["Detail"].default_value = 6.0
    nt.links.new(mapping.outputs["Vector"], noise.inputs["Vector"])
    band = nt.nodes.new("ShaderNodeMapRange")
    band.inputs["From Min"].default_value = 0.52
    band.inputs["From Max"].default_value = 0.75
    nt.links.new(noise.outputs["Fac"], band.inputs["Value"])
    zmask = nt.nodes.new("ShaderNodeMapRange")
    zmask.inputs["From Min"].default_value = 0.05
    zmask.inputs["From Max"].default_value = 0.3
    zmask.inputs["To Min"].default_value = 0.0
    zmask.inputs["To Max"].default_value = 1.0
    nt.links.new(sep.outputs["Z"], zmask.inputs["Value"])
    zfall = nt.nodes.new("ShaderNodeMath")
    zfall.operation = "PINGPONG"
    zfall.inputs[1].default_value = 0.5
    nt.links.new(zmask.outputs["Result"], zfall.inputs[0])
    cm = nt.nodes.new("ShaderNodeMath")
    cm.operation = "MULTIPLY"
    nt.links.new(band.outputs["Result"], cm.inputs[0])
    nt.links.new(zfall.outputs[0], cm.inputs[1])
    cm2 = nt.nodes.new("ShaderNodeMath")
    cm2.operation = "MULTIPLY"
    cm2.inputs[1].default_value = 0.55
    nt.links.new(cm.outputs[0], cm2.inputs[0])
    clouds = nt.nodes.new("ShaderNodeMixRGB")
    clouds.blend_type = "MIX"
    clouds.inputs["Color2"].default_value = srgb((255, 196, 160))
    nt.links.new(cm2.outputs[0], clouds.inputs["Fac"])
    nt.links.new(glow.outputs["Color"], clouds.inputs["Color1"])
    bg = nt.nodes.new("ShaderNodeBackground")
    bg.inputs[1].default_value = 1.0
    out = nt.nodes.new("ShaderNodeOutputWorld")
    nt.links.new(clouds.outputs["Color"], bg.inputs[0])
    nt.links.new(bg.outputs[0], out.inputs[0])
    sc.world = world


def hero():
    # Character at the origin facing screen-right and a little toward the camera.
    add_character(BUNDLE, (0, 0, 0), 62, "idle", 0)
    if OPPONENT != "none":
        # The rival on a container across the yard, facing the hero (a duel).
        add_character(OPPONENT, (3.6, 14.6, 2.59), -14, "idle", 20)
    # Container yard: a two-high stack to the right, a single one across the yard (the rival's
    # perch), a stack far left behind the hero and a gantry crane on the skyline.
    add_prop("container", (6.6, 10.6, 0), 4, 1.0, (0.50, 0.08, 0.04, 1))
    add_prop("container", (6.6, 10.6, 2.59), 4, 1.0, (0.05, 0.16, 0.40, 1))
    add_prop("container", (3.6, 14.6, 0), 90, 1.0, (0.78, 0.62, 0.42, 1))
    add_prop("container", (11.5, 16.0, 0), -8, 1.0, (0.70, 0.36, 0.04, 1))
    add_prop("container", (-7.0, 15.0, 0), -14, 1.0, (0.60, 0.30, 0.05, 1))
    add_prop("container", (-7.0, 15.0, 2.59), -14, 1.0, (0.06, 0.30, 0.36, 1))
    add_prop("barrel", (3.1, 4.4, 0), 0)
    add_prop("barrel", (3.75, 4.9, 0), 30)
    steel = flat_material("Gantry", (0.05, 0.04, 0.05, 1), 0.5, (0.30, 0.12, 0.26, 1), 0.35)
    for x in (-20.0, 10.0):
        add_box("GantryLeg", (x, 80.0, 11.0), (1.4, 1.4, 22.0), steel)
    add_box("GantryBeam", (-5.0, 80.0, 22.6), (40.0, 2.2, 2.6), steel)
    add_box("GantryBoom", (-16.0, 72.0, 23.4), (2.0, 18.0, 1.2), steel)
    add_box("GantryCab", (0.0, 79.0, 19.8), (3.6, 3.0, 2.6), steel)
    lamp = flat_material("Lamp", (1, 0.8, 0.5, 1), 0.5, (1.0, 0.75, 0.4, 1), 40.0)
    for x in (-16.0, -6.0, 4.0):
        add_box("GantryLamp", (x, 78.6, 21.0), (1.0, 0.4, 0.4), lamp)
    # Ground: concrete with a yellow lane line.
    me = bpy.data.meshes.new("Ground")
    s = 120.0
    me.from_pydata([(-s, -s, 0), (s, -s, 0), (s, s, 0), (-s, s, 0)], [], [(0, 1, 2, 3)])
    ground = bpy.data.objects.new("Ground", me)
    sc.collection.objects.link(ground)
    gm = flat_material("Concrete", (0.20, 0.17, 0.16, 1), 0.38)
    me.materials.append(gm)
    stripe = flat_material("Stripe", (0.85, 0.55, 0.04, 1), 0.5)
    add_box("Lane", (1.7, 8.0, 0.004), (0.2, 26.0, 0.01), stripe).rotation_euler = (0, 0, math.radians(-10))

    sun_dir = (0.21, 1.0, 0.085)
    sunset_world(sun_dir)
    light("Sun", "SUN", (20, 40, 6), (0, 0, 1), 2.4, (1.0, 0.62, 0.36), 2.0)
    light("Key", "AREA", (2.4, -2.9, 2.6), (0, 0, 1.3), 520, (1.0, 0.86, 0.72), 2.4)
    light("Fill", "AREA", (-2.4, -3.2, 1.2), (0, 0, 1.1), 110, (0.55, 0.62, 1.0), 3.0)
    light("RimWarm", "AREA", (1.2, 2.4, 2.3), (0, 0, 1.35), 2600, (1.0, 0.50, 0.20), 1.0)
    light("RimCool", "AREA", (-2.2, 0.9, 2.1), (0, 0, 1.25), 2200, (0.25, 0.70, 1.0), 0.9)
    light("OppRim", "AREA", (5.0, 17.0, 6.0), (3.6, 14.6, 3.6), 700, (1.0, 0.45, 0.2), 1.5)
    # Low hero angle; the character on the left third, the yard opening to the right.
    camera((0.68, -4.4, 0.55), (0.72, 0.0, 1.16), 40, 1.6, (0.0, 0.0, 1.3))


def set_emission(name_part, color, strength, exclude="@"):
    """Makes every imported material whose name contains `name_part` (and not `exclude`)
    glow: the hall's windows and tubes."""
    for mat in bpy.data.materials:
        n = mat.name.lower()
        if name_part.lower() in n and exclude.lower() not in n and mat.use_nodes:
            b = mat.node_tree.nodes.get("Principled BSDF")
            if b:
                b.inputs["Emission Color"].default_value = color
                b.inputs["Emission Strength"].default_value = strength


def hazard_strip(name, center, length, width):
    """A yellow / black diagonal hazard strip on the floor (procedural bands), along +Y."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    b.inputs["Roughness"].default_value = 0.45
    geo = nt.nodes.new("ShaderNodeNewGeometry")          # world position: stripes keep their size
    mapping = nt.nodes.new("ShaderNodeMapping")
    mapping.inputs["Rotation"].default_value = (0, 0, math.radians(45))
    nt.links.new(geo.outputs["Position"], mapping.inputs["Vector"])
    wave = nt.nodes.new("ShaderNodeTexWave")
    wave.wave_type = "BANDS"
    wave.bands_direction = "X"
    wave.wave_profile = "SAW"
    wave.inputs["Scale"].default_value = 1.6
    wave.inputs["Distortion"].default_value = 0.0
    nt.links.new(mapping.outputs["Vector"], wave.inputs["Vector"])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.interpolation = "CONSTANT"
    ramp.color_ramp.elements[0].color = srgb((240, 186, 20))
    ramp.color_ramp.elements[1].position = 0.5
    ramp.color_ramp.elements[1].color = srgb((18, 18, 18))
    nt.links.new(wave.outputs["Fac"], ramp.inputs[0])
    nt.links.new(ramp.outputs["Color"], b.inputs["Base Color"])
    return add_box(name, (center[0], center[1], 0.004), (width, length, 0.008), m)


def faceoff():
    # The duel: our hero on the left facing right, the rival on the right facing left, both a
    # little toward the camera, rifles at the ready, a hazard line on the floor between them.
    add_character(BUNDLE, (-1.3, 0.0, 0), 74, "idle", 0)
    add_character(OPPONENT, (1.3, 0.3, 0), -74, "idle", 24)
    hazard_strip("Line", (0.0, 4.0), 16.0, 0.32)
    # The hall behind them: containers and crates on the floor, the back wall (bays with high
    # windows between steel columns), roof trusses with hanging fluorescent tubes.
    add_prop("container_40", (-7.2, 9.6, 0), 0, 1.0, (0.20, 0.55, 0.78, 1))
    add_prop("container", (6.4, 8.8, 0), 0, 1.0, (0.85, 0.36, 0.05, 1))
    add_prop("container", (6.4, 8.8, 2.59), 0, 1.0, (0.62, 0.10, 0.06, 1))
    add_prop("container", (12.0, 10.5, 0), 90, 1.0, (0.10, 0.25, 0.62, 1))
    add_prop("crate", (-2.9, 6.2, 0), 8)
    add_prop("crate", (-1.75, 6.4, 0), -6)
    add_prop("crate", (-2.3, 6.3, 1.2), 3)
    add_prop("barrel", (3.0, 5.6, 0), 0)
    add_prop("barrel", (3.6, 6.1, 0), 40)
    for i in range(-5, 6):
        add_prop("wall_bay", (i * 6.0, 17.0, 0), 180)      # window side toward the camera
        add_prop("wall_column", (i * 6.0 + 3.0, 16.7, 0), 0)
    for y in (4.0, 10.5):
        add_prop("roof_truss", (0.0, y, 8.6), 0)
        for x in (-7.5, 0.0, 7.5):
            add_prop("lamp_tube", (x, y, 8.6), 90)
    set_emission("glass", (0.80, 0.90, 1.0, 1), 9.0)
    set_emission("lamp", (1.0, 0.97, 0.9, 1), 14.0, exclude="housing")
    me = bpy.data.meshes.new("Floor")
    s = 60.0
    me.from_pydata([(-s, -s, 0), (s, -s, 0), (s, s, 0), (-s, s, 0)], [], [(0, 1, 2, 3)])
    fl = bpy.data.objects.new("Floor", me)
    sc.collection.objects.link(fl)
    me.materials.append(flat_material("Concrete", srgb((92, 94, 100)), 0.3))
    world = bpy.data.worlds.new("Hall")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.03, 0.034, 0.05, 1)
    world.node_tree.nodes["Background"].inputs[1].default_value = 1.0
    sc.world = world
    # key from the front, a blue rim behind the hero and an orange one behind the rival, and
    # the back wall washed blue on the left and orange on the right (the two sides of the duel)
    light("Key", "SPOT", (0.0, -3.4, 4.6), (0, 0.1, 1.15), 1000, (1.0, 0.93, 0.85), spot=46)
    light("Fill", "AREA", (0.0, -5.5, 1.6), (0, 0, 1.2), 90, (0.75, 0.8, 1.0), 4.0)
    light("RimBlue", "AREA", (-3.4, 3.4, 2.6), (-1.3, 0.0, 1.35), 4200, (0.2, 0.6, 1.0), 1.0)
    light("RimOrange", "AREA", (3.4, 3.8, 2.6), (1.3, 0.3, 1.35), 4200, (1.0, 0.42, 0.12), 1.0)
    light("KickBlue", "AREA", (-2.6, -1.2, 0.6), (-1.3, 0.0, 1.0), 260, (0.3, 0.6, 1.0), 1.0)
    light("KickOrange", "AREA", (2.6, -0.9, 0.6), (1.3, 0.3, 1.0), 260, (1.0, 0.5, 0.2), 1.0)
    light("WashBlue", "SPOT", (-9.0, 9.0, 6.5), (-9.0, 17.0, 2.5), 12000, (0.25, 0.55, 1.0), spot=70)
    light("WashOrange", "SPOT", (9.0, 9.0, 6.5), (9.0, 17.0, 2.5), 12000, (1.0, 0.5, 0.2), spot=70)
    # low camera; the fighters at about 0.27 and 0.73 of the width, 60 % of the height
    camera((0.0, -4.8, 0.95), (0.0, 0.0, 1.22), 32, 2.4, (0.0, 0.15, 1.3))


def portrait():
    sc.render.film_transparent = True
    add_character(BUNDLE, (0, 0, 0), 22, "idle", 0)
    world = bpy.data.worlds.new("Studio")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.32, 0.33, 0.38, 1)
    world.node_tree.nodes["Background"].inputs[1].default_value = 0.6
    sc.world = world
    light("Key", "AREA", (1.8, -2.6, 2.6), (0, 0, 1.2), 520, (1.0, 0.92, 0.84), 2.2)
    light("Fill", "AREA", (-2.4, -2.0, 1.4), (0, 0, 1.0), 160, (0.7, 0.8, 1.0), 2.5)
    light("Rim", "AREA", (-1.2, 2.2, 2.4), (0, 0, 1.3), 900, (0.9, 0.95, 1.0), 1.2)
    light("Rim2", "AREA", (1.6, 2.0, 1.8), (0, 0, 1.1), 600, (1.0, 0.8, 0.6), 1.0)
    camera((0.2, -3.0, 1.05), (0.08, 0.0, 0.92), 50)


if SCENE == "portrait":
    portrait()
elif SCENE == "faceoff":
    faceoff()
else:
    hero()
sc.render.filepath = OUT
sc.render.image_settings.file_format = "PNG"
sc.render.image_settings.color_mode = "RGBA" if SCENE == "portrait" else "RGB"
bpy.ops.render.render(write_still=True)
print("KEYART", OUT)
