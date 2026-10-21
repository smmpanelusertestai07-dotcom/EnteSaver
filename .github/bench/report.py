#!/usr/bin/env python3
"""What the savings benchmark measured, scaled back up to the real library.

Each video was made shorter than the one it stands for, at the same
resolution, frame rate, codec and bitrate, so the app's copy of the short file
is in the same proportion to it as its copy of the long one would be. This
puts every measured file back at its real length, adds the library up by kind
of video, sets the result against the owner's old target (46 GB down to under
10 GB) and against Google Photos' Storage saver, and writes:

  summary.txt   the verdict, the totals and the tables (also the job summary)
  per-file.csv  every video: real size before and after, and what happened
  summary.json  the same totals, for anything that reads them

Ente Saver 17.0 measures every copy it keeps. A copy keeps its original's
codec, size, frame rate, sound, date and place, as in 16.0, but its bitrate
is no longer worked out from a formula. The phone makes a copy, scores it
against its original with VMAF on 6 to 12 frames from across the clip
(VideoQuality in the app) and makes it again at a rate read from the score
(QualitySearch), three copies at most, and keeps the smallest that scores 87
or more: the target, 86 on VMAF's default model (98 on its phone model), and
a margin of 1 for reading only some of the frames. A video none of whose
copies gets there at no more than 0.85 of its source's picture rate and 0.9
of its size stays as it is (quality_kept), and so does one whose frames
cannot be read (quality_unread). How the kept copy measured is in the savings
CSV's encoder column - compressed_tuned_cbr;vmaf=87.4;low=80.2;phone=98.9;
try=2: the phone's VMAF, its lowest moment, VMAF's phone model and the try
the copy came from. Results from before 17.0 have none of these, and the
lines that need them say so.

An emulator has no encoder chip: its software encoders stand in for a
phone's (-e softwareEncoders true, which savings-bench.yml passes), and the
app scores its copies there as it does on a phone. Those encoders cannot
write everything a phone's chip does - Android's software HEVC encoder takes
512x512 at most, its H.264 encoder 2048x2048 and not 1080p at 60 or 120 fps
- so on the emulator a 4K clip, a 60 or 120 fps clip, a tall screen
recording or an HEVC clip at its own size stays as it is (chip_cannot_keep).
What a phone's chip would make of them is estimated, and kept apart from the
measurement; the estimate is for a phone like the Realme 11 Pro 5G, whose
chip writes H.264 and HEVC at these sizes. A camera's clip is given the
picture rate the emulator's copies of camera clips in the same scene came out
at (the median; over every scene where its own has none), scaled to its own
size, frame rate and codec the way the app's BitrateCalc scales a rate: with
the pixel rate to the power 0.75, and H.264 at 1.45 times HEVC. That takes a
chip to need what Android's software H.264 encoder needed for the same score,
and HEVC what the app's rule says, neither of which is measured here. The
clip stays whole where that rate is not under 0.85 of its source's picture
rate, or the copy would weigh more than 0.9 of the original. A screen
recording, a game, an HDR clip or a forward has no measured kind of its own
to go by, so it is counted whole, and the report says how many and how much
that is.

Storage saver: what Google Photos' Storage saver would make of each video,
from the manifest's own rates, under the benchmark's stated assumption
(quality.py's REFERENCE_KBPS; Google publishes no bitrate): at most 1080p
and 30 fps, H.264 at 8 Mbps for 1080p30 and in proportion to the pixels per
second below that, never more than the source's own picture rate, and sound
at most 128 kbps. Unlike the app, it turns 4K into 1080p and 60 or 120 fps
into 30.

Kept the same: every copy the emulator made is read back, as the app reads
it, against its original - codec, size, rotation, frames, sound, date and
place - and the report says how many kept each.

The quality of the copies comes from quality.py, which graded a sample of
them on the shard runners - SSIM, PSNR and VMAF over every frame against the
original, beside a Storage saver reference made from the same original - and
is reported by kind and by scene, beside the app's own score for the same
copy, so the phone's reading can be set against the benchmark's.

Android's quality floor: from Android 12 a phone raises any VBR encode below
its own table (QualityFloor in the app), and the emulator's H.264 encoder has
no CBR, the mode the app writes in to stay clear of it on a chip that has it.
run-on-emulator.sh switches the floor off, so the copies come out at the
rates the app asks for, as they do from such a chip; the device lines say
whether that took.

The 20-minute limit: the app gives one video at most 20 minutes for all its
copies and their scores; one that runs out of time keeps the smallest copy
that reached the target by then, or stays as it is. How long a real phone
takes depends on its chip, so the effect is shown at a few speeds, counting a
video that runs out of time as kept whole.
"""
import argparse
import csv
import glob
import json
import os
import statistics
from collections import Counter, OrderedDict

# How the app scales a rate with the picture - by its pixel rate (width x
# height x frames a second) against 1080p30, to the power SCALE_EXPONENT, and
# H.264 at H264_FACTOR times HEVC - and the most a copy may be, as
# app/src/main/kotlin/app/entesaver/core/logic/BitrateCalc.kt defines them:
# a copy carries no more than MAX_OF_SOURCE of its source's picture rate and
# weighs no more than MAX_COPY_SHARE of its source, or the video stays as it is.
REF_PIXEL_RATE, SCALE_EXPONENT = 1920 * 1080 * 30, 0.75
CODEC_FACTOR = {"HEVC": 1.0, "H264": 1.45}
MAX_OF_SOURCE, MAX_COPY_SHARE = 0.85, 0.9
# QualityTarget.kt: the VMAF a copy must reach (98 on VMAF's phone model), the
# margin the search aims above it for reading only some of the frames, and the
# most copies made of one clip.
TARGET_VMAF, TARGET_PHONE, MARGIN, MAX_TRIES = 86.0, 98.0, 1.0, 3
SEARCH_VMAF = TARGET_VMAF + MARGIN
# AudioPlan: a track up to these rates is copied; a heavier AAC one is
# written again as AAC-LC at the lower ones.
KEEP_AUDIO = {1: 96_000, 2: 160_000}
AUDIO_AIM = {1: 64_000, 2: 128_000}
BUDGET_S = 20 * 60
# How fast a phone makes and scores a video's copies, as a multiple of playing
# the video: 0.5 takes twice its length, 2 half.
SPEEDS = (0.5, 1.0, 2.0)
GB = 1e9
# The owner's old target: the 46 GB library under 10 GB.
TARGET_GB = 10.0
# A copy is as good as Storage saver's when it is no more than this below it.
VMAF_SLACK, SSIM_SLACK = 1.0, 0.002
# Storage saver as quality.py takes it (REFERENCE_KBPS, an assumption):
# within 1920 x 1080 either way round and at most 30 fps, 8 Mbps for 1080p30
# and in proportion below that, never under 200 kbps; sound at most 128 kbps.
REFERENCE_KBPS, REFERENCE_LONG, REFERENCE_SHORT, REFERENCE_FPS = 8000, 1920, 1080, 30
REFERENCE_MIN_KBPS, REFERENCE_AUDIO_KBPS = 200, 128
SCENES = OrderedDict([("day", "Daylight camera pan"), ("night", "Night / indoor"), ("motion", "High motion"),
                      ("static", "Mostly static (talking head)"), ("screen", "Screen UI"), ("game", "Gameplay")])
# What a camera films - the phone's own camera, an older phone's, an iPhone's
# sent as a document - which the emulator's copies of camera clips stand for:
# in a camera's scenes, which an older phone's screen recordings are not, and
# not HDR.
CAMERA_GROUPS = {"Camera", "From older phones"}
CAMERA_PROFILES = {"wa_docs_iphone"}
CAMERA_SCENES = ("day", "night", "motion", "static")
WHY = {
    "quality_kept": "no smaller copy measured as looking like the original - most often a forward or download "
                    "another app had already compressed",
    "quality_unread": "its frames could not be read back to measure a copy against it",
    "already_efficient": "its picture was already leaner than the least the app writes",
    "already_optimised": "it already carries Ente Saver's mark",
    "not_smaller": "the copy came out no smaller than the original",
    "encoder_rejected": "no encoder made a copy that passed the app's checks",
    "out_of_time": "its copies could not be made and measured in the time the app allows",
    "probe_failed": "its format could not be read",
    "hdr_not_supported": "HDR this phone cannot write as HDR, so it is kept rather than made SDR",
    "chip_cannot_keep": "this phone's encoder cannot write it in its own codec at its own size and frame rate",
    "codec_kept": "a codec no phone chip writes, which a copy would have to change",
    "container_kept": "a file type other than MP4 or MOV",
    "size_kept": "an odd size, which an encoder cannot write",
    "sound_kept": "sound a copy could not keep the same",
    "tracks_kept": "a track besides one picture and one sound, which a copy would lose",
    "trailer_kept": "a camera's trailer (Samsung), which a copy would lose",
}
# Kept as they were on the emulator only because its software encoders are
# smaller than a phone's chip: a Realme 11 Pro 5G writes these.
EMULATOR_ONLY = {"chip_cannot_keep"}
# How the phone estimate came by a video's size.
AS_MEASURED, ESTIMATED = "as measured", "estimated"
WHOLE_NO_KIND = "counted whole: no measured kind to go by"
WHOLE_NO_CLIP = "counted whole: no camera clip made smaller to go by"
WHOLE_BY_RULE = "kept whole: the rate it would need is not under the app's limits"


def counted(n, word, words=None):
    """A count and its noun: 1 video, 2 videos."""
    return f"{n} {word if n == 1 else words or word + 's'}"


def kind(row):
    return "HEVC" if str(row.get("codec", "")).lower() == "hevc" else "H264"


def upright(row):
    w, h = int(row["width"]), int(row["height"])
    return (h, w) if int(row["rotation"]) in (90, 270) else (w, h)


def pixel_scale(row):
    """BitrateCalc's scaling: the picture's pixel rate against 1080p30, to the power SCALE_EXPONENT."""
    w, h = upright(row)
    return (w * h * float(row["fps"]) / REF_PIXEL_RATE) ** SCALE_EXPONENT


def audio_bps(row):
    """AudioPlan: what the copy's sound comes to."""
    channels = int(row.get("channels") or 0)
    if channels <= 0:
        return 0
    have = float(row.get("audio_kbps") or 0) * 1000
    keep = KEEP_AUDIO.get(channels, 2 * KEEP_AUDIO[2])
    return have if have <= keep else min(have, AUDIO_AIM.get(channels, 2 * AUDIO_AIM[2]))


def reference_size(w, h):
    """Storage saver's size: within 1920 x 1080 either way round, aspect kept, even (as quality.py makes it)."""
    long_side, short_side = max(w, h), min(w, h)
    k = min(1.0, REFERENCE_LONG / long_side, REFERENCE_SHORT / short_side)
    rw, rh = round(w * k), round(h * k)
    return max(2, rw - rw % 2), max(2, rh - rh % 2)


def storage_saver_bytes(row):
    """What Storage saver would make of the video at its real length, from the
    manifest's own rates: its picture at the reference rate for its size and
    frame rate, or at its own when that is less, and its sound at most 128 kbps."""
    rw, rh = reference_size(*upright(row))
    fps = min(float(row["fps"]), REFERENCE_FPS)
    ref_kbps = max(REFERENCE_MIN_KBPS,
                   REFERENCE_KBPS * rw * rh * fps / (REFERENCE_LONG * REFERENCE_SHORT * REFERENCE_FPS))
    video = min(num(row, "video_kbps"), ref_kbps)
    audio = min(num(row, "audio_kbps"), REFERENCE_AUDIO_KBPS) if int(num(row, "channels")) > 0 else 0
    return (video + audio) * 1000 / 8 * float(row["real_s"])


def num(row, key, default=0.0):
    try:
        return float(row.get(key) or default)
    except (TypeError, ValueError):
        return default


def on_device(m):
    """How the app measured the copy it kept, from the savings CSV's encoder
    column (QualityTarget.describe): compressed_tuned_cbr;vmaf=87.4;low=80.2;
    phone=98.9;try=2 is VMAF over the moments the phone read, the lowest of
    them, VMAF's phone model, and the try the copy came from. None for what
    the column does not say - all of it, before 17.0."""
    fields = {}
    for part in str(m.get("encoder") or "").split(";"):
        key, sep, value = part.partition("=")
        if sep:
            fields[key.strip()] = value.strip()

    def read(key, cast):
        try:
            return cast(fields[key])
        except (KeyError, ValueError):
            return None

    return dict(device_vmaf=read("vmaf", float), device_low=read("low", float), device_phone=read("phone", float),
                tries=read("try", int))


def camera_like(row):
    """Whether the video is a camera's own kind of picture, which the
    emulator's copies of camera clips stand for."""
    return ((row.get("group") in CAMERA_GROUPS or row.get("profile") in CAMERA_PROFILES)
            and row.get("scene") in CAMERA_SCENES and row.get("hdr") != "1")


def picture_bps(m, gen_s):
    """The copy's picture rate, from its own video track: its bytes over its length."""
    video = num(m, "out_video_bytes")
    seconds = num(m, "out_duration_ms") / 1000 or gen_s
    return video * 8 / seconds if video > 0 and seconds > 0 else None


def load_results(shards_dir):
    measured, made, devices, quality = {}, {}, [], {}
    for path in glob.glob(os.path.join(shards_dir, "**", "savings-shard*.csv"), recursive=True):
        with open(path, newline="") as fh:
            for r in csv.DictReader(fh):
                measured[r["name"]] = r
    for path in glob.glob(os.path.join(shards_dir, "**", "bench-library-made.csv"), recursive=True):
        with open(path, newline="") as fh:
            for r in csv.DictReader(fh):
                made[r["name"]] = r
    for path in sorted(glob.glob(os.path.join(shards_dir, "**", "device-shard*.txt"), recursive=True)):
        with open(path) as fh:
            devices.append(dict(line.strip().split("=", 1) for line in fh if "=" in line))
    for path in glob.glob(os.path.join(shards_dir, "**", "quality-shard*.csv"), recursive=True):
        with open(path, newline="") as fh:
            for r in csv.DictReader(fh):
                quality[r["name"]] = r
    return measured, made, devices, quality


def mean(values):
    values = [v for v in values if v is not None]
    return statistics.fmean(values) if values else None


def median(values):
    values = [v for v in values if v is not None]
    return statistics.median(values) if values else None


def verdict_of(app, ref, metric):
    """Whether the app's copies are at least as good as Storage saver's."""
    if app is None or ref is None:
        return "-"
    vmaf = metric.startswith("VMAF")
    slack = VMAF_SLACK if vmaf else SSIM_SLACK
    diff = app - ref
    shown = f"{diff:+.1f} {metric}" if vmaf else f"{diff:+.3f} {metric}"
    if diff >= slack:
        return f"better ({shown})"
    if diff >= -slack:
        return f"as good ({shown})"
    return f"worse ({shown})"


def phone_word(v):
    """What a VMAF phone-model score means for someone watching on a phone."""
    if v is None:
        return "-"
    if v >= 93:
        return "like the original"
    if v >= 85:
        return "good"
    if v >= 75:
        return "fair"
    return "visibly worse"


def quality_table(lines, title, groups, device, first="Kind of video"):
    """One row per group of graded copies: the app's scores beside the
    reference's and beside the app's own score for the same copies (device:
    name to the VMAF the phone measured), the verdicts against Storage saver
    on VMAF's default model and on its phone model, and how it looks on a
    phone."""
    lines.append("")
    lines.append(f"### {title}")
    lines.append("")
    lines.append(f"| {first} | Graded | SSIM Y app / ref | PSNR Y app / ref | VMAF app / ref | "
                 "App's own VMAF on the phone | VMAF phone app / ref | Mbps app / ref | "
                 "App at least as good as Storage saver? | App at least as good as Storage saver on a phone? | "
                 "On a phone screen |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---|---|---|")
    out = OrderedDict()
    for label, rows in groups.items():
        graded = [q for q in rows if q.get("status") == "graded"]
        if not graded:
            others = OrderedDict()
            for q in rows:
                others[q.get("status") or "not graded"] = others.get(q.get("status") or "not graded", 0) + 1
            why = ", ".join(f"{k}: {v}" for k, v in others.items()) if others else "no sample"
            lines.append(f"| {label} | 0 | - | - | - | - | - | - | not graded ({why}) | - | - |")
            out[label] = dict(graded=0, not_graded=others)
            continue
        m = {k: mean([num(q, k, None) if q.get(k) not in ("", None, "inf") else None for q in graded])
             for k in ("app_ssim_y", "ref_ssim_y", "app_psnr_y", "ref_psnr_y", "app_vmaf", "ref_vmaf",
                       "app_vmaf_phone", "ref_vmaf_phone", "app_kbps", "ref_kbps")}
        vmaf_all = all(q.get("app_vmaf") and q.get("ref_vmaf") for q in graded)
        metric = "VMAF" if vmaf_all else "SSIM Y"
        app, ref = (m["app_vmaf"], m["ref_vmaf"]) if vmaf_all else (m["app_ssim_y"], m["ref_ssim_y"])
        verdict = verdict_of(app, ref, metric)
        phone_all = all(q.get("app_vmaf_phone") and q.get("ref_vmaf_phone") for q in graded)
        verdict_phone = verdict_of(m["app_vmaf_phone"], m["ref_vmaf_phone"], "VMAF phone") if phone_all else "-"
        own = [device[q["name"]] for q in graded if device.get(q.get("name")) is not None]
        m["device_vmaf"] = mean(own)
        f = lambda v, d: "-" if v is None else f"{v:.{d}f}"
        own_shown = f(m["device_vmaf"], 1) + (f" ({len(own)} of {len(graded)})" if 0 < len(own) < len(graded) else "")
        lines.append(f"| {label} | {len(graded)} | {f(m['app_ssim_y'], 3)} / {f(m['ref_ssim_y'], 3)} | "
                     f"{f(m['app_psnr_y'], 1)} / {f(m['ref_psnr_y'], 1)} | "
                     f"{f(m['app_vmaf'], 1)} / {f(m['ref_vmaf'], 1)} | {own_shown} | "
                     f"{f(m['app_vmaf_phone'], 1)} / {f(m['ref_vmaf_phone'], 1)} | "
                     f"{f(m['app_kbps'] / 1000 if m['app_kbps'] else None, 2)} / "
                     f"{f(m['ref_kbps'] / 1000 if m['ref_kbps'] else None, 2)} | {verdict} | {verdict_phone} | "
                     f"{phone_word(m['app_vmaf_phone'])} |")
        out[label] = dict(graded=len(graded), verdict=verdict, verdict_phone=verdict_phone, device_scored=len(own),
                          **{k: v for k, v in m.items()})
    return out


def same_counts(files):
    """For every copy the emulator made, how many kept each thing the same
    as their original - read back from both files, as the app reads them."""
    checks = OrderedDict([
        ("codec", lambda m: m.get("out_video_mime", "").lower() == m.get("src_video_mime", "").lower()),
        ("size as shown", lambda m: shown(m, "out") == shown(m, "src")),
        ("rotation tag", lambda m: m.get("out_rotation") == m.get("src_rotation")),
        ("every frame (within 2 or 1%)", lambda m: frames_kept(m)),
        ("sound codec", lambda m: m.get("out_audio_mime", "").lower() == m.get("src_audio_mime", "").lower()),
        ("sound channels", lambda m: m.get("out_audio_channels") == m.get("src_audio_channels")),
        ("sound sample rate", lambda m: m.get("out_sample_rate") == m.get("src_sample_rate")),
        ("date filmed", lambda m: m.get("out_date") == m.get("src_date")),
        ("place filmed", lambda m: m.get("out_place") == m.get("src_place")),
    ])
    copies = [f["m"] for f in files if f["reencoded"] and f["m"].get("src_video_mime")]
    out = OrderedDict()
    for label, ok in checks.items():
        kept = sum(1 for m in copies if ok(m))
        out[label] = dict(kept=kept, of=len(copies))
    places = [m for m in copies if m.get("src_place")]
    dates = [m for m in copies if m.get("src_date")]
    out["place filmed"]["with_one"] = sum(1 for m in places if m.get("out_place") == m.get("src_place"))
    out["place filmed"]["of_with_one"] = len(places)
    out["date filmed"]["with_one"] = sum(1 for m in dates if m.get("out_date") == m.get("src_date"))
    out["date filmed"]["of_with_one"] = len(dates)
    return out


def shown(m, side):
    w, h, r = (int(num(m, f"{side}_width")), int(num(m, f"{side}_height")), int(num(m, f"{side}_rotation")))
    return (h, w) if r % 180 else (w, h)


def frames_kept(m):
    a, b = int(num(m, "src_frames")), int(num(m, "out_frames"))
    return a > 0 and abs(a - b) <= max(2, a // 100)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--shards", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    with open(a.manifest, newline="") as fh:
        library = list(csv.DictReader(fh))
    measured, made, devices, quality = load_results(a.shards)

    files = []
    for row in library:
        name = row["name"]
        real_s = float(row["real_s"])
        made_row = made.get(name)
        gen_s = float(made_row["gen_s"]) if made_row else float(row["gen_s"])
        k = real_s / gen_s
        m = measured.get(name)
        src = int(m["src_bytes"]) if m else int(made_row["bytes"]) if made_row else 0
        before = src * k
        state = m["state"] if m else "NOT_MEASURED"
        reason = m["kept_reason"] if m else ""
        if m and state == "STAGED":
            after = int(m["out_bytes"]) * k
            outcome = "kept as it was (" + reason + ")" if reason else "made smaller"
        else:
            after = before
            if not m and row.get("in_gallery") == "0":
                outcome = "not in the gallery (.nomedia)"
            elif not m:
                outcome = "not measured"
            else:
                outcome = "failed: " + (m["skip_reason"] or m["error"] or reason or state)
        reencoded = bool(m) and state == "STAGED" and not reason
        # The share of the standard rate the app's first try asks for, read
        # from how much the clip moves and how dark it is (VideoShare).
        chosen = num(m, "chosen_share", None) if m and m.get("chosen_share") else None
        # Storage saver from the manifest's own rates - and nothing where the
        # run made nothing to stand for the file, as before and after are then.
        saver = storage_saver_bytes(row) if before > 0 else 0.0
        files.append(dict(row=row, m=m or {}, name=name, real_s=real_s, gen_s=gen_s, before=before, after=after,
                          phone=after, saver=saver, estimate=AS_MEASURED, outcome=outcome, reason=reason,
                          reencoded=reencoded, measured=bool(m), chosen=chosen, ms=int(num(m or {}, "ms")),
                          quality=quality.get(name, {}), codec=kind(row),
                          compressed=row.get("already_compressed") == "1", scene=row.get("scene", ""),
                          **on_device(m or {})))

    # For a phone whose chip also writes what the emulator's software
    # encoders cannot: every file the emulator handled as it measured, and a
    # camera's clip it could not write at the picture rate its copies of
    # camera clips in the same scene came out at - as 1080p30 in HEVC, scaled
    # to the clip's own size, frame rate and codec the way BitrateCalc scales
    # a rate, and kept whole where the app would keep it whole.
    norms = OrderedDict((s, []) for s in CAMERA_SCENES)
    for f in files:
        if f["reencoded"] and camera_like(f["row"]):
            bps, scale = picture_bps(f["m"], f["gen_s"]), pixel_scale(f["row"])
            if bps and scale > 0:
                norms[f["scene"]].append(bps / (scale * CODEC_FACTOR[f["codec"]]))
    every = [v for vs in norms.values() for v in vs]
    norm_of = OrderedDict((s, statistics.median(vs) if vs else median(every)) for s, vs in norms.items())
    for f in files:
        if f["reason"] not in EMULATOR_ONLY:
            continue
        row = f["row"]
        if not camera_like(row):
            f["estimate"] = WHOLE_NO_KIND
            continue
        norm = norm_of.get(f["scene"])
        if norm is None:
            f["estimate"] = WHOLE_NO_CLIP
            continue
        video = norm * pixel_scale(row) * CODEC_FACTOR[f["codec"]]
        source = num(row, "video_kbps") * 1000
        est = (video + audio_bps(row)) * f["real_s"] / 8
        if (source > 0 and video >= MAX_OF_SOURCE * source) or est > MAX_COPY_SHARE * f["before"]:
            f["estimate"] = WHOLE_BY_RULE
            continue
        f["phone"], f["estimate"] = est, ESTIMATED

    def totals(sel, key="after"):
        return sum(f["before"] for f in sel), sum(f[key] for f in sel)

    def pct(before, after, digits=0):
        return f"{100 * (before - after) / before:.{digits}f}%" if before else "-"

    b, am = totals(files)
    _, ae = totals(files, "phone")
    _, sv = totals(files, "saver")
    n_measured = sum(1 for f in files if f["measured"])
    copies = [f for f in files if f["reencoded"]]
    n_made = len(copies)
    emulator_only = [f for f in files if f["reason"] in EMULATOR_ONLY]
    eo_b = sum(f["before"] for f in emulator_only)
    how = OrderedDict((key, [f for f in emulator_only if f["estimate"] == key])
                      for key in (ESTIMATED, WHOLE_BY_RULE, WHOLE_NO_CLIP, WHOLE_NO_KIND))
    est_b, est_a = totals(how[ESTIMATED], "phone")
    nk_b = sum(f["before"] for f in how[WHOLE_NO_KIND])
    quality_kept = [f for f in files if f["reason"] == "quality_kept"]
    unread = [f for f in files if f["reason"] == "quality_unread"]
    scored = [f for f in copies if f["device_vmaf"] is not None]
    reached = [f for f in scored if f["device_vmaf"] >= SEARCH_VMAF]
    tries = Counter(f["tries"] for f in copies)
    received = [f for f in files if f["compressed"]]
    rb, ra = totals(received, "phone")
    met, met_measured = ae < TARGET_GB * GB, am < TARGET_GB * GB

    lines = ["## Ente Saver savings benchmark v4 (17.0: every copy measured on the phone)", ""]
    rule = (f"VMAF {SEARCH_VMAF:g} or more on the phone's own reading - the target, {TARGET_VMAF:g} "
            f"({TARGET_PHONE:g} on VMAF's phone model), and a margin of {MARGIN:g} for reading 6 to 12 frames rather "
            f"than every one")
    others = n_measured - n_made
    rest = (f"; the other {counted(others, 'video')} the run reached stayed as "
            f"{'it was' if others == 1 else 'they were'}" if others else "")
    if not copies:
        says = "no copy was kept here, so none was measured against its original"
    elif not scored:
        says = (f"none of the {counted(n_made, 'copy', 'copies')} kept here carries the app's own score, so these "
                f"results cannot show that every copy kept measured {rule}")
    elif len(reached) == n_made:
        says = f"every one of the {n_made} copies kept measured {rule}{rest}"
    else:
        low, none = len(scored) - len(reached), n_made - len(scored)
        says = (f"{len(reached)} of the {n_made} copies kept measured {rule}"
                + (f"; {low} measured less" if low else "")
                + (f"; {none} {'carries' if none == 1 else 'carry'} no score" if none else "") + rest)
    missing = [f for f in files if not f["measured"] and f["before"] == 0]
    whole = [f for f in emulator_only if f["estimate"] != ESTIMATED]
    if met and met_measured:
        target = f"is met: {ae / GB:.2f} GB on the phone estimate, {am / GB:.2f} GB measured on the emulator"
    elif met:
        target = f"is met on the phone estimate ({ae / GB:.2f} GB), not as measured on the emulator ({am / GB:.2f} GB)"
    else:
        target = f"is not met: {ae / GB:.2f} GB on the phone estimate, {(ae - TARGET_GB * GB) / GB:.2f} GB over it"
    lines.append(
        f"**Verdict: {says}.** The library, {b / GB:.2f} GB before: {am / GB:.2f} GB measured on the emulator; "
        f"{ae / GB:.2f} GB estimated for a phone whose chip also writes the {len(emulator_only)} videos "
        f"({eo_b / GB:.2f} GB) the emulator's software encoders cannot"
        + (f" ({len(whole)} of them, {sum(f['before'] for f in whole) / GB:.2f} GB, counted whole in the estimate)"
           if whole else "")
        + f"; {sv / GB:.2f} GB made by Google Photos' "
        f"Storage saver itself, at the 8 Mbps for 1080p30 this benchmark assumes for it. The owner's old target, the "
        f"library under {TARGET_GB:.0f} GB, {target}. Of the phone estimate, {ra / GB:.2f} GB are downloads and "
        f"forwards WhatsApp, Instagram, YouTube or Telegram had already compressed ({rb / GB:.2f} GB before)."
        + (f" {len(missing)} of the {len(files)} videos {'is' if len(missing) == 1 else 'are'} in no shard's results "
           f"here and count for nothing in these figures." if missing else ""))
    lines.append("")
    lines.append(f"- Library: {len(files)} videos, {b / GB:.2f} GB (measured: {n_measured}, copies made here: {n_made})")
    lines.append(f"- Measured on the emulator: {am / GB:.2f} GB after, {(b - am) / GB:.2f} GB saved "
                 f"({pct(b, am, 1)}), with {len(emulator_only)} videos ({eo_b / GB:.2f} GB) its software encoders "
                 f"cannot write kept whole")
    lines.append(f"- Estimate for a phone whose chip also writes those: **{ae / GB:.2f} GB after, "
                 f"{(b - ae) / GB:.2f} GB saved ({pct(b, ae, 1)})**")
    if not emulator_only:
        lines.append("- The emulator's software encoders wrote every video the run reached: nothing is estimated")
    else:
        if every:
            rates = ", ".join(f"{s} {norm_of[s] / 1e6:.2f}" + ("" if norms[s] else " (every scene's)")
                              for s in CAMERA_SCENES)
            text = (f"- How: a camera clip among them is given the picture rate the emulator's {len(every)} copies of "
                    f"camera clips came out at in its scene - the median, as 1080p30 in HEVC: {rates} Mbps - scaled "
                    f"to its own size, frame rate and codec as the app scales a rate, and stays whole where that is "
                    f"not under {MAX_OF_SOURCE:g} of its source's picture rate or its copy would weigh more than "
                    f"{MAX_COPY_SHARE:g} of it. ")
        else:
            text = ("- How: no camera clip was made smaller here, so there is no rate to give the camera clips among "
                    "them, and they are counted whole. ")
        def clips(sel, does, do, what):
            n = len(sel)
            return f"{counted(n, 'camera clip')} ({totals(sel)[0] / GB:.2f} GB) {does if n == 1 else do} {what}"

        parts = []
        if how[ESTIMATED]:
            parts.append(clips(how[ESTIMATED], "comes", "come", f"to {est_a / GB:.2f} GB"))
        if how[WHOLE_BY_RULE]:
            parts.append(clips(how[WHOLE_BY_RULE], "stays", "stay", "whole that way"))
        if how[WHOLE_NO_CLIP]:
            parts.append(clips(how[WHOLE_NO_CLIP], "is", "are", "counted whole"))
        one = len(how[WHOLE_NO_KIND]) == 1
        parts.append(f"{len(how[WHOLE_NO_KIND])} ({nk_b / GB:.2f} GB) - screen recordings, games, HDR and forwards - "
                     f"{'has' if one else 'have'} no measured kind to go by and {'is' if one else 'are'} counted whole")
        lines.append(text + f"Of the {len(emulator_only)}: " + "; ".join(parts))
    lines.append(f"- Google Photos' Storage saver itself, at the 8 Mbps for 1080p30 this benchmark assumes: "
                 f"{sv / GB:.2f} GB after ({pct(b, sv, 1)} smaller) - it also turns 4K into 1080p and 60 or 120 fps "
                 f"into 30, which the app does not")
    lines.append(f"- Stayed whole for quality (quality_kept): {counted(len(quality_kept), 'video')}, "
                 f"{sum(f['before'] for f in quality_kept) / GB:.2f} GB - no smaller copy measured as looking like the "
                 f"original; frames that could not be read (quality_unread): {counted(len(unread), 'video')}, "
                 f"{sum(f['before'] for f in unread) / GB:.2f} GB")
    known = sorted(t for t in tries if t is not None)
    if known:
        said = [f"try {t} for {tries[t]}" for t in known]
        lines.append("- The copy kept came from " + (", ".join(said[:-1]) + " and " if len(said) > 1 else "")
                     + f"{said[-1]}, of the {n_made} kept (at most {MAX_TRIES} copies are made of one video)"
                     + (f"; {tries[None]} {'records' if tries[None] == 1 else 'record'} no try"
                        if tries.get(None) else ""))
    elif copies:
        lines.append(f"- None of the {n_made} copies kept here records the try it came from")
    if scored:
        own = [f["device_vmaf"] for f in scored]
        on_phone = median(f["device_phone"] for f in scored)
        lines.append(f"- The app's own VMAF of the copies kept: median {median(own):.1f} ({min(own):.1f} to "
                     f"{max(own):.1f}), on VMAF's phone model median {'-' if on_phone is None else f'{on_phone:.1f}'}; "
                     f"{len(scored)} of the {n_made} copies carry one")
    elif copies:
        lines.append(f"- None of the {n_made} copies kept here carries the app's own VMAF score")
    speeds = [f["gen_s"] / (f["ms"] / 1000) for f in files if f["reencoded"] and f["ms"] > 0]
    if speeds:
        lines.append(f"- The emulator's software encoders ran at {statistics.median(speeds):.2f} x real time "
                     f"(median, the app's reading of each clip, every copy and every score included); a phone's chip "
                     f"is faster")
    for d in devices[:1]:
        lines.append(f"- Emulator: {d.get('model')} API {d.get('sdk')}, RAM {int(d.get('ram_bytes', 0)) / GB:.1f} GB, "
                     f"tier {d.get('tier')}; software encoders standing in for a chip: "
                     f"{d.get('software_stands_in', 'unknown')}; H.264 at 1080p30: {d.get('h264_1080p30', '?')}, "
                     f"HEVC at 1080p30: {d.get('hevc_1080p30', '?')}, H.264 at 4K30: {d.get('h264_4k30', '?')}, "
                     f"HDR (HLG) in HEVC: {d.get('hdr_hlg_hevc_encode', '?')}, AAC encoder in sync: "
                     f"{d.get('aac_keeps_sync', '?')}")
        shaping = sorted({x.get("quality_floor_shaping", "unknown") for x in devices})
        lines.append(f"- Android's quality floor: applies on this emulator at 1080p: "
                     f"{d.get('quality_floor_1080p', 'unknown')}; switched off for the run "
                     f"(debug.stagefright.enableshaping={', '.join(shaping)}; 0 is off)")

    # Kept the same: read back from every copy made.
    same = same_counts(files)
    lines.append("")
    lines.append("### Kept the same (every copy the emulator made, read back against its original)")
    lines.append("")
    lines.append("| What | Copies that kept it | Of |")
    lines.append("|---|---:|---:|")
    for label, t in same.items():
        extra = ""
        if "of_with_one" in t:
            extra = f" ({t['with_one']} of the {t['of_with_one']} that had one)"
        lines.append(f"| {label} | {t['kept']}{extra} | {t['of']} |")

    def sizes(sel):
        gb, gm = totals(sel)
        _, ge = totals(sel, "phone")
        _, gs = totals(sel, "saver")
        return gb, gm, ge, gs

    def cells(gb, gm, ge, gs):
        return f"{gb / GB:.2f} | {gm / GB:.2f} | {pct(gb, gm)} | {ge / GB:.2f} | {pct(gb, ge)} | {gs / GB:.2f}"

    columns = ("Before GB | After GB (measured on the emulator) | Saved | After GB (phone, est.) | Saved | "
               "Storage saver GB")
    broad = OrderedDict()
    for f in files:
        broad.setdefault(f["row"]["group"], []).append(f)
    groups = OrderedDict()
    for f in files:
        groups.setdefault(f["row"]["label"], []).append(f)
    for title, table in (("Where the videos came from", broad), ("Every kind of video", groups)):
        lines.append("")
        lines.append(f"### {title}")
        lines.append("")
        lines.append(f"| Kind of video | Videos | {columns} |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
        for label, sel in table.items():
            lines.append(f"| {label} | {len(sel)} | {cells(*sizes(sel))} |")
        lines.append(f"| **All** | {len(files)} | {cells(b, am, ae, sv)} |")

    by_scene = OrderedDict((s, []) for s in SCENES)
    for f in files:
        by_scene.setdefault(f["scene"] or "-", []).append(f)
    lines.append("")
    lines.append("### What is in the picture (the manifest's scene column)")
    lines.append("")
    lines.append(f"| Scene | Videos | Real hours | {columns} |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
    scene_rows = OrderedDict()
    for sc, sel in by_scene.items():
        if not sel:
            continue
        gb, gm, ge, gs = sizes(sel)
        hours = sum(f["real_s"] for f in sel) / 3600
        scene_rows[sc] = dict(videos=len(sel), hours=hours, before=gb, after_measured=gm, after_phone_est=ge,
                              storage_saver=gs)
        lines.append(f"| {SCENES.get(sc, sc)} | {len(sel)} | {hours:.1f} | {cells(gb, gm, ge, gs)} |")
    lines.append(f"| **All** | {len(files)} | {sum(f['real_s'] for f in files) / 3600:.1f} | {cells(b, am, ae, sv)} |")

    lines.append("")
    lines.append("### The 20-minute limit (a video gets at most 20 minutes for all its copies; one that runs out of "
                 "time is counted as kept as it is)")
    lines.append("")
    lines.append("| Making and scoring its copies takes | Videos that would run out of time | Saved (phone, est.) |")
    lines.append("|---|---:|---:|")
    speed_rows = {}
    for speed in SPEEDS:
        late = {id(f) for f in files if f["phone"] < f["before"] and f["real_s"] / speed > BUDGET_S}
        left = sum(f["before"] if id(f) in late else f["phone"] for f in files)
        speed_rows[speed] = dict(late=len(late), saved=b - left)
        lines.append(f"| {1 / speed:g}x the video's length | {len(late)} | {(b - left) / GB:.2f} GB |")

    kept = OrderedDict()
    for f in files:
        if f["outcome"] == "made smaller":
            continue
        key = f["outcome"]
        if key.startswith("kept as it was ("):
            key = key[len("kept as it was ("):-1]
        t = kept.setdefault(key, dict(videos=0, before=0.0))
        t["videos"] += 1
        t["before"] += f["before"]
    lines.append("")
    lines.append("### Kept as they were on the emulator, and why")
    lines.append("")
    lines.append("| Why | Videos | Share of videos | GB | Share of the library | What it means |")
    lines.append("|---|---:|---:|---:|---:|---|")
    for key, t in sorted(kept.items(), key=lambda kv: -kv[1]["before"]):
        means = WHY.get(key, "in a folder no gallery sees (WhatsApp's Sent)" if key.startswith("not in the gallery")
                        else "the run did not reach it" if key == "not measured" else "")
        if key in EMULATOR_ONLY:
            means += (" - here the emulator's software encoders; a phone's chip writes them (in the phone estimate: "
                      "camera clips estimated, the rest counted whole)")
        lines.append(f"| {key} | {t['videos']} | {100 * t['videos'] / len(files):.0f}% | {t['before'] / GB:.2f} | "
                     f"{100 * t['before'] / b:.0f}% | {means} |")

    device_of = {f["name"]: f["device_vmaf"] for f in files if f["device_vmaf"] is not None}
    calibration = dict(copies=0)
    if quality:
        by_kind = OrderedDict()
        for f in files:
            if f["quality"]:
                by_kind.setdefault(f["row"]["label"], []).append(f["quality"])
        q_kind = quality_table(lines, "How good the copies are, by kind (a sample, graded against the original)",
                               by_kind, device_of)
        by_scene_q = OrderedDict()
        for f in files:
            if f["quality"]:
                by_scene_q.setdefault(SCENES.get(f["scene"], f["scene"]), []).append(f["quality"])
        q_scene = quality_table(lines, "How good the copies are, by scene", by_scene_q, device_of, first="Scene")
        graded = [q for q in quality.values() if q.get("status") == "graded"]
        tools = sorted({q.get("vmaf_tool", "") for q in quality.values() if q.get("vmaf_tool")})
        lines.append("")
        lines.append(f"{len(graded)} copies graded of {len(quality)} sampled. How: each copy's original is put on the "
                     "copy's size and frame rate (the same ones, now), lined up to within one of its own frames, and "
                     "the two are compared over the whole clip: SSIM and PSNR on brightness (Y), VMAF (vmaf_v0.6.1) "
                     "and VMAF's phone model (a phone held at arm's length: 93 and up looks like the original, "
                     "85-93 good, 75-85 fair). The reference is the same original at most 1080p and 30 fps, H.264 by "
                     "libx264 -preset medium at 8 Mbps for 1080p30 and in proportion below that - a yardstick for "
                     "Google Photos' Storage saver, whose bitrate Google does not publish. The phone's own score is "
                     "the one the app kept the copy by: vmaf_v0.6.1 worked out on the device over 6 to 12 frames from "
                     "across the clip. The copies here were written by the emulator's software encoder, not a "
                     "phone's chip.")
        diffs = [num(q, "app_vmaf") - device_of[q["name"]] for q in graded
                 if q.get("name") in device_of and q.get("app_vmaf") not in ("", None)]
        lines.append("")
        if diffs:
            mid = statistics.median(diffs)
            runs = "agrees with it" if mid == 0 else f"runs {abs(mid):.1f} {'low' if mid > 0 else 'high'} against it"
            lines.append(f"The phone's reading against the benchmark's: over the {len(diffs)} graded copies with the "
                         f"app's own score, the benchmark's VMAF over every frame less the phone's is {mid:+.1f} "
                         f"(median; {min(diffs):+.1f} to {max(diffs):+.1f}) - the phone's own score {runs}.")
            calibration = dict(copies=len(diffs), median=mid, low=min(diffs), high=max(diffs))
        else:
            lines.append("None of the graded copies carries the app's own score, so the phone's reading cannot be set "
                         "against the benchmark's here.")
        lines.append("")
        lines.append("VMAF: " + ("; ".join(tools) if tools else "not run"))
    else:
        q_kind = q_scene = {}
        lines.append("")
        lines.append("No quality results: no shard graded its kept copies.")

    lines.append("")
    outcomes = OrderedDict()
    for f in files:
        key = f["outcome"].split(" (")[0] if f["outcome"].startswith("kept") else f["outcome"]
        outcomes[key] = outcomes.get(key, 0) + 1
    lines.append("Outcomes: " + ", ".join(f"{k}: {v}" for k, v in outcomes.items()))

    def opt(v, fmt):
        return format(v, fmt) if v is not None else ""

    with open(os.path.join(a.out, "summary.txt"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(os.path.join(a.out, "per-file.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["name", "group", "kind", "folder", "real_minutes", "width", "height", "fps", "codec", "video_kbps",
                    "before_mb", "after_mb_measured", "after_mb_phone_est", "after_mb_storage_saver", "outcome",
                    "scene", "already_compressed", "chosen_share", "device_vmaf", "device_low", "device_phone",
                    "tries", "graded", "app_ssim_y", "ref_ssim_y", "app_vmaf", "ref_vmaf", "app_vmaf_phone",
                    "ref_vmaf_phone", "out_video_mime", "out_rotation", "src_rotation", "src_frames", "out_frames",
                    "src_date", "out_date", "src_place", "out_place"])
        for f in files:
            r, q, m = f["row"], f["quality"], f["m"]
            w.writerow([f["name"], r["group"], r["label"], r["folder"], f"{f['real_s'] / 60:.2f}", r["width"],
                        r["height"], r["fps"], r["codec"], r["video_kbps"], f"{f['before'] / 1e6:.1f}",
                        f"{f['after'] / 1e6:.1f}", f"{f['phone'] / 1e6:.1f}", f"{f['saver'] / 1e6:.1f}",
                        f["outcome"], f["scene"], int(f["compressed"]), opt(f["chosen"], ".3f"),
                        opt(f["device_vmaf"], ".1f"), opt(f["device_low"], ".1f"), opt(f["device_phone"], ".1f"),
                        opt(f["tries"], "d"), q.get("status", ""), q.get("app_ssim_y", ""), q.get("ref_ssim_y", ""),
                        q.get("app_vmaf", ""), q.get("ref_vmaf", ""), q.get("app_vmaf_phone", ""),
                        q.get("ref_vmaf_phone", ""), m.get("out_video_mime", ""), m.get("out_rotation", ""),
                        m.get("src_rotation", ""), m.get("src_frames", ""), m.get("out_frames", ""),
                        m.get("src_date", ""), m.get("out_date", ""), m.get("src_place", ""), m.get("out_place", "")])
    with open(os.path.join(a.out, "summary.json"), "w") as fh:
        json.dump(dict(videos=len(files), measured=n_measured, made=n_made, before_bytes=b, after_bytes_measured=am,
                       after_bytes_phone_est=ae, after_bytes_storage_saver=sv,
                       emulator_only_kept=len(emulator_only), emulator_only_bytes=eo_b,
                       phone_estimate=dict(
                           estimated=len(how[ESTIMATED]), estimated_before=est_b, estimated_after=est_a,
                           kept_whole_by_rule=len(how[WHOLE_BY_RULE]),
                           kept_whole_by_rule_bytes=totals(how[WHOLE_BY_RULE])[0],
                           whole_no_camera_clip=len(how[WHOLE_NO_CLIP]),
                           whole_no_camera_clip_bytes=totals(how[WHOLE_NO_CLIP])[0],
                           whole_no_measured_kind=len(how[WHOLE_NO_KIND]), whole_no_measured_kind_bytes=nk_b,
                           camera_bps_as_1080p30_hevc=norm_of, camera_copies={s: len(v) for s, v in norms.items()}),
                       quality_kept=dict(videos=len(quality_kept), bytes=sum(f["before"] for f in quality_kept)),
                       quality_unread=dict(videos=len(unread), bytes=sum(f["before"] for f in unread)),
                       tries={str(t) if t is not None else "unknown": n for t, n in sorted(
                           tries.items(), key=lambda kv: (kv[0] is None, kv[0] or 0))},
                       device_score=dict(scored=len(scored), of=n_made, at_or_over_search_vmaf=len(reached),
                                         search_vmaf=SEARCH_VMAF,
                                         median_vmaf=median(f["device_vmaf"] for f in scored),
                                         lowest_vmaf=min((f["device_vmaf"] for f in scored), default=None),
                                         median_low=median(f["device_low"] for f in scored),
                                         median_phone=median(f["device_phone"] for f in scored)),
                       target=dict(gb=TARGET_GB, met=met, met_measured=met_measured, already_compressed_before=rb,
                                   already_compressed_after=ra),
                       same=same,
                       by_kind={label: dict(zip(("before", "after_measured", "after_phone_est", "storage_saver"),
                                                sizes(sel)), videos=len(sel)) for label, sel in groups.items()},
                       by_scene=scene_rows, kept_as_they_were=kept,
                       quality=dict(by_kind=q_kind, by_scene=q_scene, calibration=calibration),
                       time_limit={str(k): v for k, v in speed_rows.items()}, devices=devices), fh, indent=2)
    print("\n".join(lines))


if __name__ == "__main__":
    main()
