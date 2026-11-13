"""Second set of procedural clips for the hero character, exported to
assets/character/anims_extra2.glb (armature + the tiny Eyes mesh + the new actions only; the game
merges them into the character's AnimationPlayer like anims_extra.glb, see character_model.gd).
Every keyframe is computed here (FK quaternions + pelvis location, 30 fps, in place), on the same
skeleton, with the pose helpers of tools/character/animate.py and anim_extra.py: no outside motion
data, so the clips are ours (CC0 like the character).

Clips:
  carry_idle (loop 2 s)   relaxed match idle: the gun held low by its grip in the right hand at the
                          hip, muzzle down-forward; the left arm hangs. The aim pose takes over when
                          the fighter fires or scopes (CharacterModel.raise_gun).
  carry_run_a / _b        static arm poses for a run with the gun carried low (game: arm bones only,
                          blended a <-> b with the stride like the fists): a = left hand forward.
  sprint_fwd (loop 0.62 s) sprint at 5.5 m/s: strong forward lean, long strides, high heel kick,
                          the arms pumping, the gun low in the right hand.

Run headless (Blender 4.5 LTS):
  blender -b --factory-startup -P tools/anim/anim_extra2.py -- [--only a,b] [--out X.glb] [--no-export]
"""
import os
import sys
import math

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "character"))
import bpy  # noqa: E402
from mathutils import Matrix, Vector  # noqa: E402

import animlib as A  # noqa: E402
import animate as AN  # noqa: E402
import anim_extra as AE  # noqa: E402
from animlib import rot, lerp, smooth  # noqa: E402

FPS = 30
PROJECT = os.path.abspath(os.path.join(HERE, "..", ".."))
GLB_OUT = os.path.join(PROJECT, "assets", "character", "anims_extra2.glb")
X, Y, Z = (1, 0, 0), (0, 1, 0), (0, 0, 1)
FWD, RIGHT, UP = Vector((0, -1, 0)), Vector((-1, 0, 0)), Vector((0, 0, 1))      # character frame
RELAX = AN.RELAX
LOOSE = {"index": (14, 20, 12), "middle": (20, 26, 14), "ring": (24, 28, 15), "pinky": (28, 30, 16)}


# ============================================================================= helpers
def legs(pose, feet, knee_out=0.12):
    """animate.legs with the toe bend the right way round: animate.legs turns the ball bone by
    -toe, which bends heel-up toes down into the floor (the game flips that for the base clips,
    character_model._fix_base_toes); here a heel-up foot keeps its toes flat on the ground."""
    AN.legs(pose, feet, knee_out)
    for s in ("l", "r"):
        pose.set_delta("ball_" + s, rot(X, feet[s][2]))
    pose.fk()


def gun_frame(barrel, grip, up_hint=UP):
    """World gun matrix (X right, Y barrel, Z top) with its grip at `grip`."""
    b = Vector(barrel).normalized()
    u = Vector(up_hint)
    u = (u - b * u.dot(b)).normalized()
    return AE.mat(Matrix((b.cross(u), b, u)).transposed(), grip)


def gun_for_wrist(barrel, wrist, up_hint=UP):
    """Gun matrix whose trigger hand (the idle grip, REF HR_G) has its wrist at `wrist`."""
    G = gun_frame(barrel, Vector((0, 0, 0)), up_hint)
    hr = G @ AE.REF["HR_G"]
    G.translation = Vector(wrist) - hr.translation
    return G


def hang_arm(pose, s, fwd=0.05, out=0.06, down=0.53, curls=RELAX, thumb=(12, 8, 5)):
    """A relaxed arm hanging beside the thigh, the palm toward the body."""
    side = RIGHT if s == "r" else -RIGHT
    S = pose.head("upperarm_" + s)
    wrist = S + FWD * fwd + side * out - UP * down
    pole = S - FWD * 0.35 + side * 0.25 - UP * 0.25
    pose.two_bone("upperarm_" + s, "lowerarm_" + s, wrist, pole)
    f = (wrist - pose.head("lowerarm_" + s)).normalized()
    p = -side + FWD * 0.15
    p = (p - f * p.dot(f)).normalized()
    pose.set_orient("hand_" + s, AE.hand_matrix(s, wrist, f, p).to_3x3())
    pose.fingers(s, curls, thumb=thumb)
    pose.fk()


def gun_arm(pose, G, pole):
    AE.arm_to(pose, "r", G @ AE.REF["HR_G"], pole, AE.GRIP_R, AE.THUMB_R)
    pose.gun = G


# ============================================================================= relaxed stance
def carry_body(pose, t, period=2.0):
    """Standing square to the front (no rifle blade), knees soft, weight a little on the right leg."""
    ph = 2 * math.pi * t / period
    br = math.sin(ph)
    pr = rot(Z, -3.0) @ rot(Y, 1.5) @ rot(X, 2.0)
    sp = [rot(Z, 1.0) @ rot(Y, -0.6) @ rot(X, 1.0), rot(Z, 1.0) @ rot(X, 1.0 + 0.5 * br),
          rot(Z, 1.0) @ rot(X, 0.5 - 0.9 * br)]
    neck = rot(X, -1.5)
    head = rot(X, -3.0 + 0.6 * br) @ rot(Z, 1.0)
    cl = rot(X, 1.2 * br) @ rot(Z, 1.0)
    cr = rot(X, 1.2 * br) @ rot(Z, -1.0)
    pos = AN.PELVIS_REST + Vector((-0.012, 0.0, -0.024 + 0.003 * br))
    AN.set_upper(pose, pos, pr, sp, neck, head, cl, cr)
    feet = {"l": AN.foot_at("l", Vector((0.135, -0.075, 0.008)), 10.0, 0.0),
            "r": AN.foot_at("r", Vector((-0.125, -0.05, 0.008)), -8.0, 0.0)}
    legs(pose, feet, knee_out=0.08)
    return br


def carry_gun(pose, swing=0.0, lift=0.0):
    """The gun low at the right hip: held by its grip, muzzle down-forward (about 40 degrees)."""
    Pf = AE.pelvis_frame(pose)
    P3 = Pf.to_3x3()
    wrist = Pf @ Vector((-0.235, -0.07 - 0.06 * swing, 0.02 + lift))
    b = P3 @ (FWD * math.cos(math.radians(40 - 6 * swing)) - UP * math.sin(math.radians(40 - 6 * swing)) + RIGHT * 0.03)
    G = gun_for_wrist(b, wrist, P3 @ UP)
    return G, Pf @ Vector((-0.45, 0.45, 0.35))


def carry_idle_pose(t):
    pose = A.Pose()
    br = carry_body(pose, t)
    G, pole = carry_gun(pose, lift=0.004 * br)
    gun_arm(pose, G, pole)
    hang_arm(pose, "l", fwd=0.05 + 0.005 * br)
    return pose


def carry_run_pose(swing):
    """swing +1: the left hand forward (the right, with the gun, a little back)."""
    pose = A.Pose()
    carry_body(pose, 0.0)
    G, pole = carry_gun(pose, swing=-0.6 * swing, lift=0.03)
    gun_arm(pose, G, pole)
    u = (swing + 1.0) * 0.5
    side = -RIGHT
    S = pose.head("upperarm_l")
    wrist = S + FWD * lerp(-0.20, 0.24, u) + side * lerp(0.08, -0.02, u) - UP * lerp(0.46, 0.33, u)
    pole_l = S - FWD * 0.35 + side * 0.2 - UP * 0.3
    pose.two_bone("upperarm_l", "lowerarm_l", wrist, pole_l)
    f = (wrist - pose.head("lowerarm_l")).normalized()
    p = (-side - f * (-side).dot(f)).normalized()
    pose.set_orient("hand_l", AE.hand_matrix("l", wrist, f, p).to_3x3())
    pose.fingers("l", LOOSE, thumb=(20, 15, 10))
    pose.fk()
    return pose


# ============================================================================= sprint
SPRINT_T = 0.62
SPRINT_SPEED = 5.5
SPRINT = dict(T=SPRINT_T, speed=SPRINT_SPEED, stance=0.24, lift=0.40, lift_skew=0.6, bob=0.05, drop=0.11,
              lean=16.0, chest_pitch=4.0, front_bias=0.06, strike_pitch=12.0, toeoff_pitch=-46.0,
              swing_pitch=-32.0, dir=(0, -1), foot_yaw={"l": -3.0, "r": 3.0},
              base={"l": (0.085, 0.0, 0.008), "r": (-0.085, 0.0, 0.008)}, knee_out=0.07,
              yaw_osc=6.0, roll_osc=2.0)


def sprint_body(t, P):
    """animate.locomotion_pose's legs and pelvis with the chest square to the front (no rifle blade)."""
    T = P["T"]
    pose = A.Pose()
    beta = P["stance"]
    D = P["speed"] * beta * T
    dirv = Vector((P["dir"][0], P["dir"][1], 0)).normalized()
    feet = {}
    for s in ("l", "r"):
        ph = (t / T + (0.0 if s == "l" else 0.5)) % 1.0
        base = Vector(P["base"][s])
        if ph < beta:
            k = ph / beta
            u = D / 2 + P["front_bias"] - k * D
            h = 0.0
            if k < 0.18:
                pitch = lerp(P["strike_pitch"], 0.0, smooth(k / 0.18))
            elif k < 0.5:
                pitch = 0.0
            else:
                pitch = lerp(0.0, P["toeoff_pitch"], smooth((k - 0.5) / 0.5))
            toe = pitch if pitch < 0 else 0.0
        else:
            k = (ph - beta) / (1 - beta)
            u0, u1 = -D / 2 + P["front_bias"], D / 2 + P["front_bias"]
            u = u0 + (u1 - u0) * (0.5 - 0.5 * math.cos(math.pi * k))
            h = P["lift"] * math.sin(math.pi * min(1.0, k ** P["lift_skew"])) ** 1.1
            pitch = AN.interp_keys([(0.0, P["toeoff_pitch"]), (0.35, P["swing_pitch"]), (0.8, P["strike_pitch"] * 0.4),
                                    (1.0, P["strike_pitch"])], k)
            # (the toes stay bent up until the foot is well clear of the ground)
            toe = AN.interp_keys([(0.0, P["toeoff_pitch"]), (0.2, P["toeoff_pitch"]), (0.5, 0.0), (1.0, 0.0)], k)
        pos = base + dirv * u + Vector((0, 0, h))
        feet[s] = AN.foot_at(s, pos, P["foot_yaw"][s], pitch, toe)
    phl = (t / T) % 1.0
    bob = -P["bob"] * math.cos(4 * math.pi * (phl - beta / 2))
    pyaw = P["yaw_osc"] * -math.cos(2 * math.pi * phl)
    proll = P["roll_osc"] * math.sin(2 * math.pi * phl)
    lean = P["lean"]
    ppos = AN.PELVIS_REST + Vector((0, -0.03, -P["drop"] + bob))
    prot = rot(Z, pyaw) @ rot(Y, proll) @ rot(X, lean * 0.4)
    cy = -pyaw * 1.6                    # the shoulders turn against the hips
    sroll = -proll / 3.0
    sp = [rot(Z, cy * 0.3) @ rot(Y, sroll) @ rot(X, lean * 0.2),
          rot(Z, cy * 0.3) @ rot(Y, sroll) @ rot(X, lean * 0.2),
          rot(Z, cy * 0.4) @ rot(Y, sroll) @ rot(X, lean * 0.2 + P["chest_pitch"])]
    neck = rot(Z, -cy * 0.3) @ rot(X, -lean * 0.35)
    head = rot(Z, -cy * 0.3 - pyaw * 0.4) @ rot(X, -lean * 0.5 - P["chest_pitch"] - 2.0)
    AN.set_upper(pose, ppos, prot, sp, neck, head, rot(Z, -2.0), rot(Z, 2.0))
    legs(pose, feet, knee_out=P["knee_out"])
    return pose


def pump_arm(pose, s, a, gun=False):
    """A sprinter's arm, elbow bent: a = +1 hand forward at chest height, -1 hand back past the hip."""
    side = RIGHT if s == "r" else -RIGHT
    S = pose.head("upperarm_" + s)
    u = (a + 1.0) * 0.5
    if gun:      # the gun hand swings less and stays low and out from the thigh
        wrist = S + FWD * lerp(-0.14, 0.17, u) + side * lerp(0.10, 0.04, u) - UP * lerp(0.44, 0.33, u)
    else:
        wrist = S + FWD * lerp(-0.22, 0.27, u) + side * lerp(0.08, -0.07, u) - UP * lerp(0.40, 0.17, u)
    pole = S - FWD * 0.45 + side * 0.18 - UP * 0.30
    if gun:
        tilt = lerp(62.0, 34.0, u)       # muzzle more down while the hand is back
        b = FWD * math.cos(math.radians(tilt)) - UP * math.sin(math.radians(tilt)) + side * 0.05
        G = gun_for_wrist(b, wrist)
        gun_arm(pose, G, pole)
        return
    pose.two_bone("upperarm_" + s, "lowerarm_" + s, wrist, pole)
    f = (wrist - pose.head("lowerarm_" + s)).normalized()
    p = (-side - f * (-side).dot(f)).normalized()
    pose.set_orient("hand_" + s, AE.hand_matrix(s, wrist, f, p).to_3x3())
    pose.fingers(s, LOOSE, thumb=(25, 18, 10))
    pose.fk()


def sprint_pose(t):
    pose = sprint_body(t, SPRINT)
    a_l = -math.cos(2 * math.pi * (t / SPRINT_T + 0.04))      # the left arm swings with the right leg
    pump_arm(pose, "l", a_l)
    pump_arm(pose, "r", -a_l, gun=True)
    return pose


# ============================================================================= registry / build
ANIMS = [
    # name, frames (last == first for loops), loop, pose fn(t)
    ("carry_idle", 60, True, carry_idle_pose),
    ("carry_run_a", 1, False, lambda t: carry_run_pose(1.0)),
    ("carry_run_b", 1, False, lambda t: carry_run_pose(-1.0)),
    ("sprint_fwd", int(round(SPRINT_T * FPS)), True, sprint_pose),
]


def build(only=None):
    arm = AN.arm
    arm.animation_data_create()
    info = {}
    for name, nframes, loop, fn in ANIMS:
        if only and name not in only:
            continue
        poses = AE.sample(fn, nframes)
        act = A.write_action(name, [AE.copy_B(p) for p in poses], FPS, loop)
        tr = arm.animation_data.nla_tracks.new()
        tr.name = name
        tr.strips.new(name, 0, act)
        tr.mute = True
        info[name] = {"frames": nframes + 1, "seconds": nframes / FPS, "loop": loop, "poses": poses}
        print("built", name, nframes + 1, "frames")
    arm.animation_data.action = None
    return info


def main(argv):
    def arg(name, default=None):
        return argv[argv.index(name) + 1] if name in argv else default
    only = arg("--only")
    only = only.split(",") if only else None
    AE.load_character()
    info = build(only)
    if "--no-export" not in argv:
        AE.strip_for_export(set(info.keys()))
        AE.export(arg("--out", GLB_OUT))
    return info


if __name__ == "__main__":
    main(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
