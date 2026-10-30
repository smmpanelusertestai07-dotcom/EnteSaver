"""Extra procedural animations for the hero character, exported to assets/character/anims_extra.glb
(armature + one small skinned mesh + the new actions only; the game merges the clips into the
character's AnimationPlayer at runtime, track paths "Armature/Skeleton3D:<bone>").

Actions (30 fps, in place, baked FK quaternions + pelvis location, same conventions as animate.py):
  reload, pump, heal (loop), throw, prone_idle (loop), prone_fwd (loop), swap, hit_react,
  fists_idle, fists_run_a, fists_run_b (static arm poses for the fists, see fists_pose),
  runx_fwd, runx_back, runx_left, runx_right (long-stride run cycles, loops)

Run headless:
  blender -b --python tools/character/anim_extra.py -- [--only reload,pump] [--out X.glb] [--no-export]
                                                       [--save X.blend]
The rig is taken from assets/character/character.glb (imported; stage_b.blend is not needed) and the
pose helpers come from animate.py (animate.setup())."""
import os
import sys
import math

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bpy
from mathutils import Matrix, Vector, Quaternion

import animlib as A
import animate as AN
from animlib import rot, lerp, smooth

FPS = 30
PROJECT = os.path.abspath(os.path.join(HERE, "..", ".."))
GLB_IN = os.path.join(PROJECT, "assets", "character", "character.glb")
GLB_OUT = os.path.join(PROJECT, "assets", "character", "anims_extra.glb")
X, Y, Z = (1, 0, 0), (0, 1, 0), (0, 0, 1)


# ============================================================================= scene / rig
def load_character(path=GLB_IN):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.context.scene.render.fps = FPS
    bpy.ops.import_scene.gltf(filepath=path)
    arm = bpy.data.objects["Armature"]
    AN.setup(arm)
    init_refs()
    return arm


# ============================================================================= small math helpers
def spline(keys, t):
    """Cubic Hermite through keys [(time, value[, stop])]; value: float / Vector / list.
    stop (default True) = zero velocity at that key (ease in/out like animate.interp_keys);
    stop=False = Catmull-Rom tangent (the motion passes through without stopping)."""
    vals = [k[1] for k in keys]
    vec = isinstance(vals[0], (list, tuple))
    if vec:
        vals = [Vector(v) if len(v) <= 4 else list(v) for v in vals]
    if isinstance(vals[0], list):            # long lists (finger curls): per component
        n = len(vals[0])
        return [spline([(k[0], v[i]) + tuple(k[2:]) for k, v in zip(keys, vals)], t) for i in range(n)]
    ts = [k[0] for k in keys]
    if t <= ts[0]:
        return vals[0].copy() if hasattr(vals[0], "copy") else vals[0]
    if t >= ts[-1]:
        return vals[-1].copy() if hasattr(vals[-1], "copy") else vals[-1]

    def tangent(i):
        stop = keys[i][2] if len(keys[i]) > 2 else True
        if stop or i == 0 or i == len(keys) - 1:
            return vals[i] * 0.0
        return (vals[i + 1] - vals[i - 1]) / (ts[i + 1] - ts[i - 1])
    for i in range(len(keys) - 1):
        if t <= ts[i + 1]:
            h = ts[i + 1] - ts[i]
            s = (t - ts[i]) / h
            h00 = 2 * s ** 3 - 3 * s ** 2 + 1
            h10 = s ** 3 - 2 * s ** 2 + s
            h01 = -2 * s ** 3 + 3 * s ** 2
            h11 = s ** 3 - s ** 2
            return vals[i] * h00 + tangent(i) * (h10 * h) + vals[i + 1] * h01 + tangent(i + 1) * (h11 * h)
    return vals[-1]


def qspline(keys, t):
    """Spline of rotations: keys [(time, Matrix3/Quaternion[, stop])] -> Matrix3 (hemisphere-aligned
    component Hermite, renormalised)."""
    qs = []
    for k in keys:
        q = k[1].to_quaternion() if hasattr(k[1], "to_quaternion") else Quaternion(k[1])
        if qs and qs[-1].dot(q) < 0:
            q.negate()
        qs.append(q)
    v = spline([(k[0], Vector(q[:])) + tuple(k[2:]) for k, q in zip(keys, qs)], t)
    return Quaternion(v).normalized().to_matrix()


def mat(R3, pos):
    M = R3.to_4x4() if R3 is not None else Matrix.Identity(4)
    M.translation = Vector(pos)
    return M


def hand_matrix(s, wrist, f, p):
    """World matrix of hand_<s> with its anatomical frame (f = wrist->middle knuckle, p = palm normal)."""
    f0, p0 = A.HAND0[s]
    Q = A.frame_fp(Vector(f), Vector(p)) @ A.frame_fp(f0, p0).transposed()
    return mat(Q @ A.REST["hand_" + s].to_3x3(), wrist)


def hand_axes(M, s):
    """Inverse of hand_matrix: (f, p) of a hand world matrix."""
    Q = M.to_3x3() @ A.REST["hand_" + s].to_3x3().inverted()
    f0, p0 = A.HAND0[s]
    return Q @ f0, Q @ p0


def blend_mats(Ma, Mb, w):
    qa, qb = Ma.to_quaternion(), Mb.to_quaternion()
    if qa.dot(qb) < 0:
        qb.negate()
    return mat(qa.slerp(qb, w).to_matrix(), Ma.translation.lerp(Mb.translation, w))


def lerp_curls(ca, cb, w):
    return {k: tuple(lerp(a, b, w) for a, b in zip(ca[k], cb[k])) for k in ca}


def copy_B(pose):
    return {k: v.copy() for k, v in pose.B.items()}


def pelvis_frame(pose):
    """Pelvis head position with the pelvis' rotation relative to rest (axes = body rest axes)."""
    D = pose.P["pelvis"].to_3x3() @ A.REST["pelvis"].to_3x3().inverted()
    return mat(D, pose.head("pelvis"))


def chest_frame(pose):
    """spine_03 world matrix relative to the neutral standing chest: C @ CHEST_REF^-1 maps
    'standing reference' world points to the current chest."""
    return pose.P["spine_03"] @ AN.CHEST_REF.inverted()


# ============================================================================= gun model
# The game puts the weapon origin (pistol-grip centre) 5.5 cm beyond the right wrist along the forearm
# and points it along the aim (character forward at idle).  Here the gun follows hand_r rigidly with its
# idle offset, so roll/dip of the right hand moves the gun.  Gun frame axes: X = gun right, Y = barrel
# (forward), Z = up; origin = grip centre (same as assets/props/weapon_*.glb in Blender coordinates).
GRIP_OFS = 0.055
AR_MAG = {"centre": Vector((0.0, 0.155, -0.06)), "axis": Vector((0.0, 0.16, -1.0)).normalized()}
REF = {}


def gun_frame_idle(pose):
    wrist, fore = pose.head("hand_r"), pose.head("lowerarm_r")
    grip = wrist + (wrist - fore).normalized() * GRIP_OFS
    return mat(Matrix(((-1, 0, 0), (0, -1, 0), (0, 0, 1))), grip)


def init_refs():
    idle0 = AN.pose_idle(0.0)
    G0 = gun_frame_idle(idle0)
    REF["idle0"] = idle0
    REF["G0"] = G0
    REF["HR_G"] = G0.inverted() @ idle0.P["hand_r"]      # right hand (trigger grip) in gun space
    REF["HL_G"] = G0.inverted() @ idle0.P["hand_l"]      # left hand (foregrip) in gun space


def rifle_targets(pose, sway=Matrix.Identity(3), offset=Vector((0, 0, 0))):
    """World matrices of both hands exactly as animate.rifle_arms() would place them (current chest)."""
    C = pose.P["spine_03"]
    C3 = C.to_3x3()
    CH = AN.CHEST
    piv = C @ ((CH["rh"] + CH["lh"]) * 0.5)
    rh = piv + sway @ (C @ CH["rh"] - piv) + offset
    lh = piv + sway @ (C @ CH["lh"] - piv) + offset
    HR = hand_matrix("r", rh, sway @ C3 @ CH["fr"], sway @ C3 @ CH["prn"])
    HL = hand_matrix("l", lh, sway @ C3 @ CH["fl"], sway @ C3 @ CH["pln"])
    return HR, HL


def rifle_poles(pose, offset=Vector((0, 0, 0))):
    C = pose.P["spine_03"]
    return C @ AN.CHEST["pr"] + offset, C @ AN.CHEST["pl"] + offset


def gun_from_right_hand(HR):
    return HR @ REF["HR_G"].inverted()


def arm_to(pose, s, M, pole, curls, thumb):
    pose.two_bone("upperarm_" + s, "lowerarm_" + s, M.translation, pole)
    pose.set_orient("hand_" + s, M.to_3x3())
    pose.fingers(s, curls, thumb=thumb)
    pose.fk()


GRIP_R, GRIP_L = AN.GRIP_R, AN.GRIP_L
THUMB_R, THUMB_L = (35, 25, 15), (30, 20, 12)
OPEN = {"index": (4, 6, 4), "middle": (6, 8, 5), "ring": (8, 10, 6), "pinky": (10, 12, 8)}
MAG_GRIP = {"index": (30, 40, 25), "middle": (55, 60, 35), "ring": (60, 62, 35), "pinky": (62, 64, 35)}
KIT_GRIP = {"index": (25, 30, 18), "middle": (30, 34, 20), "ring": (34, 36, 22), "pinky": (38, 40, 24)}
BALL_GRIP = {"index": (38, 45, 28), "middle": (45, 50, 30), "ring": (48, 52, 30), "pinky": (52, 55, 32)}


def curls_vec(c, th):
    return [v for k in ("index", "middle", "ring", "pinky") for v in c[k]] + list(th)


def vec_curls(v):
    c = {k: tuple(v[i * 3:i * 3 + 3]) for i, k in enumerate(("index", "middle", "ring", "pinky"))}
    return c, tuple(v[12:15])


# ============================================================================= idle-based upper body
def idle_body(pose, t, period=2.0, spine_add=None, neck_add=None, head_add=None, pelvis_add=None,
              pelvis_rot_add=None, feet=None, clav_add=(None, None)):
    """Idle stance (animate.pose_idle body without arms), plus optional extra rotations:
    spine_add: list of 3 Matrix3 multiplied after the idle spine deltas."""
    ph = 2 * math.pi * t / period
    breath = math.sin(ph)
    pr, sp, neck, head, cl, cr = AN.idle_upper_rots(breath=breath * 0.8)
    if pelvis_rot_add is not None:
        pr = pelvis_rot_add @ pr
    if spine_add is not None:
        sp = [a @ b for a, b in zip(sp, spine_add)]
    if neck_add is not None:
        neck = neck @ neck_add
    if head_add is not None:
        head = head @ head_add
    if clav_add[0] is not None:
        cl = clav_add[0] @ cl
    if clav_add[1] is not None:
        cr = clav_add[1] @ cr
    pos = AN.PELVIS_REST + Vector((0.0, 0.0, -AN.PELVIS_DROP_IDLE + 0.004 * math.sin(ph)))
    if pelvis_add is not None:
        pos = pos + Vector(pelvis_add)
    AN.set_upper(pose, pos, pr, sp, neck, head, cl, cr)
    AN.legs(pose, feet if feet is not None else AN.idle_feet())
    sway = rot(Z, 0.6 * math.sin(ph)) @ rot(X, 0.5 * math.cos(ph))
    return sway


# ============================================================================= reload (2.0 s)
RELOAD_T = 60 / FPS
PALM_F, PALM_P = 0.06, 0.028          # palm surface centre in the hand frame (measured on Body_Hands)


def wrist_for_palm(palm, f, p):
    return Vector(palm) - Vector(f).normalized() * PALM_F - Vector(p).normalized() * PALM_P


def gun_move(G, pitch=0.0, roll=0.0, yaw=0.0, ofs=(0, 0, 0), pivot=(0.0, -0.22, 0.06), bore=0.09):
    """Move the gun in its own frame: roll (top towards the gun's right +) about the bore line, pitch
    (muzzle up +) / yaw (muzzle to the gun's left +) about `pivot` (stock at the shoulder), then ofs."""
    Tp = Matrix.Translation(Vector(pivot))
    Tb = Matrix.Translation(Vector((0.0, 0.0, bore)))
    R1 = Tp @ (rot(Z, yaw) @ rot(X, pitch)).to_4x4() @ Tp.inverted()
    R2 = Tb @ rot(Y, roll).to_4x4() @ Tb.inverted()
    return G @ Matrix.Translation(Vector(ofs)) @ R1 @ R2


def mag_hand(s):
    """Left hand on the AR magazine (gun space), magazine pulled out of the well by s metres:
    palm on the magazine's front face, fingers wrapping its right side, thumb up on its left side."""
    a = AR_MAG["axis"]                                    # out of the well (down, slightly forward)
    fwd = (Vector((0, 1, 0)) - a * a.y).normalized()       # magazine front
    side = Vector((1, 0, 0))
    f = (side * 0.93 - a * 0.30 - fwd * 0.20).normalized()
    p = -fwd
    palm = AR_MAG["centre"] + a * (s + 0.005) + fwd * 0.05 - side * 0.035
    return hand_matrix("l", wrist_for_palm(palm, f, p), f, p)


def reload_pose(t):
    pose = A.Pose()
    # body: idle (+ its 2 s breathing, so frame 60 == frame 0) with a slight forward curl; the head
    # glances down at the magazine well
    curl = spline([(0.0, 0.0), (0.12, 0.0), (0.40, 1.0), (1.55, 1.0), (1.95, 0.0), (2.0, 0.0)], t)
    look = spline([(0.0, 0.0), (0.15, 0.0), (0.42, 1.0), (0.80, 0.8), (1.10, 0.7), (1.38, 1.0),
                   (1.58, 0.9), (1.90, 0.0), (2.0, 0.0)], t)
    sp_add = [rot(X, 1.0 * curl), rot(X, 1.5 * curl), rot(X, 2.5 * curl) @ rot(Z, -2.0 * curl)]
    sway = idle_body(pose, t, spine_add=sp_add, neck_add=rot(X, 13.0 * look) @ rot(Z, -2.0 * look),
                     head_add=rot(X, 17.0 * look) @ rot(Z, -5.0 * look))
    HR0, HL0 = rifle_targets(pose, sway)
    G = gun_from_right_hand(HR0)
    # gun: muzzle dips about the stock, rolls ~28 deg (top to the right: magwell towards the left hand),
    # small jolt when the new magazine is pushed home
    dip = spline([(0.0, 0.0), (0.06, 0.0), (0.38, 1.0), (1.36, 1.0), (1.86, 0.0), (2.0, 0.0)], t)
    roll = spline([(0.0, 0.0), (0.08, 0.0), (0.40, 28.0), (1.36, 28.0), (1.44, 24.0), (1.56, 27.0),
                   (1.90, 0.0), (2.0, 0.0)], t)
    jolt = spline([(0.0, 0.0), (1.38, 0.0), (1.45, 1.0), (1.58, 0.0), (2.0, 0.0)], t)
    G = gun_move(G, pitch=-13.0 * dip + 3.0 * jolt, roll=roll, yaw=3.0 * dip,
                 ofs=(0.0, 0.01 * dip, -0.02 * dip + 0.008 * jolt))
    HR = G @ REF["HR_G"]
    pr, pl = rifle_poles(pose)
    # right index presses the magazine release
    press = spline([(0.0, 0.0), (0.38, 0.0), (0.44, 1.0), (0.54, 1.0), (0.62, 0.0), (2.0, 0.0)], t)
    grip_r = dict(GRIP_R)
    grip_r["index"] = tuple(lerp(a, b, press) for a, b in zip(GRIP_R["index"], (30, 35, 20)))
    arm_to(pose, "r", HR, pr, grip_r, THUMB_R)
    # left hand: foregrip -> magazine -> pull out -> hip pouch -> new magazine -> insert -> foregrip
    Pf = pelvis_frame(pose)
    Cf = chest_frame(pose)
    fore = G @ REF["HL_G"]

    def on_mag(s):
        return G @ mag_hand(s)
    # hip pouch (pelvis space, left front of the belt): fingers down, palm against the pouch
    f_pouch, p_pouch = Vector((-0.15, -0.20, -1.0)), Vector((-1.0, 0.10, -0.10))
    pouch = Pf @ hand_matrix("l", wrist_for_palm((0.215, -0.085, 0.015), f_pouch, p_pouch), f_pouch, p_pouch)
    f_near, p_near = Vector((-0.20, -0.55, -0.80)), Vector((-0.90, 0.20, 0.10))
    near_pouch = Pf @ hand_matrix("l", wrist_for_palm((0.20, -0.17, 0.10), f_near, p_near), f_near, p_near)
    k = [
        (0.00, fore), (0.10, fore),
        (0.25, blend_mats(fore, on_mag(0.05), 0.6) @ Matrix.Translation((0.0, 0.0, -0.02)), False),
        (0.40, on_mag(0.0)), (0.50, on_mag(0.0)),
        (0.64, on_mag(0.13)),
        (0.73, blend_mats(on_mag(0.16), near_pouch, 0.45), False),
        (0.84, near_pouch, False),
        (0.96, pouch), (1.08, pouch),
        (1.18, near_pouch, False),
        (1.27, blend_mats(near_pouch, on_mag(0.13), 0.55), False),
        (1.37, on_mag(0.10)),
        (1.46, on_mag(-0.004)), (1.52, on_mag(0.0)),
        (1.64, blend_mats(on_mag(0.02), fore, 0.5) @ Matrix.Translation((0.0, 0.0, -0.02)), False),
        (1.80, fore), (2.00, fore),
    ]
    HL = mat(qspline([(kk[0], kk[1].to_3x3()) + tuple(kk[2:]) for kk in k], t),
             spline([(kk[0], kk[1].translation) + tuple(kk[2:]) for kk in k], t))
    pole_mag = Cf @ Vector((0.50, -0.20, 0.85))
    pole_pouch = Cf @ Vector((0.55, 0.35, 0.95))
    pole_l = spline([(0.0, pl), (0.10, pl), (0.40, pole_mag), (0.64, pole_mag), (0.96, pole_pouch),
                     (1.08, pole_pouch), (1.37, pole_mag), (1.52, pole_mag), (1.80, pl), (2.0, pl)], t)
    fv = spline([(0.0, curls_vec(GRIP_L, THUMB_L)), (0.10, curls_vec(GRIP_L, THUMB_L)),
                 (0.22, curls_vec(OPEN, (15, 10, 5))), (0.34, curls_vec(OPEN, (20, 10, 5))),
                 (0.44, curls_vec(MAG_GRIP, (35, 20, 10))), (0.91, curls_vec(MAG_GRIP, (35, 20, 10))),
                 (0.99, curls_vec(OPEN, (20, 10, 5))), (1.01, curls_vec(OPEN, (20, 10, 5))),
                 (1.10, curls_vec(MAG_GRIP, (35, 20, 10))), (1.52, curls_vec(MAG_GRIP, (35, 20, 10))),
                 (1.60, curls_vec(OPEN, (20, 12, 6))), (1.76, curls_vec(GRIP_L, THUMB_L)),
                 (2.0, curls_vec(GRIP_L, THUMB_L))], t)
    cl, th = vec_curls(fv)
    arm_to(pose, "l", HL, pole_l, cl, th)
    pose.gun = G
    return pose


# ============================================================================= pump (0.45 s)
PUMP_T = 14 / FPS


def pump_pose(t):
    """Shotgun pump: the left hand racks the fore-end ~10 cm back along the gun axis and forward again."""
    pose = A.Pose()
    sway = idle_body(pose, 0.0)
    HR0, HL0 = rifle_targets(pose, sway)
    G = gun_from_right_hand(HR0)
    pr, pl = rifle_poles(pose)
    arm_to(pose, "r", HR0, pr, GRIP_R, THUMB_R)
    back = spline([(0.0, 0.0), (0.04, 0.0), (0.16, 1.0), (0.21, 1.0), (0.35, -0.03), (0.42, 0.0), (PUMP_T, 0.0)], t)
    HL = G @ Matrix.Translation(Vector((0.0, -0.10 * back, 0.0))) @ REF["HL_G"]
    arm_to(pose, "l", HL, pl, GRIP_L, THUMB_L)
    pose.gun = G
    return pose


# ============================================================================= heal (1.2 s loop)
HEAL_T = 36 / FPS


def heal_gun(pose):
    """Gun lowered one-handed at the right hip, muzzle down-forward (top of the gun facing forward)."""
    Pf = pelvis_frame(pose)
    grip = Pf @ Vector((-0.235, -0.115, -0.05))
    b = (Pf.to_3x3() @ Vector((-0.10, -0.62, -0.78))).normalized()       # barrel
    u = Pf.to_3x3() @ Vector((0.0, -1.0, 0.25))
    u = (u - b * u.dot(b)).normalized()
    xg = b.cross(u)
    return mat(Matrix((xg, b, u)).transposed(), grip)


def heal_pose(t):
    ph = 2 * math.pi * t / HEAL_T
    press = 0.5 - 0.5 * math.cos(2 * ph)               # two gentle presses per loop
    pose = A.Pose()
    sp_add = [rot(Z, 3.0) @ rot(X, 0.5), rot(Z, 3.0) @ rot(X, 1.0 + 0.5 * press), rot(Z, 3.0) @ rot(X, 1.5 + 0.6 * press)]
    idle_body(pose, t, period=HEAL_T, spine_add=sp_add, neck_add=rot(X, 15.0) @ rot(Z, -6.0),
              head_add=rot(X, 22.0 + 2.0 * press) @ rot(Z, -10.0),
              clav_add=(rot(X, 2.0), rot(X, 3.0)))
    Cf = chest_frame(pose)
    G = heal_gun(pose)
    HR = G @ REF["HR_G"]
    arm_to(pose, "r", HR, Cf @ Vector((-0.55, 0.45, 1.05)), GRIP_R, THUMB_R)
    # left hand: palm against the kit, pressing it to the belly
    f = Cf.to_3x3() @ Vector((-0.85, -0.05, -0.50))
    p = Cf.to_3x3() @ Vector((0.05, 1.0, 0.25))
    palm = Cf @ Vector((0.02, -0.215 + 0.022 * press, 1.12 - 0.006 * press))
    HL = hand_matrix("l", wrist_for_palm(palm, f, p), f, p)
    arm_to(pose, "l", HL, Cf @ Vector((0.55, 0.20, 0.85)), KIT_GRIP, (25, 15, 8))
    pose.gun = G
    return pose


# ============================================================================= throw (0.9 s)
THROW_T = 27 / FPS
THROW_RELEASE = 13 / FPS          # grenade leaves the hand (s)


IDLE_SWAY0 = rot(X, 0.5)          # animate.pose_idle(0) rifle sway (keeps frame 0 == idle frame 0)


def throw_pose(t):
    """Overhand grenade throw with the right hand (the game hides the gun): wind-up with the torso
    twisted right and the left arm pointing at the target, release forward-high at THROW_RELEASE,
    follow-through down across the body, back to the idle rifle pose.  Hand targets are given relative
    to the shoulders in character axes (they must not rotate with the big torso twist)."""
    kt = [0.0, 0.15, 0.30, THROW_RELEASE, 0.56, 0.74, 0.90]
    st = [True, False, True, False, True, False, True]

    def K(vals):
        return spline([(a, b, c) for a, b, c in zip(kt, vals, st)], t)
    pyaw = K([0.0, -6.0, -14.0, 16.0, 22.0, 8.0, 0.0])          # added to the idle pelvis yaw (-14)
    ppitch = K([0.0, -1.5, -4.0, 6.0, 10.0, 3.0, 0.0])
    pdx = K([0.0, -0.01, -0.02, 0.0, 0.01, 0.005, 0.0])
    pdy = K([0.0, 0.02, 0.04, -0.035, -0.05, -0.02, 0.0])
    pdz = K([0.0, -0.006, -0.012, -0.02, -0.028, -0.012, 0.0])
    syaw = K([0.0, -3.0, -6.0, 4.0, 6.0, 2.0, 0.0])             # per spine bone (added)
    spitch = K([0.0, -0.5, -1.5, 3.0, 5.0, 1.5, 0.0])
    sroll = K([0.0, 1.0, 2.5, -1.5, -2.5, -0.5, 0.0])
    pose = A.Pose()
    pr, sp, neck, head, cl, cr = AN.idle_upper_rots()
    pr = rot(Z, pyaw) @ pr @ rot(X, ppitch)
    sp = [rot(Z, syaw) @ rot(Y, sroll) @ rot(X, spitch) @ q for q in sp]
    hy = -(pyaw + 3 * syaw)                                     # head keeps facing the target
    neck = rot(Z, 0.4 * hy) @ neck @ rot(X, -0.25 * spitch)
    head = rot(Z, 0.6 * hy) @ head @ rot(X, -0.5 * spitch - 0.4 * ppitch)
    cr = cr @ rot(Y, K([0.0, 4.0, 8.0, -2.0, -6.0, -2.0, 0.0])) @ rot(X, K([0.0, -3.0, -6.0, 3.0, 6.0, 2.0, 0.0]))
    pos = AN.PELVIS_REST + Vector((pdx, pdy, -AN.PELVIS_DROP_IDLE + pdz))
    lift = K([0.0, 0.0, 0.0, 0.35, 1.0, 0.35, 0.0])            # right heel lifts in the follow-through
    feet = AN.idle_feet()
    a_r, p_r, y_r = AN.IDLE_FEET["r"]
    feet["r"] = AN.foot_at("r", p_r, y_r + 16.0 * lift, -26.0 * lift, toe=26.0 * lift)
    AN.set_upper(pose, pos, pr, sp, neck, head, cl, cr)
    AN.legs(pose, feet)
    HR0, HL0 = rifle_targets(pose, IDLE_SWAY0)
    prr, pll = rifle_poles(pose)
    sh_r, sh_l = pose.head("upperarm_r"), pose.head("upperarm_l")
    V = Vector
    # ---- right arm: (wrist offset from the shoulder, f, palm normal, pole offset) per key
    R = [None,
         (V((-0.10, -0.12, 0.16)), V((-0.25, -0.25, 1.0)), V((0.25, -1.0, 0.1)), V((-0.65, 0.05, -0.30))),
         (V((-0.13, 0.13, 0.25)), V((-0.10, 0.35, 0.93)), V((0.15, -0.93, 0.30)), V((-0.65, 0.20, -0.10))),
         (V((0.03, -0.40, 0.30)), V((0.05, -0.75, 0.66)), V((0.0, -0.66, -0.75)), V((-0.45, 0.10, -0.50))),
         (V((0.26, -0.24, -0.36)), V((0.40, -0.40, -0.82)), V((0.30, 0.85, -0.40)), V((-0.55, 0.35, -0.10))),
         (V((0.18, -0.30, -0.24)), V((0.45, -0.85, -0.25)), V((0.55, 0.35, 0.75)), V((-0.60, 0.25, -0.30))),
         None]
    keys_r = []
    for i, tk in enumerate(kt):
        if R[i] is None:
            keys_r.append((tk, HR0, prr, st[i]))
        else:
            w, f, pn, pol = R[i]
            keys_r.append((tk, hand_matrix("r", sh_r + w, f, pn), sh_r + pol, st[i]))
    HR = mat(qspline([(k[0], k[1].to_3x3(), k[3]) for k in keys_r], t),
             spline([(k[0], k[1].translation, k[3]) for k in keys_r], t))
    pole_r = spline([(k[0], k[2]) for k in keys_r], t)
    fvr = spline([(0.0, curls_vec(GRIP_R, THUMB_R)), (0.12, curls_vec(BALL_GRIP, (40, 30, 20))),
                  (THROW_RELEASE - 0.02, curls_vec(BALL_GRIP, (40, 30, 20))),
                  (THROW_RELEASE + 0.05, curls_vec(OPEN, (10, 5, 0))), (0.62, curls_vec(AN.RELAX, (10, 8, 5))),
                  (0.82, curls_vec(GRIP_R, THUMB_R)), (0.90, curls_vec(GRIP_R, THUMB_R))], t)
    c_r, th_r = vec_curls(fvr)
    arm_to(pose, "r", HR, pole_r, c_r, th_r)
    # ---- left arm: points at the target during the wind-up, pulls down/in on the throw
    L = [None,
         (V((-0.04, -0.36, 0.0)), V((-0.25, -1.0, 0.10)), V((-0.60, 0.0, 0.80)), V((0.40, 0.05, -0.55))),
         (V((-0.06, -0.45, 0.08)), V((-0.10, -1.0, 0.12)), V((-0.85, 0.05, 0.50)), V((0.35, 0.0, -0.60))),
         (V((0.07, -0.10, -0.29)), V((-0.10, -0.60, -0.80)), V((-0.90, 0.25, 0.20)), V((0.45, 0.35, -0.20))),
         (V((0.07, 0.04, -0.36)), V((0.0, -0.35, -0.95)), V((-0.95, 0.15, 0.15)), V((0.45, 0.40, -0.10))),
         (V((-0.02, -0.18, -0.30)), V((-0.35, -0.85, -0.30)), V((-0.60, 0.10, 0.80)), V((0.50, 0.15, -0.40))),
         None]
    keys_l = []
    for i, tk in enumerate(kt):
        if L[i] is None:
            keys_l.append((tk, HL0, pll, st[i]))
        else:
            w, f, pn, pol = L[i]
            keys_l.append((tk, hand_matrix("l", sh_l + w, f, pn), sh_l + pol, st[i]))
    HL = mat(qspline([(k[0], k[1].to_3x3(), k[3]) for k in keys_l], t),
             spline([(k[0], k[1].translation, k[3]) for k in keys_l], t))
    pole_l = spline([(k[0], k[2]) for k in keys_l], t)
    fvl = spline([(0.0, curls_vec(GRIP_L, THUMB_L)), (0.14, curls_vec(OPEN, (10, 5, 0))),
                  (0.40, curls_vec(OPEN, (10, 5, 0))), (0.56, curls_vec(AN.RELAX, (10, 8, 5))),
                  (0.80, curls_vec(GRIP_L, THUMB_L)), (0.90, curls_vec(GRIP_L, THUMB_L))], t)
    c_l, th_l = vec_curls(fvl)
    arm_to(pose, "l", HL, pole_l, c_l, th_l)
    pose.gun = None
    return pose


# ============================================================================= swap (0.5 s)
SWAP_T = 15 / FPS
SWAP_LOW = 0.25


def swap_pose(t):
    """Weapon swap: gun lowered (muzzle down, rolled in) and raised again; lowest at SWAP_LOW."""
    pose = A.Pose()
    low = spline([(0.0, 0.0), (SWAP_LOW, 1.0), (0.5, 0.0)], t)
    sway = idle_body(pose, 0.0, spine_add=[rot(X, 1.0 * low), rot(X, 1.0 * low), rot(X, 2.0 * low)],
                     neck_add=rot(X, 5.0 * low), head_add=rot(X, 6.0 * low))
    HR0, HL0 = rifle_targets(pose, sway)
    G = gun_move(gun_from_right_hand(HR0), pitch=-38.0 * low, roll=14.0 * low, yaw=6.0 * low,
                 ofs=(0.0, 0.03 * low, -0.07 * low))
    pr, pl = rifle_poles(pose)
    arm_to(pose, "r", G @ REF["HR_G"], pr, GRIP_R, THUMB_R)
    arm_to(pose, "l", G @ REF["HL_G"], pl, GRIP_L, THUMB_L)
    pose.gun = G
    return pose


# ============================================================================= hit_react (0.35 s)
HIT_T = 10 / FPS


def hit_pose(t):
    """Small flinch of the upper body (hit from the front), back to idle."""
    k = spline([(0.0, 0.0), (0.06, 1.0), (0.15, 0.45, False), (0.25, -0.07), (HIT_T, 0.0)], t)
    pose = A.Pose()
    sway = idle_body(pose, 0.0, spine_add=[rot(X, -2.5 * k) @ rot(Z, 2.0 * k), rot(X, -3.0 * k) @ rot(Z, 2.0 * k),
                                           rot(X, -4.0 * k) @ rot(Z, 3.0 * k) @ rot(Y, -2.0 * k)],
                     neck_add=rot(X, -5.0 * k), head_add=rot(X, -9.0 * k) @ rot(Z, 6.0 * k) @ rot(Y, 4.0 * k),
                     pelvis_add=(0.0, 0.012 * k, -0.015 * k),
                     clav_add=(rot(X, -4.0 * k), rot(X, -4.0 * k)))
    sway = sway @ rot(X, 4.0 * k)
    HR0, HL0 = rifle_targets(pose, sway)
    pr, pl = rifle_poles(pose)
    arm_to(pose, "r", HR0, pr, GRIP_R, THUMB_R)
    arm_to(pose, "l", HL0, pl, GRIP_L, THUMB_L)
    pose.gun = gun_from_right_hand(HR0)
    return pose


# ============================================================================= prone
PRONE = dict(
    pelvis=(0.0, 0.26, 0.16), pitch=84.0, yaw=-16.0, roll=0.0,
    spine_ext=(6.0, 6.0, 3.0), spine_yaw=(-1.5, -1.5, -2.0), spine_roll=(0.0, 0.0, 0.0),
    neck=(-24.0, 7.0), head=(-28.0, 9.0), head_roll=7.0,   # (pitch, yaw): negative pitch = extension (look up)
    clav_l=(-14.0, 6.0), clav_r=(14.0, 6.0),        # (yaw = protraction, pitch)
    grip=(-0.24, -0.46, 0.165), gun_yaw=0.0, gun_pitch=0.0, gun_roll=0.0, left_back=0.10,
    elbow_h=0.037, pole_r=(-1.0, 0.3, 0.0), pole_l=(-0.4, 0.0, -1.0),
    leg_len=0.88, ankle_z=0.155, ankle_l=(0.20, 0.0, 0.0), ankle_r=(-0.20, 0.0, 0.0),
    foot_tilt=24.0, foot_yaw=10.0, toe=62.0,
)


def prone_body(pose, P, breath=0.0):
    pz = Vector(P["pelvis"]) + Vector((0, 0, 0.002 * breath))
    prot = rot(Z, P["yaw"]) @ rot(Y, P["roll"]) @ rot(X, P["pitch"])
    pose.set_pelvis(pz, prot)
    for n, e, yw, rl in zip(("spine_01", "spine_02", "spine_03"), P["spine_ext"], P["spine_yaw"], P["spine_roll"]):
        pose.set_delta(n, rot(Z, yw) @ rot(Y, rl) @ rot(X, -e - 0.35 * breath))
    pose.set_delta("neck_01", rot(Z, P["neck"][1]) @ rot(X, P["neck"][0] + 0.3 * breath))
    pose.set_delta("head", rot(Z, P["head"][1]) @ rot(Y, P.get("head_roll", 0.0)) @ rot(X, P["head"][0] + 0.3 * breath))
    pose.set_delta("clavicle_l", rot(Z, P["clav_l"][0]) @ rot(X, P["clav_l"][1]))
    pose.set_delta("clavicle_r", rot(Z, P["clav_r"][0]) @ rot(X, P["clav_r"][1]))
    pose.fk()


def prone_gun(P, ofs=(0, 0, 0), yaw=0.0, roll=0.0, pitch=0.0):
    R = rot(Z, P["gun_yaw"] + yaw) @ rot(Matrix(((-1, 0, 0), (0, -1, 0), (0, 0, 1))) @ Vector((1, 0, 0)), 0.0)
    G = mat(Matrix(((-1, 0, 0), (0, -1, 0), (0, 0, 1))), Vector(P["grip"]) + Vector(ofs))
    G = G @ rot(Z, P["gun_yaw"] + yaw).to_4x4() @ rot(X, P["gun_pitch"] + pitch).to_4x4() @ rot(Y, P["gun_roll"] + roll).to_4x4()
    return G


def elbow_at_height(s, S, W, h, prefer):
    """Point of the elbow circle (shoulder S, wrist W) at height h, on the side of `prefer`
    (lowest point of the circle if h is out of reach). Returns the elbow position (usable as IK pole)."""
    L1, L2 = A.LEN["upperarm_" + s], A.LEN["lowerarm_" + s]
    d = W - S
    D = min(d.length, (L1 + L2) * 0.9995)
    dn = d.normalized()
    a = (L1 * L1 - L2 * L2 + D * D) / (2 * D)
    r = math.sqrt(max(1e-8, L1 * L1 - a * a))
    C = S + dn * a
    u = Vector((0, 0, -1)) - dn * (-dn.z)
    if u.length < 1e-6:
        u = Vector((1, 0, 0)) - dn * dn.x
    u.normalize()
    v = dn.cross(u).normalized()
    Az, Bz = r * u.z, r * v.z
    R = math.hypot(Az, Bz)
    phi = math.atan2(Bz, Az)
    c = (h - C.z) / R if R > 1e-9 else -2.0
    if c <= -1.0 or c >= 1.0:
        th = [phi + math.pi] if c <= -1.0 else [phi]
    else:
        th = [phi + math.acos(c), phi - math.acos(c)]
    pts = [C + (u * math.cos(x) + v * math.sin(x)) * r for x in th]
    pts.sort(key=lambda e: -(e - C).normalized().dot(Vector(prefer).normalized()))
    return pts[0]


def arm_to_ground(pose, s, M, pole, curls, thumb, h_min):
    """arm_to(), but if the elbow would sink below h_min it is lifted onto h_min along its IK circle
    (same side as the unconstrained solution, so the motion stays continuous)."""
    arm_to(pose, s, M, pole, curls, thumb)
    E = pose.head("lowerarm_" + s)
    if E.z < h_min:
        S = pose.head("upperarm_" + s)
        W = M.translation
        mid = (S + W) * 0.5
        E2 = elbow_at_height(s, S, W, h_min, E - mid)
        arm_to(pose, s, M, E2, curls, thumb)


def prone_arms(pose, P, G, elbow_l=None, elbow_r=None, left_back=None):
    """Hands on the gun (right trigger grip, left hand on the handguard `left_back` m behind the idle
    foregrip); each elbow on its IK circle at height P['elbow_h'] (resting on the ground)."""
    lb = P["left_back"] if left_back is None else left_back
    HR = G @ REF["HR_G"]
    HL = G @ Matrix.Translation(Vector((0.0, -lb, 0.0))) @ REF["HL_G"]
    sr, sl = pose.head("upperarm_r"), pose.head("upperarm_l")
    pr = elbow_at_height("r", sr, HR.translation, P["elbow_h"], P["pole_r"]) if elbow_r is None else elbow_r
    pl = elbow_at_height("l", sl, HL.translation, P["elbow_h"], P["pole_l"]) if elbow_l is None else elbow_l
    arm_to(pose, "r", HR, pr, GRIP_R, THUMB_R)
    arm_to(pose, "l", HL, pl, GRIP_L, THUMB_L)


def prone_foot(s, ankle, P, tilt=None, yaw=None, toe=None):
    """Toes tucked: foot roughly vertical (sole facing back), ball on the ground, toes bent forward."""
    side = 1.0 if s == "l" else -1.0
    tilt = P["foot_tilt"] if tilt is None else tilt
    yaw = P["foot_yaw"] if yaw is None else yaw
    toe = P["toe"] if toe is None else toe
    Q = rot(Z, side * yaw) @ rot(X, 90.0 - tilt)
    return (Vector(ankle), Q, toe)


def prone_legs(pose, P, feet, knee_poles=None):
    for s in ("l", "r"):
        ankle, Q, toe = feet[s]
        side = 1.0 if s == "l" else -1.0
        hip = pose.head("thigh_" + s)
        kp = (hip + ankle) * 0.5 + Vector((side * 0.10, 0.0, -1.0)) if knee_poles is None else knee_poles[s]
        pose.two_bone("thigh_" + s, "calf_" + s, ankle, kp)
        pose.foot_orient(s, Q)
        pose.set_delta("ball_" + s, rot(X, -toe))
        pose.fk()


def prone_idle_feet(pose, P):
    feet = {}
    for s in ("l", "r"):
        side = 1.0 if s == "l" else -1.0
        hip = pose.head("thigh_" + s)
        a = Vector(P["ankle_" + s])
        ankle = Vector((hip.x + a.x * 0.0 + side * abs(a.x) * 0.0, 0, 0))
        ankle = Vector((side * abs(a.x), hip.y + math.sqrt(max(0.0, P["leg_len"] ** 2 - (side * abs(a.x) - hip.x) ** 2
                                                              - (P["ankle_z"] - hip.z) ** 2)), P["ankle_z"]))
        feet[s] = prone_foot(s, ankle, P)
    return feet


PRONE_IDLE_T = 60 / FPS


def prone_idle_pose(t, P=None):
    P = PRONE if P is None else P
    breath = math.sin(2 * math.pi * t / PRONE_IDLE_T)
    pose = A.Pose()
    prone_body(pose, P, breath)
    G = prone_gun(P, ofs=(0.0, 0.0, 0.002 * breath), pitch=0.3 * breath)
    prone_arms(pose, P, G)
    prone_legs(pose, P, prone_idle_feet(pose, P))
    pose.gun = G
    return pose


PRONE_FWD_T = 36 / FPS
CRAWL = dict(swing=0.36, elbow_lift=0.06, gun_fwd=0.07, gun_yaw=6.0, gun_lift=0.015, pelvis_roll=6.0,
             pelvis_yaw=5.0, chest_yaw=5.0, clav=16.0, speed=0.30)


def _cycle(ph, start, swing):
    """(swinging, u): u = progress in the swing window [start, start+swing) or in the stance window."""
    x = (ph - start) % 1.0
    if x < swing:
        return True, x / swing
    return False, (x - swing) / (1.0 - swing)


def _reach(ph, start, swing):
    """0..1 'forward' amount of a limb: rises (eased) during its swing, falls linearly during stance."""
    sw, u = _cycle(ph, start, swing)
    return smooth(u) if sw else 1.0 - u


def _lift(ph, start, swing):
    sw, u = _cycle(ph, start, swing)
    return math.sin(math.pi * u) if sw else 0.0


def drawn_leg(pose, s, P, k):
    """Leg drawn up to the side by k (0 = extended prone leg with toes tucked, 1 = knee drawn up and out,
    shin flat behind it).  The knee travels around the hip at ground level (exact IK: knee = pole)."""
    side = 1.0 if s == "l" else -1.0
    L1, L2 = A.LEN["thigh_" + s], A.LEN["calf_" + s]
    hip = pose.head("thigh_" + s)
    ext_ankle, ext_Q, ext_toe = prone_idle_feet(pose, P)[s]
    # extended knee on the IK circle (lowest point), as prone_legs() does
    kp = (hip + ext_ankle) * 0.5 + Vector((side * 0.10, 0.0, -1.0))
    probe = A.Pose()
    probe.B = {n: m.copy() for n, m in pose.B.items()}
    probe.fk()
    probe.two_bone("thigh_" + s, "calf_" + s, ext_ankle, kp)
    K0 = probe.head("calf_" + s)
    d0 = (ext_ankle - K0).normalized()
    a0 = math.atan2(side * (K0.x - hip.x), K0.y - hip.y)
    z0 = K0.z
    a1, z1 = math.radians(58.0), 0.062
    d1 = Vector((side * 0.06, 1.0, 0.11)).normalized()
    u = smooth(k)
    a = lerp(a0, a1, u)
    zk = lerp(z0, z1, u) + 0.012 * math.sin(math.pi * u)
    rh = math.sqrt(max(1e-6, L1 * L1 - (hip.z - zk) ** 2))
    K = Vector((hip.x + side * rh * math.sin(a), hip.y + rh * math.cos(a), zk))
    q0 = Vector((0, 1, 0)).rotation_difference(d0)
    q1 = Vector((0, 1, 0)).rotation_difference(d1)
    d = q0.slerp(q1, u) @ Vector((0, 1, 0))
    d = (d + Vector((0, 0, 0.16 * math.sin(math.pi * u)))).normalized()      # lift the foot mid-way
    ankle = K + d * L2
    pose.two_bone("thigh_" + s, "calf_" + s, ankle, K + (K - (hip + ankle) * 0.5) * 0.5)
    # foot: blend from toes-tucked (world) to a relaxed foot lying on its inner edge, following the shin
    Qa = ext_Q @ A.REST["foot_" + s].to_3x3()
    pose.set_delta("foot_" + s, rot(X, 38.0) @ rot(Y, side * 20.0))
    pose.fk()
    Qb = pose.P["foot_" + s].to_3x3()
    qa, qb = Qa.to_quaternion(), Qb.to_quaternion()
    if qa.dot(qb) < 0:
        qb.negate()
    pose.set_orient("foot_" + s, qa.slerp(qb, u).to_matrix())
    pose.set_delta("ball_" + s, rot(X, -lerp(ext_toe, 5.0, u)))
    pose.fk()


def prone_fwd_pose(t):
    """Elbow/knee crawl in place (contralateral: left elbow reaches while the right knee draws up, then the
    other pair).  The pushing knees slide back at ~CRAWL['speed'] m/s (crawl speed at 1x playback)."""
    P = dict(PRONE)
    C = CRAWL
    ph = (t / PRONE_FWD_T) % 1.0
    sw = C["swing"]
    rl, rr = _reach(ph, 0.0, sw), _reach(ph, 0.5, sw)           # elbow reach amounts
    kl, kr = _lift(ph, 0.5, sw), _lift(ph, 0.0, sw)             # knee draw (swing) amounts
    kl = max(kl, 0.0)
    # knees stay drawn a little into the push, then extend: use a reach-like curve
    dl, dr = _reach(ph, 0.5, sw), _reach(ph, 0.0, sw)
    side_bal = dr - dl                                           # +1: right knee drawn up
    P["pelvis"] = tuple(Vector(P["pelvis"]) + Vector((0.0, 0.0, 0.008 * abs(side_bal))))
    P["roll"] = P["roll"] + C["pelvis_roll"] * side_bal
    P["yaw"] = P["yaw"] + C["pelvis_yaw"] * side_bal
    cy = -C["chest_yaw"] * (rl - rr) - 0.6 * C["pelvis_yaw"] * side_bal
    P["spine_yaw"] = tuple(a + cy / 3.0 for a in P["spine_yaw"])
    P["spine_roll"] = tuple(a - 0.5 * C["pelvis_roll"] * side_bal / 3.0 for a in P["spine_roll"])
    P["clav_l"] = (P["clav_l"][0] - C["clav"] * (rl - 0.5), P["clav_l"][1])
    P["clav_r"] = (P["clav_r"][0] + C["clav"] * (rr - 0.5), P["clav_r"][1])
    P["neck"] = (P["neck"][0], P["neck"][1] - 0.5 * cy)
    pose = A.Pose()
    prone_body(pose, P)
    G = prone_gun(P, ofs=(0.0, -C["gun_fwd"] * (rl + rr - 1.0), C["gun_lift"] * (_lift(ph, 0.0, sw) + _lift(ph, 0.5, sw))),
                  yaw=C["gun_yaw"] * (rr - rl))
    # elbows: aimed at the prone_idle elbow offset from the shoulder (planted), the reaching one lifted and
    # pushed forward; used as IK poles so the solution stays continuous
    HR = G @ REF["HR_G"]
    HL = G @ Matrix.Translation(Vector((0.0, -P["left_back"], 0.0))) @ REF["HL_G"]
    sr, sl = pose.head("upperarm_r"), pose.head("upperarm_l")
    if "elbow_ofs" not in REF:
        p0 = prone_idle_pose(0.0)
        REF["elbow_ofs"] = {k: p0.head("lowerarm_" + k) - p0.head("upperarm_" + k) for k in "lr"}
    er = sr + REF["elbow_ofs"]["r"] + Vector((0.0, -0.05 * rr, C["elbow_lift"] * _lift(ph, 0.5, sw)))
    el = sl + REF["elbow_ofs"]["l"] + Vector((0.0, -0.05 * rl, C["elbow_lift"] * _lift(ph, 0.0, sw)))
    arm_to_ground(pose, "r", HR, er, GRIP_R, THUMB_R, PRONE["elbow_h"])
    arm_to_ground(pose, "l", HL, el, GRIP_L, THUMB_L, PRONE["elbow_h"])
    drawn_leg(pose, "l", P, dl)
    drawn_leg(pose, "r", P, dr)
    pose.gun = G
    return pose


# ============================================================================= fists (unarmed)
# With the fists out the guns go on the back and the arms move like a runner's. Static arm poses;
# the game filters them to the arm and finger bones (torso and legs come from the idle / run
# cycles) and blends fists_run_a <-> fists_run_b with the stride, so the fists swing against the
# legs (a: left fist forward, right fist back; b: the mirror), or fists_idle at rest.
FIST = {"index": (80, 95, 55), "middle": (85, 95, 55), "ring": (88, 95, 55), "pinky": (90, 95, 55)}
FIST_THUMB = (45, 35, 30)
FWD, RIGHT, UP = Vector((0, -1, 0)), Vector((-1, 0, 0)), Vector((0, 0, 1))      # character frame


def fist_arm(pose, s, swing, rest=False):
    """Arm with a closed fist. swing +1: fist forward at the lower chest with the elbow bent about
    90 degrees; -1: fist back beside the hip; rest: hanging relaxed beside the thigh."""
    side = RIGHT if s == "r" else -RIGHT
    S = pose.head("upperarm_" + s)
    if rest:
        wrist = S + FWD * 0.07 + side * 0.07 - UP * 0.5
        pole = S - FWD * 0.15 + side * 0.25 - UP * 0.25
    else:
        u = (swing + 1.0) * 0.5                     # 0 = back, 1 = forward
        wrist = S + FWD * lerp(-0.2, 0.26, u) + side * lerp(0.08, -0.06, u) - UP * lerp(0.42, 0.26, u)
        pole = S - FWD * 0.35 + side * 0.15 - UP * 0.3
    pose.two_bone("upperarm_" + s, "lowerarm_" + s, wrist, pole)
    f = (wrist - pose.head("lowerarm_" + s)).normalized()
    p = (-side - f * (-side).dot(f)).normalized()     # palm toward the body
    pose.set_orient("hand_" + s, hand_matrix(s, wrist, f, p).to_3x3())
    pose.fingers(s, FIST, thumb=FIST_THUMB)
    pose.fk()


def fists_pose(swing, rest=False):
    pose = A.Pose()
    idle_body(pose, 0.0)
    fist_arm(pose, "l", swing, rest)
    fist_arm(pose, "r", -swing, rest)
    return pose


# ============================================================================= long-stride run cycles
# The reference's run: about 1.7 strides a second with long steps (~1.5 m), a high heel kick and a
# forward lean, at the game's run speed. The base run_* cycles (0.7 s, 2 m/s) played 2.5x faster
# at 5 m/s looked like a choppy jog. One cycle length for every direction keeps the blend in step;
# the game plays these instead of run_* (runx_* in character_model.gd).
RUNX_T = 0.6
RUNX_SPEED = 5.0
_RUNX = dict(T=RUNX_T, speed=RUNX_SPEED, stance=0.25, bob=0.045, drop=0.10)
RUNX = {
    "runx_fwd": dict(AN.RUN_FWD, **_RUNX, lift=0.34, lift_skew=0.65, lean=13.0, front_bias=0.05,
                     strike_pitch=14.0, toeoff_pitch=-42.0, swing_pitch=-22.0),
    "runx_back": dict(AN.RUN_BACK, **dict(_RUNX, stance=0.27, bob=0.035, drop=0.08), lift=0.22),
    "runx_left": dict(AN.RUN_LEFT, **dict(_RUNX, stance=0.27, bob=0.035, drop=0.09), lift=0.24),
    "runx_right": dict(AN.RUN_RIGHT, **dict(_RUNX, stance=0.27, bob=0.035, drop=0.09), lift=0.24),
}


def runx_pose(name):
    return lambda t: AN.locomotion_pose(t, RUNX[name])


# ============================================================================= registry / build
ANIMS = [
    # name, frames (last == first for loops), loop, pose fn(t)
    ("reload", int(round(RELOAD_T * FPS)), False, reload_pose),
    ("pump", int(round(PUMP_T * FPS)), False, pump_pose),
    ("heal", int(round(HEAL_T * FPS)), True, heal_pose),
    ("throw", int(round(THROW_T * FPS)), False, throw_pose),
    ("swap", int(round(SWAP_T * FPS)), False, swap_pose),
    ("hit_react", int(round(HIT_T * FPS)), False, hit_pose),
    ("prone_idle", int(round(PRONE_IDLE_T * FPS)), True, prone_idle_pose),
    ("prone_fwd", int(round(PRONE_FWD_T * FPS)), True, prone_fwd_pose),
    ("fists_idle", 1, False, lambda t: fists_pose(0.0, rest=True)),
    ("fists_run_a", 1, False, lambda t: fists_pose(1.0)),
    ("fists_run_b", 1, False, lambda t: fists_pose(-1.0)),
] + [(n, int(round(RUNX_T * FPS)), True, runx_pose(n)) for n in RUNX]


def sample(fn, nframes):
    return [fn(f / FPS) for f in range(nframes + 1)]


def build(only=None):
    arm = AN.arm
    arm.animation_data_create()
    info = {}
    for name, nframes, loop, fn in ANIMS:
        if only and name not in only:
            continue
        poses = sample(fn, nframes)
        frames = [copy_B(p) for p in poses]
        act = A.write_action(name, frames, FPS, loop)
        tr = arm.animation_data.nla_tracks.new()
        tr.name = name
        tr.strips.new(name, 0, act)
        tr.mute = True
        info[name] = {"frames": nframes + 1, "seconds": nframes / FPS, "loop": loop, "poses": poses}
        print("built", name, nframes + 1, "frames")
    arm.animation_data.action = None
    return info


def strip_for_export(keep_actions):
    arm = AN.arm
    for ob in list(bpy.data.objects):
        if ob != arm and ob.name != "Eyes":
            bpy.data.objects.remove(ob, do_unlink=True)
    for act in list(bpy.data.actions):
        if act.name not in keep_actions:
            bpy.data.actions.remove(act)
    if arm.animation_data:
        for tr in list(arm.animation_data.nla_tracks):
            if not tr.strips or tr.strips[0].action is None or tr.strips[0].action.name not in keep_actions:
                arm.animation_data.nla_tracks.remove(tr)
        arm.animation_data.action = None
    for pb in arm.pose.bones:
        pb.location = (0, 0, 0)
        pb.rotation_quaternion = (1, 0, 0, 0)
        pb.scale = (1, 1, 1)
    for blk in (bpy.data.meshes, bpy.data.materials, bpy.data.images):
        for d in list(blk):
            if d.users == 0:
                blk.remove(d)


def export(path):
    bpy.context.scene.frame_set(0)
    bpy.ops.export_scene.gltf(
        filepath=path, export_format='GLB', use_selection=False, export_yup=True,
        export_apply=True, export_texcoords=False, export_normals=True, export_tangents=False,
        export_materials='NONE', export_skins=True, export_def_bones=True, export_influence_nb=4,
        export_all_influences=False, export_morph=False, export_animations=True,
        export_animation_mode='ACTIONS', export_force_sampling=True, export_frame_step=1,
        export_optimize_animation_size=True, export_anim_single_armature=True,
        export_reset_pose_bones=True, export_rest_position_armature=True, export_nla_strips=True,
        export_current_frame=False, export_extras=False, export_cameras=False, export_lights=False,
    )
    print("exported", path, round(os.path.getsize(path) / 1024, 1), "KB")


def main(argv):
    def arg(name, default=None):
        return argv[argv.index(name) + 1] if name in argv else default
    only = arg("--only")
    only = only.split(",") if only else None
    load_character()
    info = build(only)
    if arg("--save"):
        bpy.ops.wm.save_as_mainfile(filepath=arg("--save"))
    if "--no-export" not in argv:
        strip_for_export(set(info.keys()))
        export(arg("--out", GLB_OUT))
    return info


if __name__ == "__main__":
    main(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
