"""Stage D: export character.glb (Y-up, skinned, deform bones only, no morphs, modifiers applied,
embedded JPEG/PNG textures) and write manifest.json."""
import os
import sys
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
import char_config as CFG

bpy.ops.wm.open_mainfile(filepath=os.path.join(CFG.WORK, "stage_c.blend"))
arm = bpy.data.objects["Armature"]
sc = bpy.context.scene
sc.render.fps = 30
sc.frame_set(0)

# clean scene: only armature + its meshes
for ob in list(bpy.data.objects):
    if ob.type not in ('ARMATURE', 'MESH') or (ob.type == 'MESH' and ob.parent != arm):
        bpy.data.objects.remove(ob, do_unlink=True)
meshes = [o for o in bpy.data.objects if o.type == 'MESH']
for ob in meshes:
    ob.hide_viewport = False
    ob.hide_render = False
    ob.hide_set(False)
    assert ob.data.shape_keys is None, ob.name
    for m in ob.modifiers:
        assert m.type == 'ARMATURE', (ob.name, m.type)
arm.animation_data.action = None
for pb in arm.pose.bones:
    pb.location = (0, 0, 0)
    pb.rotation_quaternion = (1, 0, 0, 0)
    pb.scale = (1, 1, 1)

os.makedirs(CFG.OUT_DIR, exist_ok=True)
out = os.path.join(CFG.OUT_DIR, "character.glb")
bpy.ops.export_scene.gltf(
    filepath=out, export_format='GLB', use_selection=False, export_yup=True,
    export_apply=True, export_texcoords=True, export_normals=True, export_tangents=False,
    export_materials='EXPORT', export_image_format='AUTO', export_jpeg_quality=88,
    export_skins=True, export_def_bones=True, export_influence_nb=4, export_all_influences=False,
    export_morph=False, export_animations=True, export_animation_mode='ACTIONS',
    export_force_sampling=True, export_frame_step=1, export_optimize_animation_size=True,
    export_anim_single_armature=True, export_reset_pose_bones=True, export_rest_position_armature=True,
    export_nla_strips=True, export_current_frame=False, export_extras=False, export_cameras=False,
    export_lights=False,
)
print("exported", out, os.path.getsize(out) / 1e6, "MB")

# ----------------------------------------------------------------------------- manifest
anim_info = json.load(open(os.path.join(CFG.WORK, "anim_info.json")))
bones = [b.name for b in arm.data.bones]


def tris(ob):
    return sum(len(p.vertices) - 2 for p in ob.data.polygons)


def category(n):
    if n.startswith("Body_"):
        return "body"
    if n.startswith("Outfit_"):
        return "outfit"
    if n == "Hair_Default":
        return "hair"
    return "face"


mesh_list = [{"name": o.name, "triangles": tris(o), "category": category(o.name),
              "bundle": (o.name.split("_")[1] if o.name.startswith("Outfit_") else None)}
             for o in sorted(meshes, key=lambda o: o.name)]


def to_godot(v):
    """Blender (x, y, z) -> glTF/Godot (x, z, -y)."""
    return [round(v[0], 4), round(v[2], 4), round(-v[1], 4)]


rifle = anim_info["rifle_idle_hands_blender"]
height = max((o.matrix_world @ v.co).z for o in meshes if o.name.startswith("Body_") for v in o.data.vertices)
body_set = set(CFG.BODY_PARTS)
base_tris = sum(m["triangles"] for m in mesh_list if m["category"] in ("body", "face", "hair"))
bundles = []
for bid, disp, parts in CFG.BUNDLES:
    names = ["Outfit_%s_%s" % (bid, p) for p, _ in parts]
    bt = sum(m["triangles"] for m in mesh_list if m["name"] in names)
    bundles.append({"id": bid, "display_name": disp, "meshes": names, "hide": CFG.BUNDLE_HIDE.get(bid, []),
                    "outfit_triangles": bt, "total_triangles_with_full_body_hair": base_tris + bt})

manifest = {
    "file": "character.glb",
    "height_m": round(height, 3),
    "units": "meters; glTF Y-up; character faces +Z in glTF/Godot (Blender -Y); right hand on -X; feet at y=0",
    "bones": {
        "all": bones,
        "count": len(bones),
        "root": "root", "pelvis": "pelvis", "spine_chain": ["spine_01", "spine_02", "spine_03"],
        "neck": "neck_01", "head": "head",
        "clavicle_l": "clavicle_l", "clavicle_r": "clavicle_r",
        "upperarm_l": "upperarm_l", "upperarm_r": "upperarm_r",
        "lowerarm_l": "lowerarm_l", "lowerarm_r": "lowerarm_r",
        "hand_l": "hand_l", "hand_r": "hand_r",
        "thigh_l": "thigh_l", "thigh_r": "thigh_r", "calf_l": "calf_l", "calf_r": "calf_r",
        "foot_l": "foot_l", "foot_r": "foot_r", "ball_l": "ball_l", "ball_r": "ball_r",
        "fingers": [b for b in bones if b.startswith(("thumb_", "index_", "middle_", "ring_", "pinky_"))],
    },
    "meshes": mesh_list,
    "base_meshes": {"body_parts": CFG.BODY_PARTS, "always_on": ["Eyes", "Eyebrows", "Eyelashes"],
                    "default_hair": "Hair_Default"},
    "bundles": bundles,
    "default_bundle": "default",
    "animations": [{"name": n, "frames": v["frames"], "frame_range": [v["frame_start"], v["frame_end"]],
                    "seconds": round(v["seconds"], 4), "fps": 30, "loop": v["loop"]}
                   for n, v in anim_info["animations"].items()],
    "locomotion": {"run_speed_mps_at_1x": 2.0, "run_cycle_s": 0.7, "run_stride_m": 1.4,
                   "crouch_fwd_speed_mps_at_1x": 1.0, "crouch_pelvis_drop_m": 0.45,
                   "note": "in place; scale playback rate by (actual speed / speed_at_1x) to avoid foot sliding"},
    "rifle_pose": {
        "description": "idle frame 0 world-space wrist (hand bone head) positions; gameplay anims keep the same grip relative to spine_03",
        "hand_r_blender": rifle["r"]["pos"], "hand_l_blender": rifle["l"]["pos"],
        "hand_r_godot": to_godot(rifle["r"]["pos"]), "hand_l_godot": to_godot(rifle["l"]["pos"]),
        "design_targets_blender": anim_info["rifle_design_targets_blender"],
        "gun_attach_hint": "attach gun to hand_r (trigger grip), aim its forward axis at hand_l; right palm centre is ~7 cm along hand_r's +Y (bone axis)",
        "hand_r_axes_blender": {k: rifle["r"][k] for k in ("x_axis", "y_axis", "z_axis")},
        "hand_l_axes_blender": {k: rifle["l"][k] for k in ("x_axis", "y_axis", "z_axis")},
    },
    "notes": [],
}
with open(os.path.join(CFG.WORK, "manifest_partial.json"), "w") as f:
    json.dump(manifest, f, indent=1)
print("manifest partial written")
