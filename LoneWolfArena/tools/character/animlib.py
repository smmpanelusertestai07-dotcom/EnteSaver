"""Procedural animation toolkit for the MPFB game_engine rig.

Everything is computed in Blender armature space (character faces -Y, +Z up, character's
left = +X). Limbs are solved with an exact analytic two-bone IK (elbow/knee hinge = local X
axis of the child bone, as in the MPFB rig), hands/feet get explicit orientations, and the
result is written as plain FK quaternion keys (+ pelvis location), i.e. already 'baked'."""
import math
import bpy
from mathutils import Matrix, Vector, Quaternion

ARM = None
REST = {}
PARENT = {}
REL = {}
ORDER = []
LEN = {}
HINGE_LOCAL = {}
HAND0 = {}
FOOT_GEO = {}


def rot(axis, deg):
    return Matrix.Rotation(math.radians(deg), 3, Vector(axis).normalized())


def init(arm):
    global ARM
    ARM = arm
    bones = arm.data.bones
    depth = {}

    def d(b):
        return 0 if b.parent is None else d(b.parent) + 1
    for b in bones:
        REST[b.name] = b.matrix_local.copy()
        PARENT[b.name] = b.parent.name if b.parent else None
        depth[b.name] = d(b)
    ORDER.extend(sorted(REST.keys(), key=lambda n: depth[n]))
    for n in REST:
        p = PARENT[n]
        REL[n] = (REST[p].inverted() @ REST[n]) if p else REST[n].copy()
    for s in ("l", "r"):
        LEN["upperarm_" + s] = (REST["lowerarm_" + s].translation - REST["upperarm_" + s].translation).length
        LEN["lowerarm_" + s] = (REST["hand_" + s].translation - REST["lowerarm_" + s].translation).length
        LEN["thigh_" + s] = (REST["calf_" + s].translation - REST["thigh_" + s].translation).length
        LEN["calf_" + s] = (REST["foot_" + s].translation - REST["calf_" + s].translation).length
        for up, lo in (("upperarm_", "lowerarm_"), ("thigh_", "calf_")):
            xl = REST[lo + s].to_3x3().col[0]
            HINGE_LOCAL[up + s] = (REST[up + s].to_3x3().inverted() @ xl).normalized()
            HINGE_LOCAL[lo + s] = Vector((1, 0, 0))
        # anatomical hand frame at rest (f = wrist->middle knuckle, p = palm normal)
        w = REST["hand_" + s].translation
        f0 = (REST["middle_01_" + s].translation - w).normalized()
        s0 = REST["index_01_" + s].translation - REST["pinky_01_" + s].translation
        s0 = (s0 - f0 * s0.dot(f0)).normalized()
        p0 = s0.cross(f0) if s == "r" else f0.cross(s0)
        HAND0[s] = (f0, p0)
        # foot geometry (rest)
        ankle = REST["foot_" + s].translation.copy()
        ball = REST["ball_" + s].translation.copy()
        heel = Vector((ankle.x, ankle.y + 0.055, 0.0))
        FOOT_GEO[s] = {"ankle": ankle, "ball": ball, "heel": heel}


def frame_from(h_l, Y, n):
    y_l = Vector((0, 1, 0))
    h = (h_l - y_l * h_l.dot(y_l)).normalized()
    L = Matrix((h, y_l, h.cross(y_l))).transposed()
    n2 = (n - Y * n.dot(Y)).normalized()
    W = Matrix((n2, Y, n2.cross(Y))).transposed()
    return W @ L.transposed()


def frame_fp(f, p):
    f = f.normalized()
    p = (p - f * p.dot(f)).normalized()
    return Matrix((f, p, f.cross(p))).transposed()


class Pose:
    def __init__(self):
        self.B = {n: Matrix.Identity(4) for n in REST}
        self.P = {}
        self.fk()

    def fk(self):
        for n in ORDER:
            p = PARENT[n]
            self.P[n] = (self.P[p] @ REL[n] @ self.B[n]) if p else (REL[n] @ self.B[n])

    def head(self, n):
        return self.P[n].translation.copy()

    def tail(self, n):
        return self.P[n] @ Vector((0, ARM.data.bones[n].length, 0))

    def set_delta(self, n, D3):
        R3 = REST[n].to_3x3()
        M = (R3.inverted() @ D3 @ R3).to_4x4()
        M.translation = self.B[n].translation
        self.B[n] = M

    def set_orient(self, n, O3):
        p = PARENT[n]
        Pp = self.P[p].to_3x3() if p else Matrix.Identity(3)
        M = (REL[n].to_3x3().inverted() @ Pp.inverted() @ O3).to_4x4()
        M.translation = self.B[n].translation
        self.B[n] = M

    def set_pelvis(self, pos, D3):
        self.set_delta("pelvis", D3)
        rest_head = REL["pelvis"].translation
        self.B["pelvis"].translation = REL["pelvis"].to_3x3().inverted() @ (Vector(pos) - rest_head)

    def two_bone(self, up, lo, target, pole):
        self.fk()
        S = self.head(up)
        L1, L2 = LEN[up], LEN[lo]
        d = Vector(target) - S
        D = max(1e-4, min(d.length, (L1 + L2) * 0.9995))
        dn = d.normalized()
        pv = Vector(pole) - S
        m = pv - dn * pv.dot(dn)
        if m.length < 1e-6:
            m = Vector((0, -1, 0)) - dn * (-dn.y)
        m.normalize()
        cA = max(-1.0, min(1.0, (L1 * L1 + D * D - L2 * L2) / (2 * L1 * D)))
        A = math.acos(cA)
        E = S + (dn * math.cos(A) + m * math.sin(A)) * L1
        T = S + dn * D
        n = m.cross(dn).normalized()
        self.set_orient(up, frame_from(HINGE_LOCAL[up], (E - S).normalized(), n))
        self.fk()
        self.set_orient(lo, frame_from(HINGE_LOCAL[lo], (T - E).normalized(), n))
        self.fk()
        return E

    def hand_orient(self, s, f1, p1):
        f0, p0 = HAND0[s]
        Q = frame_fp(f1, p1) @ frame_fp(f0, p0).transposed()
        self.fk()
        self.set_orient("hand_" + s, Q @ REST["hand_" + s].to_3x3())
        self.fk()

    def foot_orient(self, s, Q):
        self.fk()
        self.set_orient("foot_" + s, Q @ REST["foot_" + s].to_3x3())
        self.fk()

    def fingers(self, s, curls, thumb=(0.0, 0.0, 0.0), spread=0.0):
        """curls: dict finger -> (deg01, deg02, deg03) curl towards the palm."""
        f0, p0 = HAND0[s]
        k = f0.cross(p0).normalized()
        for fname, (a, b, c) in curls.items():
            for i, ang in zip((1, 2, 3), (a, b, c)):
                self.set_delta("%s_0%d_%s" % (fname, i, s), rot(k, ang))
        # thumb: opposition about the hand axis + flexion of distal joints
        sign = 1.0 if s == "r" else -1.0
        t1, t2, t3 = thumb
        self.set_delta("thumb_01_" + s, rot(f0, -sign * t1) @ rot(k, t1 * 0.3))
        tdir = (REST["thumb_02_" + s].translation - REST["thumb_01_" + s].translation).normalized()
        kt = tdir.cross(p0).normalized()
        self.set_delta("thumb_02_" + s, rot(kt, t2))
        self.set_delta("thumb_03_" + s, rot(kt, t3))


def foot_pose(s, anchor, anchor_pos, yaw, pitch):
    """Foot placement. anchor in {'ball','heel'}; pitch>0 = toes up. Returns (ankle_pos, Q, toe_deg)
    where toe_deg is the ball-bone counter rotation keeping the toes flat for heel-up poses."""
    g = FOOT_GEO[s]
    Q = rot((0, 0, 1), yaw) @ rot((1, 0, 0), -pitch)
    a = g[anchor]
    ankle = Vector(anchor_pos) + Q @ (g["ankle"] - a)
    toe = 0.0
    if anchor == "ball" and pitch < 0:
        toe = pitch     # toes bend up relative to the foot
    return ankle, Q, toe


def lerp(a, b, t):
    return a + (b - a) * t


def smooth(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


# ----------------------------------------------------------------------------- keyframing
def write_action(name, frames_B, fps=30, loop=False):
    """frames_B: list of dict bone->Matrix4 basis. Creates an action with linear keys."""
    arm = ARM
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    if arm.animation_data is None:
        arm.animation_data_create()
    arm.animation_data.action = act
    for pb in arm.pose.bones:
        pb.rotation_mode = 'QUATERNION'
    prevq = {}
    for fi, B in enumerate(frames_B):
        for n, M in B.items():
            pb = arm.pose.bones[n]
            q = M.to_quaternion()
            if n in prevq and prevq[n].dot(q) < 0:
                q.negate()
            prevq[n] = q
            pb.rotation_quaternion = q
            pb.keyframe_insert("rotation_quaternion", frame=fi, group=n)
            if n in ("pelvis",):
                pb.location = M.translation
                pb.keyframe_insert("location", frame=fi, group=n)
    # linear interpolation
    try:
        fcurves = act.fcurves
    except AttributeError:
        fcurves = []
    curves = list(fcurves) if fcurves else []
    if not curves:
        for layer in getattr(act, "layers", []):
            for strip in layer.strips:
                for cb in strip.channelbags:
                    curves.extend(cb.fcurves)
    for fc in curves:
        for kp in fc.keyframe_points:
            kp.interpolation = 'LINEAR'
    act.use_frame_range = True
    act.frame_start = 0
    act.frame_end = len(frames_B) - 1
    act.use_cyclic = loop
    return act
