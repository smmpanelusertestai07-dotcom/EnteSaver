#!/usr/bin/env python3
"""How good the app's copies are: against their originals, and against what
Google Photos' Storage saver would have made of the same originals.

SavingsBenchTest keeps the app's copy of a sample of the library - the first
files of every kind, and every video longer than 20 minutes - and
run-on-emulator.sh pulls them. This runs on the shard's own runner, which
still has the originals, and for every kept copy:

  - scales the original to the copy's size (bicubic), puts it on the copy's
    frame rate - lined up to within one of its own frames, up to two of the
    copy's frames either way, as a copy may start a frame early or late, or
    keep the odd frames of a 60 fps clip - and measures SSIM, PSNR and, when
    an ffmpeg with libvmaf is at hand, VMAF over the whole clip;
  - makes the reference from the same original the way Storage saver is taken
    to: at most 1080p (1920 on the long side, 1080 on the short), at most
    30 fps, H.264 by libx264 -preset medium at 8 Mbps for 1080p30 and in
    proportion to the pixels per second below that, and measures it the same
    way. Google publishes no bitrate for Storage saver - its help page says
    only that videos above 1080p are resized to 1080p and that 1080p and
    below "look close to the original" - and no measured figure was found, so
    8 Mbps is the stated assumption, set in REFERENCE_KBPS;
  - saves one frame from the middle - original, app, reference side by side,
    at the copy's own pixels - in frames/.

It writes quality-shard<N>.csv: a row for every sample file of the shard,
graded or not, with what happened to the ones that were not (kept as they
were, failed, never pulled).

VMAF: Ubuntu's ffmpeg is built without libvmaf, and Ubuntu packages no VMAF
tool. The imageio-ffmpeg wheel on PyPI carries a static ffmpeg 7.0.2 built
with libvmaf 2.3.0 and its built-in vmaf_v0.6.1 model; it is fetched pinned
to its SHA-256 (not pip-installed: the runner's Python refuses system-wide
installs, and only the binary is needed). If that fails, VMAF is left out
and the CSV says why.

  quality.py --manifest bench-manifest.csv --library bench-library --results bench-out \\
             --keep bench-keep --shard 0 --out bench-out
"""
import argparse
import csv
import glob
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile

# Storage saver: 8 Mbps for 1080p30 H.264 (an assumption, see above).
REFERENCE_KBPS = 8000
REFERENCE_LONG, REFERENCE_SHORT, REFERENCE_FPS = 1920, 1080, 30
WHEEL = ("https://files.pythonhosted.org/packages/a0/2d/43c8522a2038e9d0e7dbdf3a61195ecc31ca576fb1527a528c877e87d973/"
         "imageio_ffmpeg-0.6.0-py3-none-manylinux2014_x86_64.whl")
WHEEL_SHA256 = "c7e46fcec401dd990405049d2e2f475e2b397779df2519b544b8aab515195282"
WHEEL_MEMBER = "imageio_ffmpeg/binaries/ffmpeg-linux-x86_64-v7.0.2"
# The standard frame rates; a measured rate snaps to the nearest.
RATES = [(15, 1), (24000, 1001), (24, 1), (25, 1), (30000, 1001), (30, 1), (50, 1), (60000, 1001), (60, 1),
         (90, 1), (120000, 1001), (120, 1), (240, 1)]
ALIGN_S = 3.0
FIELDS = ["name", "profile", "scene", "label", "status", "kept_file", "src_width", "src_height", "src_fps",
          "src_kbps", "app_width", "app_height", "app_fps", "app_kbps", "app_ssim_y", "app_ssim", "app_psnr_y",
          "app_psnr", "app_vmaf", "app_vmaf_min", "app_vmaf_phone", "ref_width", "ref_height", "ref_fps", "ref_kbps",
          "ref_ssim_y", "ref_ssim", "ref_psnr_y", "ref_psnr", "ref_vmaf", "ref_vmaf_min", "ref_vmaf_phone", "offset",
          "seconds_graded", "frame",
          "vmaf_tool", "took_s"]


def has_vmaf(ffmpeg):
    try:
        out = subprocess.run([ffmpeg, "-hide_banner", "-filters"], capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return re.search(r"\slibvmaf\s", out) is not None


def version_of(ffmpeg):
    try:
        out = subprocess.run([ffmpeg, "-hide_banner", "-version"], capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return "?"
    m = re.search(r"ffmpeg version (\S+)", out)
    return m.group(1) if m else "?"


def vmaf_tool(choice, work):
    """(ffmpeg with libvmaf or None, what it is or why there is none)."""
    if choice == "off":
        return None, "none: turned off"
    if choice != "auto":
        if has_vmaf(choice):
            return choice, f"ffmpeg {version_of(choice)} given"
        return None, f"none: {choice} has no libvmaf"
    if has_vmaf("ffmpeg"):
        return "ffmpeg", f"the runner's ffmpeg {version_of('ffmpeg')}"
    dest = os.path.join(work, "vmaf-ffmpeg")
    try:
        wheel = os.path.join(work, "imageio_ffmpeg.whl")
        with urllib.request.urlopen(WHEEL, timeout=180) as r, open(wheel, "wb") as fh:
            shutil.copyfileobj(r, fh)
        with open(wheel, "rb") as fh:
            digest = hashlib.sha256(fh.read()).hexdigest()
        if digest != WHEEL_SHA256:
            return None, f"none: the imageio-ffmpeg wheel's SHA-256 was {digest}, not the pinned one"
        with zipfile.ZipFile(wheel) as z, z.open(WHEEL_MEMBER) as src, open(dest, "wb") as out:
            shutil.copyfileobj(src, out)
        os.chmod(dest, os.stat(dest).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        os.remove(wheel)
    except (OSError, KeyError, zipfile.BadZipFile) as e:
        return None, f"none: the runner's ffmpeg has no libvmaf and the imageio-ffmpeg wheel could not be used ({e})"
    if not has_vmaf(dest):
        return None, "none: the runner's ffmpeg has no libvmaf, nor has the imageio-ffmpeg wheel's"
    return dest, f"ffmpeg {version_of(dest)} from the imageio-ffmpeg 0.6.0 wheel (libvmaf, vmaf_v0.6.1)"


def probe(path):
    """The video as shown: width and height after rotation, frame rate,
    length, and the video track's own bitrate (from its packets)."""
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                          "stream=width,height,avg_frame_rate,r_frame_rate:stream_side_data=rotation:"
                          "stream_tags=rotate:format=duration", "-of", "json", path],
                         capture_output=True, text=True, check=True).stdout
    d = json.loads(out)
    st = d["streams"][0]
    rot = 0
    for sd in st.get("side_data_list", []):
        if "rotation" in sd:
            rot = int(float(sd["rotation"]))
    rot = rot or int(st.get("tags", {}).get("rotate", 0) or 0)
    w, h = int(st["width"]), int(st["height"])
    if abs(rot) % 180 == 90:
        w, h = h, w
    sizes = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=size",
                            "-of", "csv=p=0", path], capture_output=True, text=True, check=True).stdout.split()
    dur = float(d["format"].get("duration") or 0)
    kbps = sum(int(s) for s in sizes if s.isdigit()) * 8 / dur / 1000 if dur > 0 else 0.0
    return dict(width=w, height=h, rate=snap(st.get("avg_frame_rate"), st.get("r_frame_rate")), duration=dur,
                kbps=kbps)


def snap(avg, nominal):
    """The standard frame rate nearest the measured one, as (num, den)."""
    def val(s):
        try:
            n, d = (s or "0/1").split("/")
            return float(n) / float(d) if float(d) else 0.0
        except ValueError:
            return 0.0
    fps = val(avg) or val(nominal) or 30.0
    return min(RATES, key=lambda r: abs(r[0] / r[1] - fps))


def rate_str(r):
    return f"{r[0]}/{r[1]}" if r[1] != 1 else str(r[0])


def rate_val(r):
    return r[0] / r[1]


def reference_size(w, h):
    """Storage saver's size: within 1920 x 1080 either way round, aspect kept, even."""
    long_side, short_side = max(w, h), min(w, h)
    k = min(1.0, REFERENCE_LONG / long_side, REFERENCE_SHORT / short_side)
    rw, rh = round(w * k), round(h * k)
    return max(2, rw - rw % 2), max(2, rh - rh % 2)


def make_reference(src, dest, s):
    w, h = reference_size(s["width"], s["height"])
    rate = s["rate"] if rate_val(s["rate"]) <= REFERENCE_FPS + 0.5 else (REFERENCE_FPS, 1)
    kbps = max(200, round(REFERENCE_KBPS * (w * h * rate_val(rate)) / (1920 * 1080 * 30)))
    vf = f"scale={w}:{h}:flags=bicubic" + (f",fps={rate_str(rate)}" if rate != s["rate"] else "") + ",format=yuv420p"
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", src, "-an", "-vf", vf,
                    "-c:v", "libx264", "-preset", "medium", "-b:v", f"{kbps}k", "-profile:v", "high", dest],
                   check=True)
    return kbps


def shifts_for(d, s):
    """The ways to line the copy up with its original: (copy frames to drop,
    original frames to drop), for every shift of up to two copy frames either
    way in steps of one original frame - so a copy that kept the odd frames
    of a 60 fps clip, or every fourth of a 120 fps one, can be matched."""
    per = max(1, round(rate_val(s["rate"]) / rate_val(d["rate"])))
    out = []
    for j in range(-2 * per, 2 * per + 1):
        a = 0 if j >= 0 else -(j // per)  # whole copy frames, rounded up
        out.append((a, a * per + j))
    return out


def drop(n):
    return f",trim=start_frame={n},setpts=PTS-STARTPTS" if n else ""


def best_shift(ffmpeg, dist, src, d, s, dur):
    """The (copy, original) frames to drop that give the highest SSIM over the first seconds."""
    shifts = shifts_for(d, s)
    n = len(shifts)
    r = rate_str(d["rate"])
    g = [f"[0:v]setpts=PTS-STARTPTS,fps={r},split={n}" + "".join(f"[c{i}]" for i in range(n)),
         f"[1:v]setpts=PTS-STARTPTS,scale={d['width']}:{d['height']}:flags=bicubic,split={n}" +
         "".join(f"[o{i}]" for i in range(n))]
    for i, (a, b) in enumerate(shifts):
        g.append(f"[c{i}]null{drop(a)},trim=duration={min(ALIGN_S, dur):.3f},format=yuv420p[cc{i}]")
        g.append(f"[o{i}]null{drop(b)},fps={r},format=yuv420p[oo{i}]")
        g.append(f"[cc{i}][oo{i}]ssim=shortest=1[s{i}]")
    cmd = [ffmpeg, "-hide_banner", "-nostats", "-t", f"{ALIGN_S + 1:.1f}", "-i", dist, "-t", f"{ALIGN_S + 1:.1f}",
           "-i", src, "-filter_complex", ";".join(g)]
    for i in range(n):
        cmd += ["-map", f"[s{i}]"]
    cmd += ["-f", "null", "-"]
    err = subprocess.run(cmd, capture_output=True, text=True).stderr
    scores = {}
    for m in re.finditer(r"Parsed_ssim_(\d+) @ [^\]]*\] SSIM Y:([0-9.]+)", err):
        scores[int(m.group(1))] = float(m.group(2))
    ordered = [scores[k] for k in sorted(scores)]
    zero = shifts.index((0, 0))
    if len(ordered) != n:
        return 0, 0
    best = max(range(n), key=lambda i: ordered[i])
    # Off zero only when that is clearly better: noise never moves a copy.
    return shifts[best] if ordered[best] > ordered[zero] + 0.002 else (0, 0)


def measure(ffmpeg, vmaf, dist, src, d, s, work, search=True):
    """SSIM, PSNR (and VMAF) of the copy against the original, both on the
    copy's frame rate, the original scaled to the copy's size."""
    tool = vmaf or ffmpeg
    dur = max(0.2, min(d["duration"], s["duration"]) - 0.1)
    a, b = best_shift(tool, dist, src, d, s, dur) if search else (0, 0)
    dur = max(0.2, dur - max(a / rate_val(d["rate"]), b / rate_val(s["rate"])))
    r = rate_str(d["rate"])
    parts = 3 if vmaf else 2
    g = [f"[0:v]setpts=PTS-STARTPTS,fps={r}{drop(a)},trim=duration={dur:.3f},format=yuv420p,split={parts}" +
         "".join(f"[d{i}]" for i in range(parts)),
         f"[1:v]setpts=PTS-STARTPTS{drop(b)},fps={r},scale={d['width']}:{d['height']}:flags=bicubic,"
         f"format=yuv420p,split={parts}" + "".join(f"[r{i}]" for i in range(parts)),
         "[d0][r0]ssim=shortest=1[o0]", "[d1][r1]psnr=shortest=1[o1]"]
    if vmaf:
        log = os.path.join(work, "vmaf.json")
        if os.path.exists(log):
            os.remove(log)
        # Two models in one pass: VMAF's default (a TV at three times its
        # height) and its phone model, for the screen these videos are
        # watched on.
        models = "version=vmaf_v0.6.1\\:name=vmaf|version=vmaf_v0.6.1\\:name=phone\\:enable_transform=true"
        g.append(f"[d2][r2]libvmaf=shortest=1:model='{models}':n_threads={os.cpu_count() or 2}:"
                 "log_fmt=json:log_path=vmaf.json[o2]")
    cmd = [tool, "-hide_banner", "-nostats", "-i", dist, "-i", src, "-filter_complex", ";".join(g)]
    for i in range(parts):
        cmd += ["-map", f"[o{i}]"]
    cmd += ["-f", "null", "-"]
    err = subprocess.run(cmd, capture_output=True, text=True, cwd=work).stderr
    r = dict(offset=f"{a}/{b}", seconds=round(dur, 2))
    m = re.search(r"SSIM Y:([0-9.]+).*All:([0-9.]+)", err)
    r["ssim_y"], r["ssim"] = (float(m.group(1)), float(m.group(2))) if m else ("", "")
    m = re.search(r"PSNR y:([0-9.inf]+).*average:([0-9.inf]+)", err)
    r["psnr_y"], r["psnr"] = (m.group(1), m.group(2)) if m else ("", "")
    r["vmaf"] = r["vmaf_min"] = r["vmaf_phone"] = ""
    if vmaf:
        try:
            with open(os.path.join(work, "vmaf.json")) as fh:
                pooled = json.load(fh)["pooled_metrics"]
            r["vmaf"], r["vmaf_min"] = pooled["vmaf"]["mean"], pooled["vmaf"]["min"]
            r["vmaf_phone"] = pooled["phone"]["mean"]
        except (OSError, KeyError, ValueError):
            pass
    if r["ssim_y"] == "":
        tail = " | ".join(err.strip().splitlines()[-3:])
        raise RuntimeError(f"no SSIM from ffmpeg: {tail}")
    return r


def side_by_side(src, app, ref, d, at, dest, font):
    """One frame from the middle - original, app, reference - at the copy's
    own pixels, a crop from each, side by side."""
    cw, ch = min(d["width"], 640), min(d["height"], 360)
    cw, ch = cw - cw % 2, ch - ch % 2
    x, y = (d["width"] - cw) // 2, (d["height"] - ch) // 2
    crop = f"crop={cw}:{ch}:{x}:{y}"
    labels = ("original", "Ente Saver", "Storage saver reference")
    g = [f"[0:v]scale={d['width']}:{d['height']}:flags=bicubic,{crop}[a]", f"[1:v]{crop}[b]",
         f"[2:v]scale={d['width']}:{d['height']}:flags=bicubic,{crop}[c]"]
    if font:
        for i, k in enumerate("abc"):
            g[i] = g[i][:-3] + (f",drawtext=fontfile={font}:expansion=none:text='{labels[i]}':fontsize=22:"
                                f"fontcolor=white:box=1:boxcolor=black@0.6:x=8:y=8[{k}]")
    g.append("[a][b][c]hstack=inputs=3[v]")
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", f"{at:.2f}", "-i", src,
                    "-ss", f"{at:.2f}", "-i", app, "-ss", f"{at:.2f}", "-i", ref, "-filter_complex", ";".join(g),
                    "-map", "[v]", "-frames:v", "1", "-q:v", "3", dest], check=True)


CLAMP = bytes(min(max(v, 16), 235) for v in range(256))


def frame_digests(path, w, h, dest):
    """The savings benchmark's diagnostics: each decoded frame's time and the
    sum of its brightness plane, as decoded and with every level put inside
    16-235 as the app reads it (VideoQuality logs that sum on the phone), to
    match the frames the app read against these. w x h is the picture's
    size either way round: the plane holds as many bytes."""
    times = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                            "frame=best_effort_timestamp_time", "-of", "csv=p=0", path],
                           capture_output=True, text=True, check=True).stdout.split()
    size = w * h * 3 // 2
    p = subprocess.Popen(["ffmpeg", "-v", "error", "-noautorotate", "-i", path, "-map", "0:v:0",
                          "-pix_fmt", "yuv420p", "-f", "rawvideo", "-"], stdout=subprocess.PIPE)
    with open(dest, "w") as out:
        out.write("frame,time_s,y_sum,y_sum_16_235\n")
        i = 0
        while True:
            frame = p.stdout.read(size)
            if len(frame) < size:
                break
            t = times[i].split(",")[0] if i < len(times) else ""
            y = frame[:w * h]
            out.write(f"{i},{t},{sum(y)},{sum(y.translate(CLAMP))}\n")
            i += 1
    p.wait()


def find_font():
    for path in ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/dejavu/DejaVuSans.ttf"):
        if os.path.isfile(path):
            return path
    return None


def read_csv(path):
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--library", required=True, help="the shard's made videos (library.py make --out)")
    ap.add_argument("--results", required=True, help="where savings-shard<N>.csv was pulled to")
    ap.add_argument("--keep", required=True, help="where the kept copies were pulled to")
    ap.add_argument("--shard", type=int, required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--work", default="")
    ap.add_argument("--vmaf", default="auto", help="auto, off, or an ffmpeg with libvmaf")
    a = ap.parse_args()
    # ffmpeg runs in the work folder (for VMAF's log), so every path is absolute.
    a.library, a.results, a.keep, a.out = (os.path.abspath(p) for p in (a.library, a.results, a.keep, a.out))
    started = time.time()
    os.makedirs(a.out, exist_ok=True)
    frames_dir = os.path.join(a.out, "frames")
    os.makedirs(frames_dir, exist_ok=True)
    # Outside --out, which is uploaded: the VMAF ffmpeg alone is 80 MB.
    work = os.path.abspath(a.work) if a.work else tempfile.mkdtemp(prefix="bench-quality-")
    os.makedirs(work, exist_ok=True)
    library = {r["name"]: r for r in read_csv(a.manifest)}
    sample = [r for r in library.values() if r.get("keep") == "1" and int(r["shard"]) == a.shard]
    results = {}
    for path in glob.glob(os.path.join(a.results, f"savings-shard{a.shard}.csv")):
        results.update({r["name"]: r for r in read_csv(path)})
    vmaf, tool = vmaf_tool(a.vmaf, work)
    print(f"VMAF: {tool}", flush=True)
    diag = os.environ.get("DIAG") == "true"
    diag_left = 3
    diag_dir = os.path.join(a.out, "diag")
    if diag:
        os.makedirs(diag_dir, exist_ok=True)
    font = find_font()
    rows = []
    for m in sorted(sample, key=lambda r: r["name"]):
        t0 = time.time()
        row = {k: "" for k in FIELDS}
        row.update(name=m["name"], profile=m["profile"], scene=m["scene"], label=m["label"], vmaf_tool=tool)
        res = results.get(m["name"])
        src = os.path.join(a.library, m["folder"], m["name"])
        if m.get("in_gallery") == "0":
            row["status"] = "not in the gallery (.nomedia)"
        elif not res:
            row["status"] = "not measured"
        elif res.get("state") != "STAGED":
            row["status"] = "failed: " + (res.get("skip_reason") or res.get("kept_reason") or res.get("state", ""))
        elif res.get("kept_reason"):
            row["status"] = f"kept as it was ({res['kept_reason']})"
        elif not res.get("kept_file") or not os.path.isfile(os.path.join(a.keep, res["kept_file"])):
            row["status"] = "copy not pulled"
        elif str(os.path.getsize(os.path.join(a.keep, res["kept_file"]))) != res.get("out_bytes"):
            row["status"] = "copy pulled short"
        elif not os.path.isfile(src):
            row["status"] = "original missing"
        else:
            app = os.path.join(a.keep, res["kept_file"])
            row["kept_file"] = res["kept_file"]
            try:
                s, d = probe(src), probe(app)
                ref = os.path.join(work, "reference.mp4")
                ref_kbps = make_reference(src, ref, s)
                rp = probe(ref)
                got = measure("ffmpeg", vmaf, app, src, d, s, work)
                if diag and diag_left > 0 and os.path.exists(os.path.join(work, "vmaf.json")):
                    # Pilot runs only: every frame's score, and every frame of
                    # both files, to set beside what the phone read.
                    diag_left -= 1
                    base = os.path.join(diag_dir, re.sub(r"[^A-Za-z0-9._-]", "_", m["name"]))
                    shutil.copyfile(os.path.join(work, "vmaf.json"), base + ".frames.json")
                    frame_digests(src, s["width"], s["height"], base + ".orig.csv")
                    frame_digests(app, d["width"], d["height"], base + ".copy.csv")
                # The reference is made from the original here, frame for frame.
                want = measure("ffmpeg", vmaf, ref, src, rp, s, work, search=False)
                shot = os.path.join(frames_dir, re.sub(r"[^A-Za-z0-9._-]", "_", m["name"]) + ".jpg")
                try:
                    side_by_side(src, app, ref, d, min(d["duration"], s["duration"]) / 2, shot, font)
                    row["frame"] = os.path.basename(shot)
                except subprocess.CalledProcessError:
                    pass
                row.update(status="graded", src_width=s["width"], src_height=s["height"],
                           src_fps=f"{rate_val(s['rate']):.3f}", src_kbps=f"{s['kbps']:.0f}",
                           app_width=d["width"], app_height=d["height"], app_fps=f"{rate_val(d['rate']):.3f}",
                           app_kbps=f"{d['kbps']:.0f}", ref_width=rp["width"], ref_height=rp["height"],
                           ref_fps=f"{rate_val(rp['rate']):.3f}", ref_kbps=f"{rp['kbps']:.0f}",
                           offset=got["offset"], seconds_graded=got["seconds"])
                for side, r in (("app", got), ("ref", want)):
                    for k in ("ssim_y", "ssim", "psnr_y", "psnr", "vmaf", "vmaf_min", "vmaf_phone"):
                        v = r[k]
                        row[f"{side}_{k}"] = f"{v:.4f}" if isinstance(v, float) else v
                print(f"{m['name']}: app SSIM {row['app_ssim_y']} PSNR {row['app_psnr_y']} VMAF {row['app_vmaf']} "
                      f"(phone {row['app_vmaf_phone']}) "
                      f"at {row['app_kbps']} kbps | Storage saver SSIM {row['ref_ssim_y']} PSNR {row['ref_psnr_y']} "
                      f"VMAF {row['ref_vmaf']} at {row['ref_kbps']} kbps (asked {ref_kbps})", flush=True)
            except (subprocess.CalledProcessError, RuntimeError, KeyError, ValueError, IndexError) as e:
                row["status"] = f"could not grade: {str(e)[:200]}"
        row["took_s"] = f"{time.time() - t0:.0f}"
        if row["status"] != "graded":
            print(f"{m['name']}: {row['status']}", flush=True)
        rows.append(row)
    shutil.rmtree(work, ignore_errors=True)
    out = os.path.join(a.out, f"quality-shard{a.shard}.csv")
    with open(out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(rows)
    graded = sum(1 for r in rows if r["status"] == "graded")
    print(f"graded {graded} of {len(rows)} sample files in {(time.time() - started) / 60:.1f} minutes -> {out}")


if __name__ == "__main__":
    sys.exit(main())
