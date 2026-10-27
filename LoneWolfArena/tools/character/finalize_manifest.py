"""Merge export info + validation into assets/character/manifest.json (pure python)."""
import os
import sys
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import char_config as CFG

m = json.load(open(os.path.join(CFG.WORK, "manifest_partial.json")))
v = json.load(open(os.path.join(CFG.WORK, "validation.json")))

# triangle counts as re-imported from the GLB
for mesh in m["meshes"]:
    if mesh["name"] in v["meshes"]:
        mesh["triangles"] = v["meshes"][mesh["name"]]["triangles"]
tri = {x["name"]: x["triangles"] for x in m["meshes"]}
base = sum(t for n, t in tri.items() if n.startswith("Body_") or n in ("Eyes", "Eyebrows", "Eyelashes", "Hair_Default"))
for b in m["bundles"]:
    b["outfit_triangles"] = sum(tri[n] for n in b["meshes"])
    b["total_triangles_with_full_body_hair"] = base + b["outfit_triangles"]
    b["visible_triangles_when_hide_applied"] = base + b["outfit_triangles"] - sum(tri.get(h, 0) for h in b["hide"])
m["triangles_body_head_hair_face"] = base
m["glb_size_mb"] = v["size_mb"]
m["textures"] = v["textures"]
m["validation"] = {"bone_count": v["bone_count"], "skins": v["skins"], "skin_joints": v["skin_joints"],
                   "animations_reimported_frame_ranges_at_30fps": v["animations"],
                   "gltf_animation_durations_s": {a["name"]: a["duration_s"] for a in v["gltf_animations"]},
                   "meshes_with_morph_targets": v["gltf_meshes_with_morphs"],
                   "materials": v["materials"]}
m["notes"] = [
    "Built with MPFB 2.0.18 (MakeHuman) inside Blender 5.0.1: male, age 25 (age macro 0.5), muscle 0.78, weight 0.54, "
    "proportions 0.9, race mix caucasian 0.5 / asian 0.3 / african 0.2 plus face/torso detail targets; height macro "
    "solved numerically for 1.78 m. Skin = MakeHuman young_caucasian_male texture graded to medium-brown.",
    "Rig = MPFB 'game_engine' (53 deform bones incl. fingers). MPFB names its root bone 'Root'; it was renamed to 'root'.",
    "Body was decimated from 26.8k to ~19.5k triangles with per-region budgets (head 6.9k, hands 3.9k, feet 1k), then split "
    "by dominant bone weight into 8 parts. Seam vertices are duplicated with identical skin weights and the unsplit body's "
    "normals are stored as custom normals, so the parts are watertight and seamless when all are shown.",
    "Body_Head uses its own 453x1024 crop of the 2048 source skin atlas (material M_Skin_Head) for a sharper face; the rest "
    "of the body uses M_Skin_Body (1024). A dark short-hair tone is painted on the scalp under the hair cards so the head "
    "still reads as short dark hair where Hair_Default is hidden.",
    "Hair_Default is hidden in DESERT FOX (cap) and SHADOW OPS (helmet) because the hair cards clip through the cap/helmet "
    "crown; the painted scalp shows as a short buzz under them.",
    "Body_Feet is hidden in every bundle (all have footwear; footwear soles were lifted 3-26 mm so they sit on Z=0). "
    "Bundle 'hide' lists only contain parts fully enclosed by that outfit (ray-cast coverage + MakeHuman delete groups + "
    "visual checks), so applying them never opens a hole; parts not listed may be partially covered and stay visible.",
    "Clothes: ROOKIE = elvs crude t-shirt (flat white), toigo wool pants cut 7.5 cm above the knee into charcoal shorts "
    "(no male shorts in the packs; MakeHuman jeans shorts are hot-pants), shoes05 white sneakers. DESERT FOX = namuhekam "
    "polo (khaki), cortu cargo pants (olive, subdivided once), toigo ankle boots (brown), toigo baseball cap re-coloured "
    "plain tan (original print removed). NEON STRIKER = male_casualsuit05 jacket+shirt+jeans re-coloured black jacket / "
    "cyan striped shirt / dark jeans, shoes05 with cyan accents, medical mouth mask re-coloured black with cyan edges and "
    "tightened to the face. SHADOW OPS = fisherman sweater (black), cargo pants (black), shoes03 boots (black), M1 helmet "
    "(dense camouflage-net shell removed, shell deepened, matte black), toigo short gloves (black). ROYAL GOLD = galactic "
    "warrior uniform re-coloured white with gold panels, shoes01 re-coloured gold (metallic 0.6).",
    "Layered garments were de-intersected in the rest pose (outer layers pushed outside inner layers / skin). Minor "
    "clipping can still appear at extreme joint angles (e.g. death pose hips, deep crouch).",
    "All animations are 30 fps, baked FK (rotation keys on all bones, location on pelvis; root never moves). Locomotion is "
    "in place: run cycles 0.7 s / stride 1.4 m (2.0 m/s at 1x), crouch_fwd 1.0 s / 1.0 m. death translates the pelvis "
    "~0.5 m backwards while falling (root stays at origin). Looping clips have last frame == first frame.",
    "Gameplay clips (idle, run_*, crouch_*, jump) keep both wrists at a fixed grip relative to spine_03 (rifle follows "
    "the chest). The gun is not in the file; previews show a placeholder rifle parented to hand_r.",
    "glTF/Godot axes: Blender (x, y, z) -> glTF (x, z, -y). The character faces +Z in Godot; *_godot rifle positions are "
    "already converted.",
    "All outfit materials are double-sided (glTF doubleSided) because garments contain legitimate inner faces "
    "(collars, hems, liners, cap brim); body/eyes are single-sided.",
    "Known minor artifact: the skin-tight ROOKIE t-shirt can show a few millimetre-sized specks of skin near its hem "
    "in some poses (garments were de-intersected against skin and inner layers in both directions, and tight tops "
    "use skin-transferred weights, but the tee is very close to the body).",
    "No twist bones in the game_engine rig: forearm roll is carried by the hand bone, so extreme wrist twists can pinch "
    "slightly at the wrist.",
]
out = os.path.join(CFG.OUT_DIR, "manifest.json")
with open(out, "w") as f:
    json.dump(m, f, indent=1)
print("wrote", out)
