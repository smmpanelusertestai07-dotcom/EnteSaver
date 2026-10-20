#!/usr/bin/env python3
"""What the savings benchmark measured, scaled back up to the real library.

Each video was made shorter than the one it stands for, at the same
resolution, frame rate, codec and bitrate, so the app's copy of the short file
is in the same proportion to it as its copy of the long one would be. This
puts every measured file back at its real length, adds the library up by kind
of video, sets the result against the owner's target (46 GB down to under
10 GB), and writes:

  summary.txt   the verdict, the totals and the tables (also the job summary)
  per-file.csv  every video: real size before and after, and what happened
  summary.json  the same totals, for anything that reads them

Every copy keeps its original's codec, size and frame rate (Ente Saver
16.0), so each video is measured in its own codec. An emulator has no
encoder chip: its software encoders stand in for a phone's (-e
softwareEncoders true, which savings-bench.yml passes). They cannot write
everything a phone's chip does - Android's software HEVC encoder takes
512x512 at most, its H.264 encoder 2048x2048 - so on the emulator a 4K clip,
a tall screen recording or an HEVC clip at its own size stays as it is.
What a phone's chip makes of them, at the rate the app asks for, is worked
out from the app's own rules and the share it chose for each clip, and kept
apart from the measurement; the verdict is given for a phone like the
Realme 11 Pro 5G, whose chip writes H.264 and HEVC at these sizes.

Kept the same: every copy the emulator made is read back, as the app reads
it, against its original - codec, size, rotation, frames, sound, date and
place - and the report says how many kept each.

The quality of the copies comes from quality.py, which graded a sample of
them on the shard runners - SSIM, PSNR and VMAF against the original, beside
a Storage saver reference made from the same original - and is reported by
kind and by scene.

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

# The app's one video setting - every video at its own size and frame rate,
# in its own codec - BitrateCalc's standard rates and AudioPlan's sound, as
# app/src/main/kotlin/app/entesaver/core/logic/MediaSettings.kt,
# BitrateCalc.kt and AudioPlan.kt define them.
REF_HEVC_BPS, REF_PIXEL_RATE, SCALE_EXPONENT = 850_000, 1920 * 1080 * 30, 0.75
CODEC_FACTOR = {"HEVC": 1.0, "H264": 1.45}
CAP_BPS, FLOOR_BPS = 24_000_000, 150_000
COPY_FACTOR = 1.15
# AudioPlan: a track up to these rates is copied; a heavier AAC one is
# written again as AAC-LC at the lower ones.
KEEP_AUDIO = {1: 96_000, 2: 160_000}
AUDIO_AIM = {1: 64_000, 2: 128_000}
BUDGET_S = 20 * 60
# How fast a phone encodes, as a multiple of playing the video: 0.5 takes
# twice its length (what the emulator's software encoder managed), 2 half.
SPEEDS = (0.5, 1.0, 2.0)
GB = 1e9
# The owner's target: the 46 GB library under 10 GB.
TARGET_GB = 10.0
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


def kind(row):
    return "HEVC" if str(row.get("codec", "")).lower() == "hevc" else "H264"


def upright(row):
    w, h = int(row["width"]), int(row["height"])
    return (h, w) if int(row["rotation"]) in (90, 270) else (w, h)


def target_bps(row):
    """BitrateCalc.targetBps at the video's own size and frame rate, in its own codec."""
    w, h = upright(row)
    fps = float(row["fps"])
    raw = REF_HEVC_BPS * (w * h * fps / REF_PIXEL_RATE) ** SCALE_EXPONENT * CODEC_FACTOR[kind(row)]
    return min(max(raw, FLOOR_BPS), CAP_BPS)


# BitrateCalc.SOURCE_SHARE: the most of what its source holds a copy is asked for.
SOURCE_SHARE = 0.6


def source_cap(row):
    """BitrateCalc.sourceCapBps: SOURCE_SHARE of what the source's own picture
    holds - in the same codec at the same size, so nothing else scales it.
    None when the source's bitrate is not known."""
    video_bps = float(row.get("video_kbps") or 0) * 1000
    if video_bps <= 0:
        return None
    return min(max(video_bps * SOURCE_SHARE, FLOOR_BPS), CAP_BPS)


def audio_bps(row):
    """AudioPlan: what the copy's sound comes to."""
    channels = int(row.get("channels") or 0)
    if channels <= 0:
        return 0
    have = float(row.get("audio_kbps") or 0) * 1000
    keep = KEEP_AUDIO.get(channels, 2 * KEEP_AUDIO[2])
    return have if have <= keep else min(have, AUDIO_AIM.get(channels, 2 * AUDIO_AIM[2]))


def asked_bps(row, share):
    """The picture's rate the app asks a chip for: its share of the standard
    rate, never more than SOURCE_SHARE of what the source holds."""
    target = target_bps(row) * share
    cap = source_cap(row)
    return min(target, cap) if cap else target


def lean_already(row, src_bps, share):
    """BitrateCalc.shouldCopyAsIs: the file already at or under what the app
    would ask for, within 15%."""
    return src_bps <= asked_bps(row, share) * COPY_FACTOR


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
        src_bps = src * 8 / gen_s if src else (float(row["video_kbps"]) + float(row["audio_kbps"])) * 1000
        chosen = num(m, "chosen_share", None) if m and m.get("chosen_share") else None
        landed = None
        if reencoded and chosen:
            out_s = num(m, "out_duration_ms") / 1000 or gen_s
            out_video = num(m, "out_video_bytes") * 8 / out_s if num(m, "out_video_bytes") > 0 else None
            asked = asked_bps(row, chosen)
            landed = out_video / asked if out_video and asked else None
        # At the rate the app asks a phone's chip for, which a chip writing
        # in CBR holds to. Every clip the app makes a copy of on such a phone
        # counts: those made here, those lean already, those the emulator's
        # software encoder could not bring down to the rate (encoder_rejected)
        # and those its encoders could not write at their own size at all
        # (chip_cannot_keep). HDR stays as it is - the emulator writes no HDR,
        # and a phone only with a chip Media3 counts as editing HDR.
        hdr = row.get("hdr") == "1"
        counts = reencoded or reason in ("already_efficient", "encoder_rejected", "not_smaller") or \
            reason in EMULATOR_ONLY
        if hdr or row.get("in_gallery") == "0" or not counts or chosen is None:
            asked_after = after
        else:
            est = (asked_bps(row, chosen) + audio_bps(row)) * real_s / 8
            asked_after = before if lean_already(row, src_bps, chosen) or est >= before else est
        # The same, counting the clips the emulator's encoder would not bring
        # down as kept whole: the figure that assumes nothing of the chip.
        asked_kept = before if reason == "encoder_rejected" else asked_after
        q = quality.get(name, {})
        files.append(dict(row=row, m=m or {}, name=name, real_s=real_s, before=before, after=after, outcome=outcome,
                          reason=reason, reencoded=reencoded, measured=bool(m), chosen=chosen, landed=landed,
                          asked=asked_after, asked_kept=asked_kept, src_bps=src_bps, gen_s=gen_s,
                          ms=int(m["ms"]) if m else 0, quality=q, codec=kind(row),
                          compressed=row.get("already_compressed") == "1", scene=row.get("scene", "")))

    def totals(sel, key="after"):
        return sum(f["before"] for f in sel), sum(f[key] for f in sel)

    b, af = totals(files)
    _, aa = totals(files, "asked")
    _, aak = totals(files, "asked_kept")
    n_measured = sum(1 for f in files if f["measured"])
    n_made = sum(1 for f in files if f["reencoded"])
    emulator_only = [f for f in files if f["reason"] in EMULATOR_ONLY]
    eo_b = sum(f["before"] for f in emulator_only)
    overshot = [f for f in files if f["reason"] == "encoder_rejected"]
    received = [f for f in files if f["compressed"]]
    rb, ra = totals(received, "asked")
    met = aa < TARGET_GB * GB
    lines = ["## Ente Saver savings benchmark v4 (every video in its own codec, size and frame rate)", ""]
    lines.append(
        f"**Verdict: the owner's target is the {b / GB:.0f} GB library under {TARGET_GB:.0f} GB - "
        f"{'met' if met else 'not met'} on a phone whose chip keeps to the rate the app asks for: "
        f"{aa / GB:.2f} GB ({b / max(aa, 1):.1f} times smaller; an estimate from the share the app chose for each "
        f"clip).** Counting the {len(overshot)} clips the emulator's encoder would not bring down as kept whole, "
        f"{aak / GB:.2f} GB. Measured on the emulator, where {len(emulator_only)} videos ({eo_b / GB:.1f} GB: 4K, tall "
        f"screen recordings and HEVC, which its software encoders cannot write at their own size) stayed as they "
        f"were, the library went from {b / GB:.1f} GB to {af / GB:.1f} GB. Of the estimate, {ra / GB:.1f} GB are "
        f"downloads and forwards WhatsApp, Instagram, YouTube or Telegram had already compressed ({rb / GB:.1f} GB "
        f"before).")
    lines.append("")
    lines.append(f"- Library: {len(files)} videos, {b / GB:.2f} GB (measured: {n_measured}, copies made here: {n_made})")
    lines.append(f"- At the rate the app asks a phone's chip for (estimate): **{aa / GB:.2f} GB after, "
                 f"{(b - aa) / GB:.2f} GB saved ({100 * (b - aa) / b:.1f}%)**")
    lines.append(f"- The same, with the {len(overshot)} clips the emulator's encoder overshot on every try kept "
                 f"whole: {aak / GB:.2f} GB")
    lines.append(f"- Measured on the emulator: {af / GB:.2f} GB after ({100 * (b - af) / b:.1f}% smaller), with "
                 f"{len(emulator_only)} videos ({eo_b / GB:.2f} GB) its encoders could not write kept whole")
    landed = [f["landed"] for f in files if f["landed"]]
    if landed:
        lines.append(f"- The emulator's encoder wrote {statistics.median(landed):.2f} x the rate the app asked for "
                     f"(median; {min(landed):.2f} to {max(landed):.2f}): a phone's chip in CBR keeps to it")
    shares = [f["chosen"] for f in files if f["chosen"]]
    if shares:
        lines.append(f"- The app gave each clip {statistics.median(shares):.2f} x the standard rate (median share, "
                     f"{min(shares):.2f} to {max(shares):.2f}), read from how much it moves and how dark it is")
    speeds = [f["gen_s"] / (f["ms"] / 1000) for f in files if f["reencoded"] and f["ms"] > 0]
    if speeds:
        lines.append(f"- The emulator's software encoders ran at {statistics.median(speeds):.2f} x real time "
                     f"(median, the app's own measuring of each clip included); a phone's chip is faster")
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
        lines.append("| Kind of video | Videos | Before GB | After GB (chip, at the asked rate, est.) | Saved | "
                     "After GB (measured on the emulator) | Saved |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|")
        for label, sel in table.items():
            gb, ga = totals(sel, "asked")
            _, gm = totals(sel)
            pct = lambda x: f"{100 * (gb - x) / gb:.0f}%" if gb else "-"
            lines.append(f"| {label} | {len(sel)} | {gb / GB:.2f} | {ga / GB:.2f} | {pct(ga)} | {gm / GB:.2f} | "
                         f"{pct(gm)} |")
        lines.append(f"| **All** | {len(files)} | {b / GB:.2f} | {aa / GB:.2f} | {100 * (b - aa) / b:.0f}% | "
                     f"{af / GB:.2f} | {100 * (b - af) / b:.0f}% |")

    by_scene = OrderedDict((s, []) for s in SCENES)
    for f in files:
        by_scene.setdefault(f["scene"] or "-", []).append(f)
    lines.append("")
    lines.append("### What is in the picture (the manifest's scene column)")
    lines.append("")
    lines.append("| Scene | Videos | Real hours | Before GB | After GB (chip, est.) | Saved | After GB (measured) |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|")
    scene_rows = OrderedDict()
    for sc, sel in by_scene.items():
        if not sel:
            continue
        gb, ga = totals(sel, "asked")
        _, gm = totals(sel)
        hours = sum(f["real_s"] for f in sel) / 3600
        scene_rows[sc] = dict(videos=len(sel), hours=hours, before=gb, after_asked=ga, after_measured=gm)
        lines.append(f"| {SCENES.get(sc, sc)} | {len(sel)} | {hours:.1f} | {gb / GB:.2f} | {ga / GB:.2f} | "
                     f"{100 * (gb - ga) / gb:.0f}% | {gm / GB:.2f} |")

    lines.append("")
    lines.append("### The 20-minute limit (a video that cannot be encoded in 20 minutes is kept as it is)")
    lines.append("")
    lines.append("| Encoding takes | Videos that would run out of time | Saved (chip, est.) |")
    lines.append("|---|---:|---:|")
    speed_rows = {}
    for speed in SPEEDS:
        late = {id(f) for f in files if f["asked"] < f["before"] and f["real_s"] / speed > BUDGET_S}
        left = sum(f["before"] if id(f) in late else f["asked"] for f in files)
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
            means += " - here the emulator's software encoder; a phone's chip writes them (in the estimate)"
        lines.append(f"| {key} | {t['videos']} | {100 * t['videos'] / len(files):.0f}% | {t['before'] / GB:.2f} | "
                     f"{100 * t['before'] / b:.0f}% | {means} |")

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
        lines.append("")
        lines.append(f"{len(graded)} copies graded of {len(quality)} sampled. How: each copy's original is put on the "
                     "copy's size and frame rate (the same ones, now), lined up to within one of its own frames, and "
                     "the two are compared over the whole clip: SSIM and PSNR on brightness (Y), VMAF (vmaf_v0.6.1) "
                     "and VMAF's phone model (a phone held at arm's length: 93 and up looks like the original, "
                     "85-93 good, 75-85 fair). The reference is the same original at most 1080p and 30 fps, H.264 by "
                     "libx264 -preset medium at 8 Mbps for 1080p30 and in proportion below that - a yardstick for "
                     "Google Photos' Storage saver, whose bitrate Google does not publish. The copies here were "
                     "written by the emulator's software encoder, not a phone's chip.")
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

    with open(os.path.join(a.out, "summary.txt"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(os.path.join(a.out, "per-file.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["name", "group", "kind", "folder", "real_minutes", "width", "height", "fps", "codec", "video_kbps",
                    "before_mb", "after_mb_measured", "after_mb_chip_at_asked_rate", "outcome", "scene",
                    "already_compressed", "chosen_share", "landed", "graded", "app_ssim_y", "ref_ssim_y", "app_vmaf",
                    "ref_vmaf", "app_vmaf_phone", "ref_vmaf_phone", "out_video_mime", "out_rotation", "src_rotation",
                    "src_frames", "out_frames", "src_date", "out_date", "src_place", "out_place"])
        for f in files:
            r, q, m = f["row"], f["quality"], f["m"]
            w.writerow([f["name"], r["group"], r["label"], r["folder"], f"{f['real_s'] / 60:.2f}", r["width"],
                        r["height"], r["fps"], r["codec"], r["video_kbps"], f"{f['before'] / 1e6:.1f}",
                        f"{f['after'] / 1e6:.1f}", f"{f['asked'] / 1e6:.1f}", f["outcome"], f["scene"],
                        int(f["compressed"]), f"{f['chosen']:.3f}" if f["chosen"] is not None else "",
                        f"{f['landed']:.3f}" if f["landed"] else "", q.get("status", ""), q.get("app_ssim_y", ""),
                        q.get("ref_ssim_y", ""), q.get("app_vmaf", ""), q.get("ref_vmaf", ""),
                        q.get("app_vmaf_phone", ""), q.get("ref_vmaf_phone", ""), m.get("out_video_mime", ""),
                        m.get("out_rotation", ""), m.get("src_rotation", ""), m.get("src_frames", ""),
                        m.get("out_frames", ""), m.get("src_date", ""), m.get("out_date", ""),
                        m.get("src_place", ""), m.get("out_place", "")])
    with open(os.path.join(a.out, "summary.json"), "w") as fh:
        json.dump(dict(videos=len(files), measured=n_measured, made=n_made, before_bytes=b, after_bytes_measured=af,
                       after_bytes_chip_at_asked_rate=aa, after_bytes_chip_overshot_kept=aak,
                       emulator_only_kept=len(emulator_only), emulator_only_bytes=eo_b,
                       overshot_kept_whole=len(overshot),
                       target=dict(gb=TARGET_GB, met=met, already_compressed_before=rb,
                                   already_compressed_after=ra),
                       same=same,
                       by_kind={label: dict(zip(("before", "after_chip"), totals(sel, "asked"))) | dict(
                           after_measured=totals(sel)[1], videos=len(sel)) for label, sel in groups.items()},
                       by_scene=scene_rows, kept_as_they_were=kept, quality=dict(by_kind=q_kind, by_scene=q_scene),
                       time_limit={str(k): v for k, v in speed_rows.items()}, devices=devices), fh, indent=2)
    print("\n".join(lines))


if __name__ == "__main__":
    main()
