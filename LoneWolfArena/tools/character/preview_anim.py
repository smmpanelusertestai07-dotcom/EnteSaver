"""Render key frames of animations (optionally with a placeholder rifle that is NOT exported).
usage: python3 preview_anim.py --blend X.blend --items idle:0,run_fwd:5 --bundle default --out sheet.png
       [--cam az,dist,h,tz] [--res 384] [--norifle] [--labels]"""
import os
import sys
import math

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import bmesh
from mathutils import Matrix, Vector
import char_config as CFG
import preview_lib as PL

argv = sys.argv


def arg(name, default=None):
    return argv[argv.index(name) + 1] if name in argv else default


blend = arg("--blend", os.path.join(CFG.WORK, "stage_c.blend"))
items = [(x.split(":")[0], int(x.split(":")[1])) for x in arg("--items", "idle:0").split(",")]
bundle = arg("--bundle", "default")
out = arg("--out", "/root/work/tools/character/scratch/anim.png")
cam = [float(v) for v in arg("--cam", "30,3.3,1.05,0.85").split(",")]
res = int(arg("--res", "384"))
cols = int(arg("--cols", "4"))
rifle = "--norifle" not in argv
RIFLE_ANIMS = {"idle", "run_fwd", "run_back", "run_left", "run_right", "crouch_idle", "crouch_fwd", "jump"}

bpy.ops.wm.open_mainfile(filepath=blend)
arm = bpy.data.objects["Armature"]
sc = bpy.context.scene
PL.setup_scene(res=res, samples=int(arg("--samples", "12")))


def make_rifle():
    """Simple placeholder assault rifle along +Y, origin at the pistol grip top."""
    bm = bmesh.new()

    def box(cx, cy, cz, sx, sy, sz):
        r = bmesh.ops.create_cube(bm, size=1.0)
        for v in r["verts"]:
            v.co = Vector((cx + v.co.x * sx, cy + v.co.y * sy, cz + v.co.z * sz))
    box(0, 0.10, 0.05, 0.05, 0.42, 0.08)      # receiver/handguard
    box(0, 0.48, 0.065, 0.025, 0.36, 0.025)   # barrel
    box(0, -0.22, 0.03, 0.045, 0.22, 0.10)    # stock
    box(0, 0.05, -0.05, 0.035, 0.05, 0.11)    # magazine-ish grip area
    box(0, 0.12, -0.08, 0.04, 0.06, 0.16)     # magazine
    box(0, -0.02, -0.06, 0.03, 0.04, 0.10)    # pistol grip
    me = bpy.data.meshes.new("PreviewRifle")
    bm.to_mesh(me)
    ob = bpy.data.objects.new("PreviewRifle", me)
    sc.collection.objects.link(ob)
    mat = bpy.data.materials.new("PreviewRifleMat")
    mat.use_nodes = True
    mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"].default_value = (0.03, 0.03, 0.035, 1)
    mat.node_tree.nodes["Principled BSDF"].inputs["Roughness"].default_value = 0.45
    me.materials.append(mat)
    return ob


rifle_ob = None
if rifle:
    # place at idle frame 0: grip at right hand palm, axis towards the left hand palm
    act0 = bpy.data.actions.get("idle")
    arm.animation_data.action = act0
    sc.frame_set(0)
    pr = arm.pose.bones["hand_r"]
    pl = arm.pose.bones["hand_l"]
    mr = arm.matrix_world @ pr.matrix
    ml = arm.matrix_world @ pl.matrix
    # palm centres ~6 cm along the bone direction from the wrist
    wr = mr.translation
    wl = ml.translation
    gr = mr @ Vector((0, 0.07, 0))
    yax = (wl - wr).normalized()
    up = Vector((0, 0, 1))
    xax = yax.cross(up).normalized()
    zax = xax.cross(yax).normalized()
    M = Matrix((xax, yax, zax)).transposed().to_4x4()
    M.translation = gr + zax * 0.035
    rifle_ob = make_rifle()
    rifle_ob.matrix_world = M
    rifle_ob.parent = arm
    rifle_ob.parent_type = 'BONE'
    rifle_ob.parent_bone = "hand_r"
    bone_world = arm.matrix_world @ pr.matrix @ Matrix.Translation(Vector((0, arm.data.bones["hand_r"].length, 0)))
    rifle_ob.matrix_parent_inverse = bone_world.inverted()
    rifle_ob.matrix_basis = Matrix.Identity(4)
    rifle_ob.matrix_parent_inverse = bone_world.inverted() @ M

allm = [o.name for o in bpy.data.objects if o.type == 'MESH' and not o.name.startswith("Preview")]
base = CFG.BODY_PARTS + ["Eyes", "Eyebrows", "Eyelashes", "Hair_Default"]
parts = [p for b, d, pl_ in CFG.BUNDLES if b == bundle for p, _ in pl_]
hide = CFG.BUNDLE_HIDE.get(bundle, [])
vis = [b for b in base if b not in hide] + ["Outfit_%s_%s" % (bundle, p) for p in parts]
PL.show_only(vis, allm)

imgs = []
for name, f in items:
    arm.animation_data.action = bpy.data.actions[name]
    sc.frame_set(f)
    if rifle_ob is not None:
        rifle_ob.hide_render = name not in RIFLE_ANIMS
    tz = cam[3] if name not in ("death",) else 0.5
    PL.set_camera(azimuth_deg=cam[0], dist=cam[1] if name != "death" else cam[1] * 1.15, height=cam[2], target_z=tz,
                  target_xy=(0.0, 0.0 if name != "death" else 0.25))
    p = out.replace(".png", "_%s_%d.png" % (name, f))
    PL.render(p)
    imgs.append((p, "%s f%d" % (name, f)))

from PIL import Image, ImageDraw
n = len(imgs)
c = min(cols, n)
r = (n + c - 1) // c
sheet = Image.new("RGB", (res * c, res * r))
d = ImageDraw.Draw(sheet)
for i, (p, lab) in enumerate(imgs):
    x, y = (i % c) * res, (i // c) * res
    sheet.paste(Image.open(p), (x, y))
    if "--labels" in argv:
        d.text((x + 6, y + 6), lab, fill=(255, 255, 255))
sheet.save(out)
print("sheet", out)
