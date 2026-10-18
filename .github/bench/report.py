#!/usr/bin/env python3
"""What the savings benchmark measured, scaled back up to the real library.

Each video was made shorter than the one it stands for, at the same
resolution, frame rate, codec and bitrate, so the app's copy of the short file
is in the same proportion to it as its copy of the long one would be. This
puts every measured file back at its real length, adds the library up by kind
of video, sets the result against the owner's target (46 GB down to 5 GB),
and writes:

  summary.txt   the verdict, the totals and the tables (also the job summary)
  per-file.csv  every video: real size before and after, and what happened
  summary.json  the same totals, for anything that reads them

The quality of the copies comes from quality.py, which graded a sample of
them on the shard runners - SSIM, PSNR and VMAF against the original, beside
a Storage saver reference made from the same original - and is reported by
kind and by scene.

The codec: an emulator has no encoder chip at all. Run with -e hevcSoftware
true (savings-bench.yml does), its software HEVC encoder stands in for the
HEVC chip a phone like the Realme 11 Pro 5G has - but it takes 512x512 at
most, so nearly every clip is measured in H.264, asked for 1.45 times the
bits. What the same copies come to in the other codec is worked out from the
app's own rules and kept apart from the measurement, and the verdict is
given for the HEVC path, the one a Realme 11 Pro 5G takes.

Android's quality floor: from Android 12 a phone raises any VBR encode below
its own table (QualityFloor in the app), and the emulator's H.264 encoder has
no CBR, the mode the app writes in to stay clear of it on a chip that has it.
run-on-emulator.sh switches the floor off, so the copies come out at the
rates the app asks for, as they do from such a chip; the device lines say
whether that took.

The 20-minute limit: the app gives one video at most 20 minutes to encode and
keeps a video that runs out of time as it is. How long a real phone takes
depends on its chip, so the effect is shown at a few speeds.
"""
import argparse
import csv
import glob
import json
import os
import statistics
from collections import OrderedDict

# The app's one video setting (MediaSettings.VIDEO: 1920 on the long side,
# 30 fps), BitrateCalc's standard rates and AudioPlan's sound, as
# app/src/main/kotlin/app/entesaver/core/logic/MediaSettings.kt,
# BitrateCalc.kt and AudioPlan.kt define them.
LONG_SIDE = 1920
FPS_CAP = 30
SLOW_MOTION_FPS = 90.0
AUDIO_BPS = 48_000
REF_HEVC_BPS, REF_PIXEL_RATE, SCALE_EXPONENT = 900_000, 1920 * 1080 * 30, 0.75
CODEC_FACTOR = {"HEVC": 1.0, "H264": 1.45}
CAP_BPS, FLOOR_BPS = 8_000_000, 150_000
COPY_FACTOR = 1.15
BUDGET_S = 20 * 60
# How fast a phone encodes, as a multiple of playing the video: 0.5 takes
# twice its length (what the emulator's software encoder managed), 2 half.
SPEEDS = (0.5, 1.0, 2.0)
GB = 1e9
# The owner's target: the 46 GB library down to 5 GB, and no more than 7.
TARGET_GB, TARGET_LOW_GB = 7.0, 5.0
# A copy is as good as Storage saver's when it is no more than this below it.
VMAF_SLACK, SSIM_SLACK = 1.0, 0.002
SCENES = OrderedDict([("day", "Daylight camera pan"), ("night", "Night / indoor"), ("motion", "High motion"),
                      ("static", "Mostly static (talking head)"), ("screen", "Screen UI"), ("game", "Gameplay")])
WHY = {
    "already_efficient": "it was already as lean as the app would make it, within 15%",
    "already_optimised": "it already carries Ente Saver's mark",
    "not_smaller": "the encoder kept to its target and the copy was still no smaller",
    "encoder_rejected": "no encoder made a copy that passed the app's checks",
    "out_of_time": "it could not be encoded in the time the app allows",
    "probe_failed": "its format could not be read",
    "hdr_not_supported": "HDR this phone cannot encode",
}


def output_dims(w, h, limit):
    long_side = max(w, h)
    if long_side <= limit:
        return w - w % 2, h - h % 2
    scale = limit / long_side
    ow, oh = round(w * scale), round(h * scale)
    return ow - ow % 2, oh - oh % 2


def plan(row, codec, src_bps, share=1.0):
    """What the app does with this video on a phone that writes `codec`:
    (kept_as_is, standard target video bits per second). src_bps is the
    file's own bitrate, sound included, as Android's metadata reader reports
    it; share is the part of the standard rate the app measured the clip to
    need - a clip already as lean as that, within 15%, is kept as it is."""
    w, h, fps = int(row["width"]), int(row["height"]), float(row["fps"])
    if int(row["rotation"]) in (90, 270):
        w, h = h, w
    capped = FPS_CAP if FPS_CAP + 0.5 < fps < SLOW_MOTION_FPS else None
    out_fps = capped or fps
    ow, oh = output_dims(w, h, LONG_SIDE)
    raw = REF_HEVC_BPS * (ow * oh * out_fps / REF_PIXEL_RATE) ** SCALE_EXPONENT * CODEC_FACTOR[codec]
    target = min(max(raw, FLOOR_BPS), CAP_BPS)
    as_is = capped is None and max(w, h) <= LONG_SIDE and src_bps <= target * share * COPY_FACTOR
    return as_is, target


def num(row, key, default=0.0):
    try:
        return float(row.get(key) or default)
    except (TypeError, ValueError):
        return default


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


def verdict_of(app, ref, metric):
    """Whether the app's copies are at least as good as Storage saver's."""
    if app is None or ref is None:
        return "-"
    slack = VMAF_SLACK if metric == "VMAF" else SSIM_SLACK
    diff = app - ref
    shown = f"{diff:+.1f} {metric}" if metric == "VMAF" else f"{diff:+.3f} {metric}"
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


def quality_table(lines, title, groups, first="Kind of video"):
    """One row per group of graded copies: the app's scores beside the
    reference's, the verdict against Storage saver, and how it looks on a
    phone (VMAF's phone model)."""
    lines.append("")
    lines.append(f"### {title}")
    lines.append("")
    lines.append(f"| {first} | Graded | SSIM Y app / ref | PSNR Y app / ref | VMAF app / ref | VMAF phone app / ref | "
                 "Mbps app / ref | App at least as good as Storage saver? | On a phone screen |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---|---|")
    out = OrderedDict()
    for label, rows in groups.items():
        graded = [q for q in rows if q.get("status") == "graded"]
        if not graded:
            others = OrderedDict()
            for q in rows:
                others[q.get("status") or "not graded"] = others.get(q.get("status") or "not graded", 0) + 1
            why = ", ".join(f"{k}: {v}" for k, v in others.items()) if others else "no sample"
            lines.append(f"| {label} | 0 | - | - | - | - | - | not graded ({why}) | - |")
            out[label] = dict(graded=0, not_graded=others)
            continue
        m = {k: mean([num(q, k, None) if q.get(k) not in ("", None, "inf") else None for q in graded])
             for k in ("app_ssim_y", "ref_ssim_y", "app_psnr_y", "ref_psnr_y", "app_vmaf", "ref_vmaf",
                       "app_vmaf_phone", "ref_vmaf_phone", "app_kbps", "ref_kbps")}
        vmaf_all = all(q.get("app_vmaf") and q.get("ref_vmaf") for q in graded)
        metric = "VMAF" if vmaf_all else "SSIM Y"
        app, ref = (m["app_vmaf"], m["ref_vmaf"]) if vmaf_all else (m["app_ssim_y"], m["ref_ssim_y"])
        verdict = verdict_of(app, ref, metric)
        f = lambda v, d: "-" if v is None else f"{v:.{d}f}"
        lines.append(f"| {label} | {len(graded)} | {f(m['app_ssim_y'], 3)} / {f(m['ref_ssim_y'], 3)} | "
                     f"{f(m['app_psnr_y'], 1)} / {f(m['ref_psnr_y'], 1)} | "
                     f"{f(m['app_vmaf'], 1)} / {f(m['ref_vmaf'], 1)} | "
                     f"{f(m['app_vmaf_phone'], 1)} / {f(m['ref_vmaf_phone'], 1)} | "
                     f"{f(m['app_kbps'] / 1000 if m['app_kbps'] else None, 2)} / "
                     f"{f(m['ref_kbps'] / 1000 if m['ref_kbps'] else None, 2)} | {verdict} | "
                     f"{phone_word(m['app_vmaf_phone'])} |")
        out[label] = dict(graded=len(graded), verdict=verdict, **{k: v for k, v in m.items()})
    return out


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
        if m and state == "STAGED":
            after = int(m["out_bytes"]) * k
            outcome = "kept as it was (" + m["kept_reason"] + ")" if m["kept_reason"] else "made smaller"
        else:
            after = before
            if not m and row.get("in_gallery") == "0":
                outcome = "not in the gallery (.nomedia)"
            elif not m:
                outcome = "not measured"
            else:
                outcome = "failed: " + (m["skip_reason"] or m["error"] or m["kept_reason"] or state)
        reencoded = bool(m) and state == "STAGED" and not m["kept_reason"]
        codec = (m.get("codec") or "H264").upper() if m else "H264"
        if codec not in CODEC_FACTOR:
            codec = "H264"
        # How far the encoder landed from the bitrate the app asked of it,
        # measured on this file: carried over to the other codec's estimate.
        # The test reads the copy's video and sound tracks apart; older
        # results give the whole file, less the app's usual sound.
        src_bps = src * 8 / gen_s if src else (float(row["video_kbps"]) + float(row["audio_kbps"])) * 1000
        _, target_used = plan(row, codec, src_bps)
        landed, audio_bps, share = None, AUDIO_BPS, None
        if reencoded:
            out_s = num(m, "out_duration_ms") / 1000 or gen_s
            if num(m, "out_video_bytes") > 0:
                out_bps = num(m, "out_video_bytes") * 8 / out_s
                audio_bps = num(m, "out_audio_bytes") * 8 / out_s
            else:
                out_bps = int(m["out_bytes"]) * 8 / gen_s - AUDIO_BPS
            landed = out_bps / target_used if target_used else None
            share = num(m, "share", None) if m.get("share") else None
        q = quality.get(name, {})
        chosen = num(m, "chosen_share", None) if m and m.get("chosen_share") else None
        files.append(dict(row=row, name=name, real_s=real_s, before=before, after=after, outcome=outcome,
                          reencoded=reencoded, landed=landed, audio_bps=audio_bps, share=share, measured=bool(m),
                          codec=codec, chosen=chosen,
                          src_bps=src_bps, gen_s=gen_s, ms=int(m["ms"]) if m else 0, quality=q,
                          compressed=row.get("already_compressed") == "1", scene=row.get("scene", "")))

    landed_all = [f["landed"] for f in files if f["landed"]]
    landed_typ = statistics.median(landed_all) if landed_all else 1.0
    used = [f["codec"] for f in files if f["reencoded"]]
    measured_codec = max(set(used), key=used.count) if used else "H264"
    other_codec = "H264" if measured_codec == "HEVC" else "HEVC"
    name_of = {"HEVC": "HEVC", "H264": "H.264"}
    mc, oc = name_of[measured_codec], name_of[other_codec]
    other_phone = "a phone without an HEVC chip" if other_codec == "H264" else "a phone with an HEVC chip"

    # The other codec: the app's own decision on a phone that writes it, at
    # the share of the standard rate the copy came out at here (the median
    # for a clip kept as it was).
    for f in files:
        row = f["row"]
        as_is, target = plan(row, other_codec, f["src_bps"], f["landed"] or landed_typ)
        if as_is or not f["measured"]:
            f["after_hevc"] = f["before"]
        else:
            est = (target * (f["landed"] or landed_typ) + f["audio_bps"]) * f["real_s"] / 8
            f["after_hevc"] = est if est < f["before"] else f["before"]
        # HEVC at the rate the app asked for - the share it chose for this
        # clip, read from its frames - which a chip writing in CBR holds to.
        # The emulator's software encoder could not always come down to it;
        # this leaves out how far it overshot. A clip kept for any reason but
        # being lean already is kept here too.
        lean_or_made = f["reencoded"] or f["outcome"] == "kept as it was (already_efficient)"
        if f["chosen"] is None or not lean_or_made:
            f["after_hevc_asked"] = f["after_hevc"] if f["chosen"] is None else f["before"]
        else:
            as_is_a, target_a = plan(row, "HEVC", f["src_bps"], f["chosen"])
            est = (target_a * f["chosen"] + f["audio_bps"]) * f["real_s"] / 8
            f["after_hevc_asked"] = f["before"] if as_is_a or est >= f["before"] else est

    def totals(sel, key="after"):
        before = sum(f["before"] for f in sel)
        after = sum(f[key] for f in sel)
        return before, after

    groups = OrderedDict()
    for f in files:
        groups.setdefault(f["row"]["label"], []).append(f)

    lines = []
    b, af = totals(files)
    _, ah = totals(files, "after_hevc")
    _, aa = totals(files, "after_hevc_asked")
    n_chosen = sum(1 for f in files if f["chosen"] is not None)
    n_measured = sum(1 for f in files if f["measured"])
    n_kept = sum(1 for f in files if f["measured"] and not f["reencoded"])
    received = [f for f in files if f["compressed"]]
    rb, ra = totals(received)
    _, rh = totals(received, "after_hevc")
    lines.append(f"## Ente Saver savings benchmark v3 (measured with {mc}, the codec the app picks on a phone with "
                 f"an HEVC chip)")
    lines.append("")
    # The verdict is for the path a Realme 11 Pro 5G takes: HEVC, written in
    # CBR (the Dimensity 7050's HEVC encoder lists it), which holds the rate
    # the app asks for. Measured when the run measured HEVC; otherwise worked
    # out from the share the app chose for each clip.
    if measured_codec == "HEVC":
        hevc_after, how = af, "measured"
    elif n_chosen:
        hevc_after, how = aa, "an estimate at the rates the app asks for, from the share it chose for each clip"
    else:
        hevc_after, how = ah, f"an estimate worked out from the {mc} copies"
    met = hevc_after <= TARGET_GB * GB
    lines.append(
        f"**Verdict: the owner's target is {b / GB:.0f} GB down to {TARGET_LOW_GB:.0f}-{TARGET_GB:.0f} GB - "
        f"{'met' if met else 'not met'} on a phone whose HEVC chip writes in CBR: {hevc_after / GB:.1f} GB "
        f"({b / hevc_after:.1f} times smaller; {how}).** "
        f"Measured on the emulator ({mc}), the library went from {b / GB:.1f} GB to "
        f"{af / GB:.1f} GB ({100 * (b - af) / b:.0f}% smaller, {b / af:.1f} times smaller); in {oc}, carrying over "
        f"how far the emulator's software encoder overshot the rate it was asked for, {ah / GB:.1f} GB. Of what is "
        f"left after the measured run, {ra / GB:.1f} GB are downloads and forwards that WhatsApp, Instagram, YouTube "
        f"or Telegram had already compressed ({rb / GB:.1f} GB before); the rest, {(af - ra) / GB:.1f} GB, is "
        f"camera videos, screen recordings and other phones' originals.")
    lines.append("")
    lines.append(f"- Library: {len(files)} videos, {b / GB:.2f} GB (measured: {n_measured})")
    lines.append(f"- Measured ({mc}): {af / GB:.2f} GB after, **{(b - af) / GB:.2f} GB saved "
                 f"({100 * (b - af) / b:.1f}%)**")
    lines.append(f"- On {other_phone} ({oc}, estimate): {ah / GB:.2f} GB after, {(b - ah) / GB:.2f} GB saved "
                 f"({100 * (b - ah) / b:.1f}%)")
    if n_chosen:
        lines.append(f"- HEVC at the rates the app asks for (a chip writing in CBR holds them; estimate): "
                     f"{aa / GB:.2f} GB after, {(b - aa) / GB:.2f} GB saved ({100 * (b - aa) / b:.1f}%); "
                     f"the app's chosen share is known for {n_chosen} videos")
    lines.append(f"- Kept as they were (nothing to gain, or failed): {n_kept} videos")
    lines.append(f"- Encoder landed at {landed_typ:.2f} x the standard bitrate for its size (median; "
                 f"the app's per-video choice included)")
    shares = [f["share"] for f in files if f["share"]]
    if shares:
        lines.append(f"- The copies came out at {statistics.median(shares):.2f} x the standard rate (median share, "
                     f"{min(shares):.2f} to {max(shares):.2f})")
    speeds = [f["gen_s"] / (f["ms"] / 1000) for f in files if f["reencoded"] and f["ms"] > 0]
    if speeds:
        lines.append(f"- The emulator's software {mc} encoder ran at {statistics.median(speeds):.2f} x real time "
                     f"(median, the app's own measuring of each clip included); a phone's chip is faster")
    for d in devices[:1]:
        lines.append(f"- Emulator: {d.get('model')} API {d.get('sdk')}, RAM {int(d.get('ram_bytes', 0)) / GB:.1f} GB, "
                     f"tier {d.get('tier')}, software HEVC standing in for a chip: "
                     f"{d.get('hevc_software_stands_in', 'false')} (HEVC at 1080p30: "
                     f"{d.get('hevc_1080p30', 'unknown')})")
        shaping = sorted({x.get("quality_floor_shaping", "unknown") for x in devices})
        lines.append(f"- Android's quality floor: applies on this emulator at 1080p: "
                     f"{d.get('quality_floor_1080p', 'unknown')}; CBR at 1080p30, H.264: "
                     f"{d.get('cbr_h264_1080p30', 'unknown')}, HEVC: {d.get('cbr_hevc_1080p30', 'unknown')}; "
                     f"switched off for the run (debug.stagefright.enableshaping={', '.join(shaping)}; 0 is off)")
    broad = OrderedDict()
    for f in files:
        broad.setdefault(f["row"]["group"], []).append(f)
    for title, table in (("Where the videos came from", broad), ("Every kind of video", groups)):
        lines.append("")
        lines.append(f"### {title}")
        lines.append("")
        lines.append(f"| Kind of video | Videos | Before GB | After GB ({mc}) | Saved | After GB ({oc} est.) | Saved | "
                     f"After GB (HEVC at the asked rate, est.) | Saved |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|")
        for label, sel in table.items():
            gb, ga = totals(sel)
            _, gh = totals(sel, "after_hevc")
            _, gq = totals(sel, "after_hevc_asked")
            pct = lambda x: f"{100 * (gb - x) / gb:.0f}%" if gb else "-"
            lines.append(f"| {label} | {len(sel)} | {gb / GB:.2f} | {ga / GB:.2f} | {pct(ga)} | {gh / GB:.2f} | "
                         f"{pct(gh)} | {gq / GB:.2f} | {pct(gq)} |")
        lines.append(f"| **All** | {len(files)} | {b / GB:.2f} | {af / GB:.2f} | {100 * (b - af) / b:.0f}% | "
                     f"{ah / GB:.2f} | {100 * (b - ah) / b:.0f}% | {aa / GB:.2f} | {100 * (b - aa) / b:.0f}% |")

    # The library's pictures: what the scene column says, and what the app
    # saved on each.
    by_scene = OrderedDict((s, []) for s in SCENES)
    for f in files:
        by_scene.setdefault(f["scene"] or "-", []).append(f)
    lines.append("")
    lines.append("### What is in the picture (the manifest's scene column)")
    lines.append("")
    lines.append(f"| Scene | Videos | Real hours | Before GB | After GB ({mc}) | Saved | After GB ({oc} est.) |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|")
    scene_rows = OrderedDict()
    for s, sel in by_scene.items():
        if not sel:
            continue
        gb, ga = totals(sel)
        _, gh = totals(sel, "after_hevc")
        hours = sum(f["real_s"] for f in sel) / 3600
        scene_rows[s] = dict(videos=len(sel), hours=hours, before=gb, after_h264=ga, after_hevc=gh)
        lines.append(f"| {SCENES.get(s, s)} | {len(sel)} | {hours:.1f} | {gb / GB:.2f} | {ga / GB:.2f} | "
                     f"{100 * (gb - ga) / gb:.0f}% | {gh / GB:.2f} |")

    lines.append("")
    lines.append("### The 20-minute limit (a video that cannot be encoded in 20 minutes is kept as it is)")
    lines.append("")
    lines.append(f"| Encoding takes | Videos that would run out of time | Saved ({mc}) | Saved ({oc} est.) |")
    lines.append("|---|---:|---:|---:|")
    speed_rows = {}
    for speed in SPEEDS:
        late = [f for f in files if f["reencoded"] and f["real_s"] / speed > BUDGET_S]
        late_ids = {id(f) for f in late}
        a1 = sum(f["before"] if id(f) in late_ids else f["after"] for f in files)
        a2 = sum(f["before"] if id(f) in late_ids else f["after_hevc"] for f in files)
        speed_rows[speed] = dict(late=len(late), saved_h264=b - a1, saved_hevc=b - a2)
        lines.append(f"| {1 / speed:g}x the video's length | {len(late)} | {(b - a1) / GB:.2f} GB | {(b - a2) / GB:.2f} GB |")

    # Kept as they were, and why: by count and by size.
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
    lines.append("### Kept as they were, and why")
    lines.append("")
    lines.append("| Why | Videos | Share of videos | GB | Share of the library | What it means |")
    lines.append("|---|---:|---:|---:|---:|---|")
    for key, t in sorted(kept.items(), key=lambda kv: -kv[1]["before"]):
        means = WHY.get(key, "in a folder no gallery sees (WhatsApp's Sent)" if key.startswith("not in the gallery")
                        else "the run did not reach it" if key == "not measured" else "")
        lines.append(f"| {key} | {t['videos']} | {100 * t['videos'] / len(files):.0f}% | {t['before'] / GB:.2f} | "
                     f"{100 * t['before'] / b:.0f}% | {means} |")
    n_left = sum(t["videos"] for t in kept.values())
    gb_left = sum(t["before"] for t in kept.values())
    lines.append(f"| **Not made smaller, for any reason** | {n_left} | {100 * n_left / len(files):.0f}% | "
                 f"{gb_left / GB:.2f} | {100 * gb_left / b:.0f}% | |")

    # The quality of the copies, from quality.py's sample.
    if quality:
        by_kind = OrderedDict()
        for f in files:
            if f["quality"]:
                by_kind.setdefault(f["row"]["label"], []).append(f["quality"])
        q_kind = quality_table(lines, "How good the copies are, by kind (a sample, graded against the original)",
                               by_kind)
        by_scene_q = OrderedDict()
        for f in files:
            if f["quality"]:
                by_scene_q.setdefault(SCENES.get(f["scene"], f["scene"]), []).append(f["quality"])
        q_scene = quality_table(lines, "How good the copies are, by scene", by_scene_q, first="Scene")
        graded = [q for q in quality.values() if q.get("status") == "graded"]
        tools = sorted({q.get("vmaf_tool", "") for q in quality.values() if q.get("vmaf_tool")})
        verdicts = [v["verdict"] for v in q_kind.values() if v.get("graded")]
        good = sum(1 for v in verdicts if v.startswith(("as good", "better")))
        lines.append("")
        lines.append(f"In {good} of the {len(verdicts)} kinds graded the app's copy was at least as good as the "
                     f"Storage saver reference (VMAF where every copy of the kind has it, SSIM Y otherwise; "
                     f"as good means within {VMAF_SLACK:g} VMAF or {SSIM_SLACK:g} SSIM). {len(graded)} copies graded "
                     f"of {len(quality)} sampled.")
        lines.append("")
        lines.append("How: each copy's original is scaled to the copy's size (bicubic) and put on the copy's frame "
                     "rate, lined up to within one of its own frames (up to two of the copy's frames either way), "
                     "and the two are compared over the whole clip: SSIM and PSNR on brightness (Y), VMAF "
                     "(vmaf_v0.6.1) and VMAF's phone model (the same model for a phone held at arm's length: "
                     "93 and up looks like the original, 85-93 good, 75-85 fair). The reference is the same "
                     "original at most 1080p and 30 fps, H.264 by libx264 -preset medium at 8 Mbps for 1080p30 and "
                     "in proportion below that. Google publishes no bitrate for Storage saver (its help page says "
                     "only that videos above 1080p are resized to 1080p), so 8 Mbps is an assumption, not a "
                     "measurement. A frame from each graded copy - original, app, reference - is in the shard "
                     "artifacts' frames folder.")
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
    reasons = OrderedDict()
    for f in files:
        if f["outcome"].startswith("kept"):
            reasons[f["outcome"]] = reasons.get(f["outcome"], 0) + 1
    if reasons:
        lines.append("Kept as they were: " + ", ".join(f"{k}: {v}" for k, v in reasons.items()))

    with open(os.path.join(a.out, "summary.txt"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(os.path.join(a.out, "per-file.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["name", "group", "kind", "folder", "real_minutes", "width", "height", "fps", "codec", "video_kbps",
                    "before_mb", "after_mb_measured", "codec_used", "after_mb_other_codec_estimate", "outcome", "scene",
                    "already_compressed", "share", "graded", "app_ssim_y", "ref_ssim_y", "app_vmaf", "ref_vmaf",
                    "app_vmaf_phone", "ref_vmaf_phone", "chosen_share", "after_mb_hevc_at_asked_rate"])
        for f in files:
            r, q = f["row"], f["quality"]
            w.writerow([f["name"], r["group"], r["label"], r["folder"], f"{f['real_s'] / 60:.2f}", r["width"], r["height"],
                        r["fps"], r["codec"], r["video_kbps"], f"{f['before'] / 1e6:.1f}", f"{f['after'] / 1e6:.1f}",
                        f["codec"] if f["reencoded"] else "", f"{f['after_hevc'] / 1e6:.1f}", f["outcome"], f["scene"],
                        int(f["compressed"]), f"{f['share']:.3f}" if f["share"] else "", q.get("status", ""),
                        q.get("app_ssim_y", ""), q.get("ref_ssim_y", ""), q.get("app_vmaf", ""), q.get("ref_vmaf", ""),
                        q.get("app_vmaf_phone", ""), q.get("ref_vmaf_phone", ""),
                        f"{f['chosen']:.3f}" if f["chosen"] is not None else "", f"{f['after_hevc_asked'] / 1e6:.1f}"])
    with open(os.path.join(a.out, "summary.json"), "w") as fh:
        json.dump(dict(videos=len(files), measured=n_measured, measured_codec=measured_codec, before_bytes=b,
                       after_bytes_measured=af, after_bytes_other_codec_estimate=ah,
                       after_bytes_hevc_at_asked_rate=aa, verdict_bytes=hevc_after, landed_median=landed_typ,
                       target=dict(gb=TARGET_GB, low_gb=TARGET_LOW_GB, met=met, already_compressed_before=rb,
                                   already_compressed_after_measured=ra, already_compressed_after_other=rh),
                       by_kind={label: dict(zip(("before", "after_measured"), totals(sel))) | dict(
                           after_other=totals(sel, "after_hevc")[1], videos=len(sel)) for label, sel in groups.items()},
                       by_scene=scene_rows, kept_as_they_were=kept,
                       quality=dict(by_kind=q_kind, by_scene=q_scene),
                       time_limit={str(k): v for k, v in speed_rows.items()}, devices=devices), fh, indent=2)
    print("\n".join(lines))


if __name__ == "__main__":
    main()
