"""Stage C: procedural gameplay animations (30 fps, in place), written as baked FK actions.
idle, run_fwd, run_back, run_left, run_right, crouch_idle, crouch_fwd, jump, death, victory,
lobby_idle. Saves WORK/stage_c.blend and WORK/anim_info.json

As a module (e.g. tools/character/anim_extra.py): `import animate; animate.setup(armature)` initialises
the helpers on an already loaded armature without opening stage_b.blend."""
import os
import sys
import json
import math

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
from mathutils import Matrix, Vector

import char_config as CFG
import animlib as A
from animlib import rot, lerp, smooth, foot_pose

FPS = 30
arm = None              # the armature object, set by setup()
PELVIS_REST = None      # rest head of the pelvis, set by setup()  (0, -0.004, 0.972)
CHEST_REF = None        # spine_03 world matrix of a neutral standing pose, set by setup()
X, Y, Z = (1, 0, 0), (0, 1, 0), (0, 0, 1)

# ----------------------------------------------------------------------------- rifle design (world, idle)
RIFLE_RH = Vector((-0.125, -0.275, 1.295))     # right wrist (hand_r head) - trigger grip
RIFLE_LH = Vector((-0.035, -0.555, 1.330))     # left wrist (hand_l head) - foregrip
RIFLE_POLE_R = Vector((-0.55, 0.20, 0.95))
RIFLE_POLE_L = Vector((0.35, -0.20, 0.85))


def rifle_hand_frames(rh, lh):
    g = (lh - rh).normalized()
    down = Vector((0, 0, -1))
    down = (down - g * down.dot(g)).normalized()
    f_r = (g * math.cos(math.radians(28)) + down * math.sin(math.radians(28))).normalized()
    p_r = Vector((1.0, 0.0, 0.15))
    rgt = Vector((-1, 0, 0))
    rgt = (rgt - g * rgt.dot(g)).normalized()
    f_l = (g * math.cos(math.radians(50)) + rgt * math.sin(math.radians(50))).normalized()
    p_l = Vector((-0.35, 0.0, 1.0))
    return (f_r, p_r), (f_l, p_l)


GRIP_R = {"index": (8, 18, 12), "middle": (70, 80, 45), "ring": (72, 82, 45), "pinky": (75, 85, 45)}
GRIP_L = {"index": (42, 48, 28), "middle": (48, 52, 30), "ring": (52, 55, 30), "pinky": (55, 58, 30)}
RELAX = {"index": (8, 12, 8), "middle": (12, 16, 10), "ring": (15, 18, 10), "pinky": (18, 20, 12)}
FIST = {"index": (80, 95, 60), "middle": (85, 95, 60), "ring": (88, 95, 60), "pinky": (90, 95, 60)}


# ----------------------------------------------------------------------------- body helpers
def set_upper(pose, pelvis_pos, pelvis_rot, spine_rot, neck_rot, head_rot, clav_l=None, clav_r=None):
    pose.set_pelvis(pelvis_pos, pelvis_rot)
    for n, D in zip(("spine_01", "spine_02", "spine_03"), spine_rot):
        pose.set_delta(n, D)
    pose.set_delta("neck_01", neck_rot)
    pose.set_delta("head", head_rot)
    pose.set_delta("clavicle_l", clav_l if clav_l is not None else Matrix.Identity(3))
    pose.set_delta("clavicle_r", clav_r if clav_r is not None else Matrix.Identity(3))
    pose.fk()


def legs(pose, feet, knee_out=0.12):
    """feet: {'l': (ankle, Q, toe_deg), 'r': ...}"""
    for s in ("l", "r"):
        ankle, Q, toe = feet[s]
        fwd = Q @ Vector((0, -1, 0))
        side = 1 if s == "l" else -1
        pole = ankle + fwd * 0.7 + Vector((0, 0, 0.55)) + Vector((side * knee_out, 0, 0))
        pose.two_bone("thigh_" + s, "calf_" + s, ankle, pole)
        pose.foot_orient(s, Q)
        pose.set_delta("ball_" + s, rot(X, -toe))
        pose.fk()


CHEST = {}


def capture_rifle_chest(pose):
    """Store rifle hand targets / poles / hand frames in spine_03 space (from the idle pose)."""
    C = pose.P["spine_03"]
    Ci = C.inverted()
    C3i = C.to_3x3().inverted()
    (fr, pr), (fl, pl) = rifle_hand_frames(RIFLE_RH, RIFLE_LH)
    CHEST.update({
        "rh": Ci @ RIFLE_RH, "lh": Ci @ RIFLE_LH, "pr": Ci @ RIFLE_POLE_R, "pl": Ci @ RIFLE_POLE_L,
        "fr": C3i @ fr, "prn": C3i @ pr, "fl": C3i @ fl, "pln": C3i @ pl,
    })


def rifle_arms(pose, offset=Vector((0, 0, 0)), sway=Matrix.Identity(3)):
    pose.fk()
    C = pose.P["spine_03"]
    C3 = C.to_3x3()
    piv = C @ ((CHEST["rh"] + CHEST["lh"]) * 0.5)

    def tw(p):
        w = C @ p
        return piv + sway @ (w - piv) + offset
    rh, lh = tw(CHEST["rh"]), tw(CHEST["lh"])
    pr, pl = C @ CHEST["pr"] + offset, C @ CHEST["pl"] + offset
    pose.two_bone("upperarm_r", "lowerarm_r", rh, pr)
    pose.two_bone("upperarm_l", "lowerarm_l", lh, pl)
    pose.hand_orient("r", sway @ C3 @ CHEST["fr"], sway @ C3 @ CHEST["prn"])
    pose.hand_orient("l", sway @ C3 @ CHEST["fl"], sway @ C3 @ CHEST["pln"])
    pose.fingers("r", GRIP_R, thumb=(35, 25, 15))
    pose.fingers("l", GRIP_L, thumb=(30, 20, 12))
    pose.fk()
    return rh, lh


# ----------------------------------------------------------------------------- idle (rifle ready)
IDLE_FEET = {
    "l": ("ball", Vector((0.135, -0.215, 0.008)), -12.0),
    "r": ("ball", Vector((-0.150, -0.035, 0.008)), -32.0),
}
PELVIS_DROP_IDLE = 0.035
PELVIS_YAW_IDLE = -14.0


def idle_upper_rots(breath=0.0, yaw_extra=0.0, lean_extra=0.0):
    pr = rot(Z, PELVIS_YAW_IDLE + yaw_extra * 0.3) @ rot(X, 3.0)
    sp = [rot(Z, -5.0 + yaw_extra * 0.2) @ rot(X, 2.0 + lean_extra * 0.3),
          rot(Z, -5.0 + yaw_extra * 0.2) @ rot(X, 2.0 + lean_extra * 0.3 + breath * 0.5),
          rot(Z, -6.0 + yaw_extra * 0.3) @ rot(X, 2.5 + lean_extra * 0.4 - breath)]
    neck = rot(Z, 12.0) @ rot(X, -3.0)
    head = rot(Z, 18.0 - yaw_extra * 0.1) @ rot(X, -6.0 - lean_extra * 0.5 + breath * 0.5)
    cl = rot(Z, -12.0) @ rot(X, 4.0)
    cr = rot(Z, 4.0)
    return pr, sp, neck, head, cl, cr


def idle_feet():
    return {s: foot_pose(s, a, p, yaw, 0.0) for s, (a, p, yaw) in IDLE_FEET.items()}


def pose_idle(t=0.0, period=2.0):
    ph = 2 * math.pi * t / period
    breath = math.sin(ph)
    pose = A.Pose()
    pr, sp, neck, head, cl, cr = idle_upper_rots(breath=breath * 0.8)
    pos = PELVIS_REST + Vector((0.0, 0.0, -PELVIS_DROP_IDLE + 0.004 * math.sin(ph)))
    set_upper(pose, pos, pr, sp, neck, head, cl, cr)
    legs(pose, idle_feet())
    sway = rot(Z, 0.6 * math.sin(ph)) @ rot(X, 0.5 * math.cos(ph))
    rifle_arms(pose, sway=sway)
    return pose


def calibrate():
    pose = A.Pose()
    pr, sp, neck, head, cl, cr = idle_upper_rots()
    set_upper(pose, PELVIS_REST + Vector((0, 0, -PELVIS_DROP_IDLE)), pr, sp, neck, head, cl, cr)
    capture_rifle_chest(pose)


# ============================================================================= generic helpers
def foot_at(s, ball_pos, yaw, pitch, toe=None):
    """Ball-referenced foot placement, continuous through pitch 0 (heel pivot for toes-up)."""
    g = A.FOOT_GEO[s]
    Q = rot(Z, yaw) @ rot(X, -pitch)
    P = Vector(ball_pos)
    if pitch < 0:
        ankle = P + Q @ (g["ankle"] - g["ball"])
    else:
        heel = P + rot(Z, yaw) @ (g["heel"] - g["ball"])
        ankle = heel + Q @ (g["ankle"] - g["heel"])
    return ankle, Q, (pitch if toe is None else toe)


def chest_yaw_fix(pelvis_yaw, target_chest_yaw=-30.0):
    return target_chest_yaw - pelvis_yaw


def interp_keys(keys, t):
    """keys: list of (time, value) with value float/Vector; smooth (eased) interpolation."""
    if t <= keys[0][0]:
        return keys[0][1]
    for (t0, v0), (t1, v1) in zip(keys, keys[1:]):
        if t <= t1:
            u = smooth((t - t0) / (t1 - t0))
            return v0 + (v1 - v0) * u
    return keys[-1][1]


# ============================================================================= locomotion
def locomotion_pose(t, P):
    T = P["T"]
    pose = A.Pose()
    beta = P["stance"]
    D = P["speed"] * beta * T                      # ground contact length
    dirv = Vector((P["dir"][0], P["dir"][1], 0)).normalized()
    hips_yaw = P.get("hips_yaw", 0.0)
    feet = {}
    for s in ("l", "r"):
        ph = (t / T + (0.0 if s == "l" else 0.5)) % 1.0
        base = Vector(P["base"][s])
        if ph < beta:
            k = ph / beta
            u = D / 2 + P.get("front_bias", 0.0) - k * D
            h = 0.0
            if k < 0.18:
                pitch = lerp(P["strike_pitch"], 0.0, smooth(k / 0.18))
            elif k < 0.5:
                pitch = 0.0
            else:
                pitch = lerp(0.0, P["toeoff_pitch"], smooth((k - 0.5) / 0.5))
            toe = pitch if pitch < 0 else 0.0
            off = Vector((0, 0, 0))
        else:
            k = (ph - beta) / (1 - beta)
            u0, u1 = -D / 2 + P.get("front_bias", 0.0), D / 2 + P.get("front_bias", 0.0)
            u = u0 + (u1 - u0) * (0.5 - 0.5 * math.cos(math.pi * k))
            h = P["lift"] * math.sin(math.pi * min(1.0, k ** P.get("lift_skew", 0.8))) ** 1.1
            pitch = interp_keys([(0.0, P["toeoff_pitch"]), (0.35, P["swing_pitch"]), (0.8, P["strike_pitch"] * 0.4),
                                 (1.0, P["strike_pitch"])], k)
            toe = interp_keys([(0.0, P["toeoff_pitch"]), (0.3, 0.0), (1.0, 0.0)], k)
            off = Vector(P.get("swing_offset", {}).get(s, (0, 0, 0))) * math.sin(math.pi * k)
        pos = base + dirv * u + off + Vector((0, 0, h))
        feet[s] = foot_at(s, pos, P["foot_yaw"][s], pitch, toe)
    # pelvis
    phl = (t / T) % 1.0
    bob = -P["bob"] * math.cos(4 * math.pi * (phl - beta / 2))
    pyaw = hips_yaw + P.get("yaw_osc", 4.0) * -math.cos(2 * math.pi * phl)
    proll = P.get("roll_osc", 2.5) * math.sin(2 * math.pi * phl)
    lean = P["lean"]
    ppos = PELVIS_REST + Vector((0, 0, -P["drop"] + bob)) + Vector(P.get("pelvis_off", (0, 0, 0)))
    prot = rot(Z, pyaw) @ rot(Y, proll) @ rot(X, lean * 0.4)
    cy = chest_yaw_fix(pyaw, P.get("chest_yaw", -30.0))
    sroll = -proll / 3.0
    breath = 0.0
    sp = [rot(Z, cy * 0.3) @ rot(Y, sroll) @ rot(X, lean * 0.2),
          rot(Z, cy * 0.3) @ rot(Y, sroll) @ rot(X, lean * 0.2),
          rot(Z, cy * 0.4) @ rot(Y, sroll) @ rot(X, lean * 0.2 + P.get("chest_pitch", 0.0))]
    neck = rot(Z, 12.0) @ rot(X, -lean * 0.3)
    head = rot(Z, 18.0) @ rot(X, -lean * 0.45 - P.get("chest_pitch", 0.0) - 4.0)
    cl = rot(Z, -12.0) @ rot(X, 4.0)
    cr = rot(Z, 4.0)
    set_upper(pose, ppos, prot, sp, neck, head, cl, cr)
    legs(pose, feet, knee_out=P.get("knee_out", 0.10))
    sway = rot(Z, P.get("gun_sway", 1.5) * math.sin(2 * math.pi * phl)) @ rot(X, 1.0 * math.sin(4 * math.pi * phl))
    rifle_arms(pose, offset=Vector(P.get("gun_off", (0, 0, 0))), sway=sway)
    return pose


RUN_BASE = dict(T=0.7, speed=2.0, stance=0.38, lift=0.24, bob=0.03, drop=0.07, lean=10.0,
                strike_pitch=12.0, toeoff_pitch=-38.0, swing_pitch=-8.0,
                foot_yaw={"l": -4.0, "r": 4.0}, base={"l": (0.10, 0.0, 0.008), "r": (-0.10, 0.0, 0.008)})

RUN_FWD = dict(RUN_BASE, dir=(0, -1), front_bias=0.03)
RUN_BACK = dict(RUN_BASE, dir=(0, 1), lift=0.16, lean=2.0, strike_pitch=-10.0, toeoff_pitch=5.0, swing_pitch=-15.0,
                front_bias=0.0, stance=0.42)
RUN_LEFT = dict(RUN_BASE, dir=(1, 0), hips_yaw=22.0, lift=0.18, lean=6.0, stance=0.42, knee_out=0.0,
                strike_pitch=6.0, toeoff_pitch=-25.0, foot_yaw={"l": 25.0, "r": 18.0},
                base={"l": (0.09, -0.02, 0.008), "r": (-0.09, 0.03, 0.008)}, yaw_osc=3.0,
                swing_offset={"r": (0, -0.10, 0), "l": (0, 0.0, 0)})
RUN_RIGHT = dict(RUN_BASE, dir=(-1, 0), hips_yaw=-22.0, lift=0.18, lean=6.0, stance=0.42, knee_out=0.0,
                 strike_pitch=6.0, toeoff_pitch=-25.0, foot_yaw={"l": -18.0, "r": -25.0},
                 base={"l": (0.09, 0.03, 0.008), "r": (-0.09, -0.02, 0.008)}, yaw_osc=3.0,
                 swing_offset={"l": (0, -0.10, 0), "r": (0, 0.0, 0)})
CROUCH_FWD = dict(T=1.0, speed=1.0, stance=0.62, lift=0.11, bob=0.012, drop=0.40, lean=20.0,
                  strike_pitch=8.0, toeoff_pitch=-25.0, swing_pitch=-5.0, dir=(0, -1), front_bias=0.04,
                  foot_yaw={"l": -8.0, "r": 8.0}, base={"l": (0.13, 0.0, 0.008), "r": (-0.13, 0.0, 0.008)},
                  yaw_osc=3.0, roll_osc=1.5, knee_out=0.16, pelvis_off=(0, 0.04, 0), gun_off=(0, 0, -0.02),
                  chest_pitch=-6.0, gun_sway=1.0)


# ============================================================================= static-ish poses
def pose_crouch_idle(t, period=2.0):
    ph = 2 * math.pi * t / period
    breath = math.sin(ph)
    pose = A.Pose()
    pyaw = -16.0
    lean = 22.0
    prot = rot(Z, pyaw) @ rot(X, lean * 0.45)
    ppos = PELVIS_REST + Vector((0.0, 0.05, -0.45 + 0.004 * breath))
    cy = chest_yaw_fix(pyaw)
    sp = [rot(Z, cy * 0.3) @ rot(X, lean * 0.15), rot(Z, cy * 0.3) @ rot(X, lean * 0.15 + 0.4 * breath),
          rot(Z, cy * 0.4) @ rot(X, lean * 0.1 - 6.0 - 0.8 * breath)]
    neck = rot(Z, 12.0) @ rot(X, -lean * 0.35)
    head = rot(Z, 18.0) @ rot(X, -lean * 0.45 - 2.0)
    cl = rot(Z, -12.0) @ rot(X, 4.0)
    cr = rot(Z, 4.0)
    set_upper(pose, ppos, prot, sp, neck, head, cl, cr)
    feet = {"l": foot_at("l", Vector((0.15, -0.36, 0.008)), -10.0, 0.0),
            "r": foot_at("r", Vector((-0.14, 0.16, 0.008)), -22.0, -38.0)}
    legs(pose, feet, knee_out=0.04)
    sway = rot(Z, 0.5 * math.sin(ph)) @ rot(X, 0.4 * math.cos(ph))
    rifle_arms(pose, offset=Vector((0, 0, -0.01)), sway=sway)
    return pose


def pose_jump(t):
    """0.6 s airborne: take-off extension -> tuck -> reach for landing. In place (the game moves
    the capsule), so the pelvis stays near standing height and the legs tuck up."""
    pose = A.Pose()
    tuck = interp_keys([(0.0, 0.0), (0.22, 1.0), (0.38, 1.0), (0.6, 0.15)], t)
    pyaw = -10.0
    lean = interp_keys([(0.0, 4.0), (0.25, 10.0), (0.6, 6.0)], t)
    ppos = PELVIS_REST + Vector((0, 0.0, interp_keys([(0.0, 0.02), (0.3, 0.03), (0.6, -0.01)], t)))
    prot = rot(Z, pyaw) @ rot(X, lean * 0.5)
    cy = chest_yaw_fix(pyaw)
    sp = [rot(Z, cy * 0.3) @ rot(X, lean * 0.2), rot(Z, cy * 0.3) @ rot(X, lean * 0.2), rot(Z, cy * 0.4) @ rot(X, lean * 0.1)]
    neck = rot(Z, 12.0) @ rot(X, -lean * 0.3)
    head = rot(Z, 18.0) @ rot(X, -lean * 0.4 - 4.0)
    set_upper(pose, ppos, prot, sp, neck, head, rot(Z, -12.0) @ rot(X, 4.0), rot(Z, 4.0))
    # feet: start hanging/pointed (take-off), tuck up, then reach down/forward for landing
    lz = lerp(0.0, 0.34, tuck)
    rz = lerp(0.0, 0.26, tuck)
    land = smooth((t - 0.42) / 0.18)
    feet = {
        "l": foot_at("l", Vector((0.12, lerp(-0.10, -0.20, tuck) - 0.05 * land, 0.03 + lz)), -8.0,
                     lerp(-40.0, -12.0, tuck) + 18.0 * land, toe=0.0),
        "r": foot_at("r", Vector((-0.12, lerp(0.05, 0.12, tuck) - 0.08 * land, 0.03 + rz)), -12.0,
                     lerp(-45.0, -25.0, tuck) + 25.0 * land, toe=0.0),
    }
    legs(pose, feet, knee_out=0.10)
    rifle_arms(pose, offset=Vector((0, 0, 0.01 * tuck)))
    return pose


def standing_feet(spread=0.14, yaw=9.0, fwd=(0.0, 0.0)):
    return {"l": foot_at("l", Vector((spread + 0.02, -0.13 + fwd[0], 0.008)), yaw, 0.0),
            "r": foot_at("r", Vector((-spread - 0.02, -0.13 + fwd[1], 0.008)), -yaw, 0.0)}


def free_arm(pose, s, wrist, pole, f=None, p=None, curls=RELAX, thumb=(10, 8, 5), hand_w=1.0):
    pose.two_bone("upperarm_" + s, "lowerarm_" + s, wrist, pole)
    if f is not None:
        B0 = pose.B["hand_" + s].copy()
        pose.hand_orient(s, f, p)
        if hand_w < 1.0:
            q = Matrix.Identity(4).to_quaternion().slerp(pose.B["hand_" + s].to_quaternion(), hand_w)
            M = q.to_matrix().to_4x4()
            pose.B["hand_" + s] = M
    pose.fingers(s, curls, thumb=thumb)
    pose.fk()


def pose_lobby(t, period=4.0):
    w = 2 * math.pi * t / period
    br = math.sin(2 * w)                     # two breaths per loop
    shift = math.sin(w)
    pose = A.Pose()
    ppos = PELVIS_REST + Vector((0.025 * shift, 0.0, -0.012 - 0.006 * abs(shift) + 0.002 * br))
    prot = rot(Y, -2.5 * shift) @ rot(Z, 2.0 * math.sin(w + 0.6))
    sp = [rot(Y, 1.0 * shift) @ rot(X, 0.5), rot(Y, 0.8 * shift) @ rot(X, 0.4 * br),
          rot(Y, 0.6 * shift) @ rot(X, -0.9 * br) @ rot(Z, -1.0 * math.sin(w + 0.6))]
    neck = rot(X, -1.0) @ rot(Z, 2.0 * math.sin(w + 1.2))
    head = rot(Z, 4.0 * math.sin(w + 1.2)) @ rot(X, -2.0 + 0.5 * br) @ rot(Y, 1.0 * shift)
    cl = rot(X, 1.5 * br) @ rot(Z, 2.0)
    cr = rot(X, 1.5 * br) @ rot(Z, -2.0)
    set_upper(pose, ppos, prot, sp, neck, head, cl, cr)
    legs(pose, standing_feet(0.12, 10.0, (-0.02, 0.03)), knee_out=0.10)
    C = pose.P["spine_03"]
    for s, side in (("l", 1), ("r", -1)):
        wrist = C @ (CHEST_REF.inverted() @ Vector((side * 0.265, -0.035, 0.925 + 0.004 * br)))
        pole = C @ (CHEST_REF.inverted() @ Vector((side * 0.40, 0.45, 1.15)))
        f = C.to_3x3() @ (CHEST_REF.to_3x3().inverted() @ Vector((side * 0.05, -0.12, -1.0)))
        pv = C.to_3x3() @ (CHEST_REF.to_3x3().inverted() @ Vector((-side * 1.0, 0.25, 0.0)))
        free_arm(pose, s, wrist, pole, f, pv)
    return pose


def pose_victory(t, period=1.0):
    w = 2 * math.pi * t / period
    pump = 0.5 - 0.5 * math.cos(w)          # 0 = fists high, 1 = fists pulled down
    pose = A.Pose()
    ppos = PELVIS_REST + Vector((0.0, 0.01, -0.02 - 0.05 * pump))
    prot = rot(X, -3.0 + 3.0 * pump)
    sp = [rot(X, -2.0), rot(X, -3.0 + 2.0 * pump), rot(X, -4.0 + 3.0 * pump)]
    neck = rot(X, -4.0)
    head = rot(X, -10.0 + 5.0 * pump) @ rot(Z, 4.0 * math.sin(w * 0.5))
    cl = rot(Y, 0.0) @ rot(X, -6.0 + 4.0 * pump)
    cr = rot(X, -6.0 + 4.0 * pump)
    cl = rot(Z, 0.0) @ Matrix.Rotation(math.radians(10.0 - 8.0 * pump), 3, Vector((0, 1, 0))) @ cl
    cr = Matrix.Rotation(math.radians(-10.0 + 8.0 * pump), 3, Vector((0, 1, 0))) @ cr
    set_upper(pose, ppos, prot, sp, neck, head, cl, cr)
    legs(pose, standing_feet(0.15, 12.0), knee_out=0.12)
    for s, side in (("l", 1), ("r", -1)):
        wrist = Vector((side * lerp(0.36, 0.42, pump), lerp(-0.10, -0.12, pump), lerp(1.98, 1.66, pump)))
        pole = Vector((side * 0.9, 0.35, lerp(1.45, 1.25, pump)))
        f = Vector((side * 0.15, -0.1, 1.0))
        pv = Vector((-side * 0.2, -1.0, 0.0))
        free_arm(pose, s, wrist, pole, f, pv, curls=FIST, thumb=(45, 40, 30))
    return pose


def pose_death(t):
    """1.2 s: hit -> knees buckle -> fall backwards -> lie on the back."""
    pose = A.Pose()
    kt = [0.0, 0.15, 0.45, 0.80, 1.0, 1.2]

    def K(vals):
        return interp_keys(list(zip(kt, vals)), t)
    pz = K([-PELVIS_DROP_IDLE, -0.02, -0.33, -0.70, -0.855, -0.86])
    py = K([0.0, 0.04, 0.14, 0.36, 0.48, 0.50])
    pitch = K([3.0, -6.0, -22.0, -62.0, -88.0, -90.0])
    yaw = K([PELVIS_YAW_IDLE, -8.0, 4.0, 8.0, 6.0, 6.0])
    sp_pitch = K([2.0, -8.0, -10.0, -6.0, 2.0, 0.0])
    sp_yaw = K([-5.0, -2.0, 0.0, 0.0, 0.0, 0.0])
    head_pitch = K([-6.0, -25.0, -10.0, 15.0, -12.0, -4.0])
    head_yaw = K([18.0, 10.0, 0.0, 0.0, 10.0, 28.0])
    ppos = PELVIS_REST + Vector((0.0, py, pz))
    prot = rot(Z, yaw) @ rot(X, pitch)
    sp = [rot(Z, sp_yaw) @ rot(X, sp_pitch * 0.3), rot(Z, sp_yaw) @ rot(X, sp_pitch * 0.3),
          rot(Z, sp_yaw * 1.2) @ rot(X, sp_pitch * 0.4)]
    neck = rot(Z, head_yaw * 0.4) @ rot(X, head_pitch * 0.4)
    head = rot(Z, head_yaw * 0.6) @ rot(X, head_pitch * 0.6)
    set_upper(pose, ppos, prot, sp, neck, head, rot(Z, K([-12.0, -6, 0, 0, 0, 0])) @ rot(X, 4.0), rot(Z, 4.0))
    # legs: feet planted, then slide/lift as the body falls, end with knees bent up
    Pp = pose.P["pelvis"]
    # ankles driven directly: planted -> buckle -> legs swing up slightly -> lie nearly extended
    la = Vector((K([0.158, 0.158, 0.16, 0.18, 0.21, 0.22]), K([-0.087, -0.087, -0.08, -0.25, -0.36, -0.37]),
                 K([0.073, 0.073, 0.073, 0.16, 0.09, 0.08])))
    ra = Vector((K([-0.078, -0.078, -0.09, -0.14, -0.22, -0.26]), K([0.073, 0.073, 0.05, -0.15, -0.30, -0.27]),
                 K([0.073, 0.073, 0.073, 0.22, 0.12, 0.085])))
    lq = rot(Z, K([-12.0, -12.0, -10.0, 0.0, 15.0, 25.0])) @ rot(X, -K([0.0, 0.0, 0.0, 30.0, 60.0, 65.0]))
    rq = rot(Z, K([-32.0, -32.0, -28.0, -30.0, -38.0, -42.0])) @ rot(X, -K([0.0, 0.0, 0.0, 30.0, 58.0, 62.0]))
    feet = {"l": (la, lq, 0.0), "r": (ra, rq, 0.0)}
    Pr = Pp.to_3x3() @ A.REST["pelvis"].to_3x3().inverted()     # pelvis rotation relative to rest
    for s, side in (("l", 1), ("r", -1)):
        ankle, Q, toe = feet[s]
        fwd = Pr @ Vector((0, -1, 0))
        pole = ankle + fwd * 0.7 + Pr @ Vector((side * 0.12, 0, 0.55))
        pose.two_bone("thigh_" + s, "calf_" + s, ankle, pole)
        pose.foot_orient(s, Q)
        pose.fk()
    # arms: rifle grip released at 0.1 s, flung up/out, end spread on the ground
    w_rifle = 1.0 - smooth(t / 0.15)
    pose_r = A.Pose()
    pose_r.B = {k: v.copy() for k, v in pose.B.items()}
    pose_r.fk()
    rifle_arms(pose_r)
    C = pose.P["spine_03"]
    Ci = CHEST_REF.inverted()
    for s, side in (("l", 1), ("r", -1)):
        wx = K([0.0, 0.42, 0.62, 0.68, 0.72, 0.70])
        wy = K([0.0, -0.20, -0.05, 0.10, 0.18, 0.20])
        wz = K([0.0, 1.62, 1.55, 1.52, 1.50, 1.48])
        wrist = C @ (Ci @ Vector((side * wx, wy, wz)))
        pole = C @ (Ci @ Vector((side * 0.55, 0.40, 1.0)))
        free_arm(pose, s, wrist, pole, curls={k: tuple(v * 1.3 for v in vv) for k, vv in RELAX.items()})
    # blend arm bones between rifle pose and released pose
    for n in list(pose.B.keys()):
        if any(n.startswith(p) for p in ("upperarm", "lowerarm", "hand", "thumb", "index", "middle", "ring", "pinky")):
            qa = pose_r.B[n].to_quaternion()
            qb = pose.B[n].to_quaternion()
            if qa.dot(qb) < 0:
                qb.negate()
            pose.B[n] = qa.slerp(qb, 1.0 - w_rifle).to_matrix().to_4x4()
    pose.fk()
    return pose


def setup(armature):
    """Initialise the toolkit on `armature` (once): strip pose constraints, animlib init, scene fps,
    rifle grip calibration (calibrate()) and the reference chest CHEST_REF."""
    global arm, PELVIS_REST, CHEST_REF
    arm = armature
    for pb in arm.pose.bones:
        for c in list(pb.constraints):
            pb.constraints.remove(c)
    A.init(arm)
    bpy.context.scene.render.fps = FPS
    PELVIS_REST = A.REST["pelvis"].translation.copy()     # (0, -0.004, 0.972)
    calibrate()
    # reference chest (spine_03 world matrix) of a neutral standing pose: used to express free-arm targets
    _ref = A.Pose()
    _ref.set_pelvis(PELVIS_REST + Vector((0, 0, -0.012)), Matrix.Identity(3))
    _ref.fk()
    CHEST_REF = _ref.P["spine_03"].copy()
    return arm


# ============================================================================= build all actions
ANIMS = [
    # name, frames (last == first for loops), loop, pose fn(t)
    ("idle", 60, True, lambda t: pose_idle(t, 2.0)),
    ("run_fwd", 21, True, lambda t: locomotion_pose(t, RUN_FWD)),
    ("run_back", 21, True, lambda t: locomotion_pose(t, RUN_BACK)),
    ("run_left", 21, True, lambda t: locomotion_pose(t, RUN_LEFT)),
    ("run_right", 21, True, lambda t: locomotion_pose(t, RUN_RIGHT)),
    ("crouch_idle", 60, True, lambda t: pose_crouch_idle(t, 2.0)),
    ("crouch_fwd", 30, True, lambda t: locomotion_pose(t, CROUCH_FWD)),
    ("jump", 18, False, pose_jump),
    ("death", 36, False, pose_death),
    ("victory", 60, True, lambda t: pose_victory(t, 1.0)),
    ("lobby_idle", 120, True, lambda t: pose_lobby(t, 4.0)),
]


def build(only=None):
    info = {}
    arm.animation_data_create()
    for name, nframes, loop, fn in ANIMS:
        if only and name not in only:
            continue
        frames = []
        for f in range(nframes + 1):
            t = f / FPS
            pose = fn(t)
            frames.append({k: v.copy() for k, v in pose.B.items()})
        act = A.write_action(name, frames, FPS, loop)
        # keep every action on its own (muted) NLA track so the exporter sees all of them
        tr = arm.animation_data.nla_tracks.new()
        tr.name = name
        strip = tr.strips.new(name, 0, act)
        tr.mute = True
        info[name] = {"frames": nframes + 1, "frame_start": 0, "frame_end": nframes,
                      "seconds": nframes / FPS, "loop": loop}
        print("built", name, nframes + 1, "frames")
    arm.animation_data.action = None
    return info


if __name__ == "__main__":
    bpy.ops.wm.open_mainfile(filepath=os.path.join(CFG.WORK, "stage_b.blend"))
    setup(bpy.data.objects["Armature"])
    only = None
    if "--only" in sys.argv:
        only = sys.argv[sys.argv.index("--only") + 1].split(",")
    info = build(only)
    # report rifle pose (idle frame 0) in world space
    p = pose_idle(0.0)
    hand = {s: {"pos": [round(c, 4) for c in p.head("hand_" + s)],
                "x_axis": [round(c, 4) for c in p.P["hand_" + s].to_3x3().col[0]],
                "y_axis": [round(c, 4) for c in p.P["hand_" + s].to_3x3().col[1]],
                "z_axis": [round(c, 4) for c in p.P["hand_" + s].to_3x3().col[2]]} for s in "lr"}
    with open(os.path.join(CFG.WORK, "anim_info.json"), "w") as f:
        json.dump({"animations": info, "rifle_idle_hands_blender": hand,
                   "rifle_design_targets_blender": {"hand_r": list(RIFLE_RH), "hand_l": list(RIFLE_LH)}}, f, indent=1)
    out = os.path.join(CFG.WORK, "stage_c.blend") if not only else os.path.join(CFG.WORK, "stage_c_test.blend")
    bpy.ops.wm.save_as_mainfile(filepath=out)
    print("STAGE C saved", out)
