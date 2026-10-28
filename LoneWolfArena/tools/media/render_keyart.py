"""Renders the key art used by the loading screen and the lobby banner: the game's own character
(chosen bundle) holding the AR, low 3/4 hero angle, warm key light + cool rim light, stacked
containers out of focus behind. Text/logo are added afterwards by tools/media/make_keyart.py.

usage: blender -b --python tools/media/render_keyart.py -- --bundle shadow --out art.png
       [--res 1920x1080] [--samples 64] [--action idle --frame 0] [--side right]"""
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


BUNDLE = arg("--bundle", "shadow")
OUT = arg("--out", "/tmp/keyart.png")
RES = [int(v) for v in arg("--res", "1920x1080").split("x")]
SAMPLES = int(arg("--samples", "64"))
ACTION = arg("--action", "idle")
FRAME = int(arg("--frame", "0"))
SIDE = arg("--side", "right")      # where the character stands in the frame
CHAR = os.path.join(ROOT, "assets", "character", "character.glb")
PROPS = os.path.join(ROOT, "assets", "props")

import json
MANIFEST = json.load(open(os.path.join(ROOT, "assets", "character", "manifest.json")))

bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
sc.render.engine = "CYCLES"
sc.cycles.device = "CPU"
sc.cycles.samples = SAMPLES
sc.cycles.use_denoising = True
sc.render.resolution_x, sc.render.resolution_y = RES
sc.render.fps = 30
sc.view_settings.view_transform = "AgX"
try:
    sc.view_settings.look = "AgX - Punchy"
except Exception:
    pass

bpy.ops.import_scene.gltf(filepath=CHAR)
arm = bpy.data.objects["Armature"]
bundle = next((b for b in MANIFEST["bundles"] if b["id"] == BUNDLE), MANIFEST["bundles"][0])
for ob in bpy.data.objects:
    if ob.type != "MESH":
        continue
    if ob.name.startswith("Outfit_"):
        ob.hide_render = ob.name not in bundle["meshes"]
    elif ob.name in bundle.get("hide", []):
        ob.hide_render = True
act = bpy.data.actions.get(ACTION)
arm.animation_data_create()
arm.animation_data.action = act
if hasattr(arm.animation_data, "action_slot") and act is not None and act.slots:
    arm.animation_data.action_slot = act.slots[0]
sc.frame_set(FRAME)
TURN = float(arg("--turn", "-60"))      # rotate the character (deg about Z) to face into the frame
arm.rotation_euler = (0, 0, math.radians(TURN))
bpy.context.view_layer.update()
sc.frame_set(FRAME)

# Rifle in the right hand, barrel where the character faces (-Y); GLB barrel is +Y in Blender.
before = set(bpy.data.objects)
bpy.ops.import_scene.gltf(filepath=os.path.join(PROPS, "weapon_ar.glb"))
gun_roots = [o for o in bpy.data.objects if o not in before and o.parent is None]
hand = arm.matrix_world @ arm.pose.bones["hand_r"].head
fore = arm.matrix_world @ arm.pose.bones["lowerarm_r"].head
grip = hand + (hand - fore).normalized() * 0.055
lh = arm.matrix_world @ arm.pose.bones["hand_l"].head
aim = (lh - grip)
aim.z = 0.0
aim = aim.normalized() if aim.length > 0.01 else Vector((0, -1, 0))
y_axis = aim
x_axis = y_axis.cross(Vector((0, 0, 1))).normalized()
z_axis = x_axis.cross(y_axis).normalized()
G = Matrix((x_axis, y_axis, z_axis)).transposed().to_4x4()
G.translation = grip
for o in gun_roots:
    o.matrix_world = G @ o.matrix_world


def add_prop(name, loc, rot_deg, scale=1.0, color=None):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=os.path.join(PROPS, name + ".glb"))
    roots = [o for o in bpy.data.objects if o not in before and o.parent is None]
    M = Matrix.Translation(Vector(loc)) @ Matrix.Rotation(math.radians(rot_deg), 4, "Z") @ Matrix.Scale(scale, 4)
    for o in roots:
        o.matrix_world = M @ o.matrix_world
    if color:
        for o in bpy.data.objects:
            if o in before or o.type != "MESH":
                continue
            for slot in o.material_slots:
                m = slot.material
                if m and "paint" in m.name.lower():
                    m = m.copy()
                    slot.material = m
                    bsdf = m.node_tree.nodes.get("Principled BSDF") if m.use_nodes else None
                    if bsdf:
                        bsdf.inputs["Base Color"].default_value = color


# Background: stacked shipping containers (out of focus) and the ground.
add_prop("container", (3.5, 9.0, 0), 8, 1.0, (0.42, 0.06, 0.04, 1))
add_prop("container", (3.5, 9.0, 2.59), 8, 1.0, (0.04, 0.14, 0.36, 1))
add_prop("container", (-5.5, 11.5, 0), -12, 1.0, (0.55, 0.26, 0.03, 1))
add_prop("container", (-5.5, 11.5, 2.59), -12, 1.0, (0.05, 0.25, 0.10, 1))
add_prop("container", (-9.5, 6.0, 0), 80, 1.0, (0.06, 0.26, 0.11, 1))
add_prop("crate", (2.4, 3.4, 0), 20)
add_prop("sandbags", (-3.2, 4.2, 0), -10)
me = bpy.data.meshes.new("Ground")
s = 60.0
me.from_pydata([(-s, -s, 0), (s, -s, 0), (s, s, 0), (-s, s, 0)], [], [(0, 1, 2, 3)])
ground = bpy.data.objects.new("Ground", me)
sc.collection.objects.link(ground)
gm = bpy.data.materials.new("GroundMat")
gm.use_nodes = True
bsdf = gm.node_tree.nodes["Principled BSDF"]
bsdf.inputs["Base Color"].default_value = (0.16, 0.13, 0.11, 1)
bsdf.inputs["Roughness"].default_value = 0.55
me.materials.append(gm)

# Sky: warm sunset gradient (horizon orange -> zenith violet).
world = bpy.data.worlds.new("Sky")
world.use_nodes = True
nt = world.node_tree
for n in list(nt.nodes):
    nt.nodes.remove(n)
tex = nt.nodes.new("ShaderNodeTexCoord")
sep = nt.nodes.new("ShaderNodeSeparateXYZ")
ramp = nt.nodes.new("ShaderNodeValToRGB")
ramp.color_ramp.elements[0].position = 0.0
ramp.color_ramp.elements[0].color = (1.0, 0.42, 0.10, 1)
ramp.color_ramp.elements[1].position = 0.55
ramp.color_ramp.elements[1].color = (0.20, 0.06, 0.32, 1)
mid = ramp.color_ramp.elements.new(0.18)
mid.color = (0.95, 0.20, 0.25, 1)
bg = nt.nodes.new("ShaderNodeBackground")
bg.inputs[1].default_value = 1.6
out = nt.nodes.new("ShaderNodeOutputWorld")
nt.links.new(tex.outputs["Generated"], sep.inputs[0])
nt.links.new(sep.outputs["Z"], ramp.inputs[0])
nt.links.new(ramp.outputs["Color"], bg.inputs[0])
nt.links.new(bg.outputs[0], out.inputs[0])
sc.world = world


def light(name, kind, loc, target, energy, color, size=1.0, spot=None):
    ld = bpy.data.lights.new(name, kind)
    ld.energy = energy
    ld.color = color
    if kind == "AREA":
        ld.size = size
    if kind == "SPOT" and spot:
        ld.spot_size = math.radians(spot)
        ld.spot_blend = 0.4
    ob = bpy.data.objects.new(name, ld)
    sc.collection.objects.link(ob)
    ob.location = loc
    d = Vector(target) - Vector(loc)
    ob.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
    return ob


light("Sun", "SUN", (6, -4, 8), (0, 0, 0), 3.0, (1.0, 0.72, 0.45))
light("Key", "AREA", (-2.0, -2.6, 2.4), (0, 0, 1.3), 700, (1.0, 0.86, 0.70), 2.0)
light("RimL", "AREA", (1.9, 1.2, 2.2), (0, 0, 1.3), 2600, (0.30, 0.65, 1.0), 0.8)
light("RimR", "AREA", (-1.6, 1.6, 1.9), (0, 0, 1.2), 2000, (1.0, 0.38, 0.55), 0.8)

# Camera: low hero angle, 3/4 front; character on one third of the frame.
cd = bpy.data.cameras.new("Cam")
cd.lens = 45
cd.dof.use_dof = True
cd.dof.aperture_fstop = 1.6
cam = bpy.data.objects.new("Cam", cd)
sc.collection.objects.link(cam)
sc.camera = cam
side = -1.0 if SIDE == "right" else 1.0
cam.location = Vector((side * 0.95 - 0.35, -3.6, 0.78))
look = Vector((side * 0.95 + 0.05, 0.0, 1.18))
cam.rotation_euler = (look - cam.location).to_track_quat("-Z", "Y").to_euler()
cd.dof.focus_distance = (Vector((0, 0, 1.3)) - cam.location).length

sc.render.filepath = OUT
sc.render.image_settings.file_format = "PNG"
bpy.ops.render.render(write_still=True)
print("KEYART", OUT)
