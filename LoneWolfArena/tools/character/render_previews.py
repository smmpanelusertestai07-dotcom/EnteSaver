"""Render the deliverable previews into assets/character/previews (uses preview_anim.py).
The dark rifle in gameplay previews is a preview-only placeholder parented to hand_r; it is not
part of character.glb."""
import os
import sys
import shutil
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import char_config as CFG

os.makedirs(CFG.PREVIEW_DIR, exist_ok=True)
blend = os.path.join(CFG.WORK, "stage_c.blend")
tmp = os.path.join(CFG.WORK, "prev_tmp")
os.makedirs(tmp, exist_ok=True)


def run(args):
    cmd = [sys.executable, os.path.join(HERE, "preview_anim.py"), "--blend", blend] + args
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout[-2000:], r.stderr[-2000:])
        raise SystemExit("preview failed")


jobs = []
for bid, disp, parts in CFG.BUNDLES:
    out = os.path.join(tmp, "bundle_%s.png" % bid)
    jobs.append((["--items", "idle:0", "--bundle", bid, "--res", "768", "--samples", "32",
                  "--cam", "28,3.1,1.15,0.92", "--out", out], out,
                 os.path.join(CFG.PREVIEW_DIR, "bundle_%s_%s_idle.png" % (bid, disp.replace(" ", "_").lower()))))
out = os.path.join(tmp, "frames.png")
jobs.append((["--items", "run_fwd:0,run_fwd:5,run_fwd:10,run_fwd:15,death:0,death:12,death:24,death:36",
              "--bundle", "default", "--res", "384", "--samples", "20", "--labels", "--out", out], out,
             os.path.join(CFG.PREVIEW_DIR, "anim_run_fwd_and_death_frames.png")))
out = os.path.join(tmp, "lobby.png")
jobs.append((["--items", "lobby_idle:0", "--bundle", "default", "--res", "768", "--samples", "32",
              "--cam", "0,3.0,1.1,0.92", "--norifle", "--out", out], out,
             os.path.join(CFG.PREVIEW_DIR, "lobby_idle_front.png")))
out = os.path.join(tmp, "more.png")
jobs.append((["--items", "run_back:5,run_left:5,run_right:5,crouch_idle:0,crouch_fwd:8,jump:7,victory:15,lobby_idle:60",
              "--bundle", "neon", "--res", "384", "--samples", "20", "--labels", "--out", out], out,
             os.path.join(CFG.PREVIEW_DIR, "anim_other_frames_neon.png")))
out = os.path.join(tmp, "face.png")
jobs.append((["--items", "lobby_idle:0", "--bundle", "default", "--res", "768", "--samples", "40",
              "--cam", "18,0.75,1.66,1.62", "--norifle", "--out", out], out,
             os.path.join(CFG.PREVIEW_DIR, "face_closeup.png")))

procs = []
for args, out, final in jobs:
    procs.append((subprocess.Popen([sys.executable, os.path.join(HERE, "preview_anim.py"), "--blend", blend] + args,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True), out, final))
    if len(procs) >= 2:
        p, o, fnl = procs.pop(0)
        p.communicate()
        shutil.copy(o, fnl)
        print("wrote", fnl)
for p, o, fnl in procs:
    p.communicate()
    shutil.copy(o, fnl)
    print("wrote", fnl)
