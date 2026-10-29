"""Shared configuration for the hero character pipeline."""
import os

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
# MakeHuman / MPFB inputs (not in the repository): MH_ROOT, default ~/mh (see mpfb_boot.py).
MH_ROOT = os.environ.get("MH_ROOT", os.path.expanduser("~/mh"))
D = os.path.join(MH_ROOT, "mpfb_user_data")   # merged MPFB user data (symlinks into MH_ROOT/ext/packs/*)
OUT_DIR = os.path.join(ROOT, "assets", "character")
PREVIEW_DIR = os.path.join(ROOT, "tools", "character", "previews")   # outside res:// (git-ignored)
WORK = os.path.join(ROOT, "tools", "character", "work")   # intermediate .blend + processed textures (git-ignored)
TEX_DIR = os.path.join(WORK, "tex")

TARGET_HEIGHT = 1.78

# MakeHuman macro sliders (age 0.5 == 25 years)
MACRO = {
    "gender": 1.0, "age": 0.5, "muscle": 0.78, "weight": 0.54, "proportions": 0.9,
    "height": 0.45, "cupsize": 0.5, "firmness": 0.5,
    "race": {"asian": 0.30, "caucasian": 0.50, "african": 0.20},
}

# Extra MakeHuman detail targets (relative to MPFB data/targets), weight
EXTRA_TARGETS = [
    ("head/head-square", 0.35),
    ("chin/chin-width-incr", 0.30), ("chin/chin-prominent-incr", 0.25), ("chin/chin-bones-incr", 0.25),
    ("cheek/l-cheek-bones-incr", 0.25), ("cheek/r-cheek-bones-incr", 0.25),
    ("neck/measure-neck-circ-incr", 0.55),
    ("nose/nose-flaring-incr", 0.15), ("nose/nose-point-width-incr", 0.15), ("nose/nose-scale-vert-decr", 0.20),
    ("mouth/mouth-scale-horiz-incr", 0.15), ("mouth/mouth-lowerlip-volume-incr", 0.20),
    ("mouth/mouth-upperlip-volume-incr", 0.10),
    ("forehead/forehead-scale-vert-decr", 0.20),
    ("eyebrows/eyebrows-trans-down", 0.20),
    ("eyes/l-eye-scale-incr", 0.12), ("eyes/r-eye-scale-incr", 0.12),
    ("torso/torso-vshape-incr", 0.45), ("torso/torso-muscle-pectoral-incr", 0.25),
    ("torso/torso-muscle-dorsi-incr", 0.30), ("torso/measure-shoulder-dist-incr", 0.20),
    ("torso/measure-waist-circ-decr", 0.20),
]

SKIN_SRC = D + "/skins/young_caucasian_male/young_lightskinned_male_diffuse.png"

BODYPARTS = {
    "Eyes": D + "/eyes/high-poly/high-poly.mhclo",
    "Eyebrows": D + "/eyebrows/eyebrow009/eyebrow009.mhclo",
    "Eyelashes": D + "/eyelashes/eyelashes02/eyelashes02.mhclo",
    "Hair": D + "/hair/culturalibre_hair_02/culturalibre_hair_02.mhclo",
}
EYE_TEXTURE = D + "/eyes/materials/brown_eye.png"

C = D + "/clothes"
# bundle id -> display name, list of (Part, mhclo path)
BUNDLES = [
    ("default", "ROOKIE", [
        ("Top", C + "/elvs_crude_t-shirt_male/elvs_crude_t-shirt_male.mhclo"),
        ("Shorts", C + "/toigo_wool_pants/toigo_wool_pants.mhclo"),   # cut to knee length in stage B
        ("Shoes", C + "/shoes05/shoes05.mhclo"),
    ]),
    ("desert", "DESERT FOX", [
        ("Shirt", C + "/namuhekam_male_polo_shirt/namuhekam_male_polo_shirt.mhclo"),
        ("Pants", C + "/cortu_cargo_pants/cortu_cargo_pants.mhclo"),
        ("Boots", C + "/toigo_ankle_boots_male/toigo_ankle_boots_male.mhclo"),
        ("Cap", C + "/toigo_maga_hat/toigo_maga_hat.mhclo"),
    ]),
    ("neon", "NEON STRIKER", [
        ("Jacket", C + "/male_casualsuit05/male_casualsuit05.mhclo"),
        ("Shoes", C + "/shoes05/shoes05.mhclo"),
        ("Mask", C + "/joepal_medical_mouth_protection/joepal_medical_mouth_protection.mhclo"),
    ]),
    ("shadow", "SHADOW OPS", [
        ("Top", C + "/toigo_fisherman_sweater/toigo_fisherman_sweater.mhclo"),
        ("Pants", C + "/cortu_cargo_pants/cortu_cargo_pants.mhclo"),
        ("Boots", C + "/shoes03/shoes03.mhclo"),
        ("Helmet", C + "/mrgreaterthan_m1_helmet/mrgreaterthan_m1_helmet.mhclo"),
        ("Gloves", C + "/toigo_gloves_short/toigo_gloves_short.mhclo"),
    ]),
    ("royal", "ROYAL GOLD", [
        ("Suit", C + "/thegreatengineer_galactic_warrior_uniform/thegreatengineer_galactic_warrior_uniform.mhclo"),
        ("Shoes", C + "/shoes01/shoes01.mhclo"),
    ]),
]

BODY_PARTS = ["Body_Head", "Body_Torso", "Body_ArmsUpper", "Body_ArmsLower", "Body_Hands",
              "Body_LegsUpper", "Body_LegsLower", "Body_Feet"]

# dominant bone -> body part
BONE_TO_PART = {
    "head": "Body_Head", "neck_01": "Body_Head",
    "pelvis": "Body_Torso", "spine_01": "Body_Torso", "spine_02": "Body_Torso", "spine_03": "Body_Torso",
    "clavicle_l": "Body_Torso", "clavicle_r": "Body_Torso", "root": "Body_Torso", "Root": "Body_Torso",
    "upperarm_l": "Body_ArmsUpper", "upperarm_r": "Body_ArmsUpper",
    "lowerarm_l": "Body_ArmsLower", "lowerarm_r": "Body_ArmsLower",
    "thigh_l": "Body_LegsUpper", "thigh_r": "Body_LegsUpper",
    "calf_l": "Body_LegsLower", "calf_r": "Body_LegsLower",
    "foot_l": "Body_Feet", "foot_r": "Body_Feet", "ball_l": "Body_Feet", "ball_r": "Body_Feet",
}
# anything containing these goes to hands
HAND_BONE_PREFIXES = ("hand_", "thumb_", "index_", "middle_", "ring_", "pinky_")


def part_for_bone(name):
    if name in BONE_TO_PART:
        return BONE_TO_PART[name]
    if name.startswith(HAND_BONE_PREFIXES):
        return "Body_Hands"
    return "Body_Torso"


# Body parts / hair hidden per bundle (decided from coverage.json + visual checks: a part is
# hidden only when the outfit fully encloses it, so hiding never opens a visible hole).
BUNDLE_HIDE = {
    "default": ["Body_Feet"],
    "desert": ["Body_LegsUpper", "Body_LegsLower", "Body_Feet", "Hair_Default"],
    "neon": ["Body_ArmsUpper", "Body_ArmsLower", "Body_LegsUpper", "Body_LegsLower", "Body_Feet"],
    "shadow": ["Body_Torso", "Body_ArmsUpper", "Body_Hands", "Body_LegsUpper", "Body_LegsLower", "Body_Feet", "Hair_Default"],
    "royal": ["Body_Torso", "Body_ArmsUpper", "Body_ArmsLower", "Body_LegsUpper", "Body_LegsLower", "Body_Feet"],
}
