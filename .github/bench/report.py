#!/usr/bin/env python3
"""What the savings benchmark measured, scaled back up to the real library.

Each video was made shorter than the one it stands for, at the same
resolution, frame rate, codec and bitrate, so the app's copy of the short file
is in the same proportion to it as its copy of the long one would be. This
puts every measured file back at its real length, adds the library up by kind
of video, and writes:

  summary.txt   the totals and a table by kind of video (also the job summary)
  per-file.csv  every video: real size before and after, and what happened
  summary.json  the same totals, for anything that reads them

Two things an emulator cannot show are worked out from the app's own rules
rather than measured, and kept apart from the measurement:

  - HEVC: an emulator has no HEVC encoder chip, so the app writes H.264 there.
    A phone with one (a Realme 11 Pro 5G has) gets HEVC, which needs about a
    third fewer bits for the same picture.
  - The 20-minute limit: the app gives one video at most 20 minutes to encode
    and keeps a video that runs out of time as it is. How long a real phone
    takes depends on its chip, so the effect is shown at a few speeds.
"""
import argparse
import csv
import glob
import json
import os
import statistics
from collections import OrderedDict

# Balanced, as app/src/main/kotlin/app/entesaver/core/logic/MediaSettings.kt
# and BitrateCalc.kt define it.
LONG_SIDE = 1920
FPS_CAP = 30
SLOW_MOTION_FPS = 90.0
AUDIO_BPS = 128_000
BPP = {"H264": 0.10, "HEVC": 0.065}
CAP_BPS, CAP_BPS_UHD, FLOOR_BPS, UHD_LONG_SIDE = 12_000_000, 20_000_000, 1_000_000, 2560
COPY_FACTOR = 1.15
BUDGET_S = 20 * 60
SPEEDS = (1.0, 2.0, 4.0)
GB = 1e9


def output_dims(w, h, limit):
    long_side = max(w, h)
    if long_side <= limit:
        return w - w % 2, h - h % 2
    scale = limit / long_side
    ow, oh = round(w * scale), round(h * scale)
    return ow - ow % 2, oh - oh % 2


def plan(row, codec, src_bps):
    """What the app does with this video on a phone that writes `codec`:
    (kept_as_is, target video bits per second). src_bps is the file's own
    bitrate, sound included, as Android's metadata reader reports it."""
    w, h, fps = int(row["width"]), int(row["height"]), float(row["fps"])
    if int(row["rotation"]) in (90, 270):
        w, h = h, w
    capped = FPS_CAP if FPS_CAP + 0.5 < fps < SLOW_MOTION_FPS else None
    out_fps = capped or fps
    ow, oh = output_dims(w, h, LONG_SIDE)
    cap = CAP_BPS_UHD if max(ow, oh) > UHD_LONG_SIDE else CAP_BPS
    target = min(max(ow * oh * out_fps * BPP[codec], FLOOR_BPS), cap)
    as_is = capped is None and max(w, h) <= LONG_SIDE and src_bps <= target * COPY_FACTOR
    return as_is, target


def load_results(shards_dir):
    measured, made, devices = {}, {}, []
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
    return measured, made, devices


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--shards", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    with open(a.manifest, newline="") as fh:
        library = list(csv.DictReader(fh))
    measured, made, devices = load_results(a.shards)

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
                outcome = "failed: " + (m["skip_reason"] or m["error"] or state)
        reencoded = bool(m) and state == "STAGED" and not m["kept_reason"]
        # How far the encoder landed from the bitrate the app asked of it,
        # measured on this file: carried over to the HEVC estimate.
        src_bps = src * 8 / gen_s if src else (float(row["video_kbps"]) + float(row["audio_kbps"])) * 1000
        _, target_h264 = plan(row, "H264", src_bps)
        landed = None
        if reencoded:
            out_bps = int(m["out_bytes"]) * 8 / gen_s - AUDIO_BPS
            landed = out_bps / target_h264 if target_h264 else None
        files.append(dict(row=row, name=name, real_s=real_s, before=before, after=after, outcome=outcome,
                          reencoded=reencoded, landed=landed, measured=bool(m), src_bps=src_bps))

    landed_all = [f["landed"] for f in files if f["landed"]]
    landed_typ = statistics.median(landed_all) if landed_all else 1.0

    # HEVC: the app's own decision with an HEVC chip, the measured landing.
    for f in files:
        row = f["row"]
        as_is, target = plan(row, "HEVC", f["src_bps"])
        if as_is or not f["measured"]:
            f["after_hevc"] = f["before"]
        else:
            est = (target * (f["landed"] or landed_typ) + AUDIO_BPS) * f["real_s"] / 8
            f["after_hevc"] = est if est < f["before"] else f["before"]

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
    n_measured = sum(1 for f in files if f["measured"])
    n_kept = sum(1 for f in files if f["measured"] and not f["reencoded"])
    lines.append("## Ente Saver savings benchmark (Balanced = Google Photos Storage saver)")
    lines.append("")
    lines.append(f"- Library: {len(files)} videos, {b / GB:.2f} GB (measured: {n_measured})")
    lines.append(f"- Emulator (H.264, measured): {af / GB:.2f} GB after, **{(b - af) / GB:.2f} GB saved "
                 f"({100 * (b - af) / b:.1f}%)**")
    lines.append(f"- Phone with an HEVC chip (estimate): {ah / GB:.2f} GB after, **{(b - ah) / GB:.2f} GB saved "
                 f"({100 * (b - ah) / b:.1f}%)**")
    lines.append(f"- Kept as they were (nothing to gain, or failed): {n_kept} videos")
    lines.append(f"- Encoder landed at {landed_typ:.2f} x the bitrate the app asked for (median)")
    for d in devices[:1]:
        lines.append(f"- Emulator: {d.get('model')} API {d.get('sdk')}, RAM {int(d.get('ram_bytes', 0)) / GB:.1f} GB, "
                     f"tier {d.get('tier')}, HEVC chip {d.get('hevc_hardware_1080p30')}")
    broad = OrderedDict()
    for f in files:
        broad.setdefault(f["row"]["group"], []).append(f)
    for title, table in (("Where the videos came from", broad), ("Every kind of video", groups)):
        lines.append("")
        lines.append(f"### {title}")
        lines.append("")
        lines.append("| Kind of video | Videos | Before GB | After GB (H.264) | Saved | After GB (HEVC est.) | Saved |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|")
        for label, sel in table.items():
            gb, ga = totals(sel)
            _, gh = totals(sel, "after_hevc")
            pct = lambda x: f"{100 * (gb - x) / gb:.0f}%" if gb else "-"
            lines.append(f"| {label} | {len(sel)} | {gb / GB:.2f} | {ga / GB:.2f} | {pct(ga)} | {gh / GB:.2f} | "
                         f"{pct(gh)} |")
        lines.append(f"| **All** | {len(files)} | {b / GB:.2f} | {af / GB:.2f} | {100 * (b - af) / b:.0f}% | "
                     f"{ah / GB:.2f} | {100 * (b - ah) / b:.0f}% |")
    lines.append("")
    lines.append("### The 20-minute limit (a video that cannot be encoded in 20 minutes is kept as it is)")
    lines.append("")
    lines.append("| Phone encodes at | Videos that would run out of time | Saved (H.264) | Saved (HEVC est.) |")
    lines.append("|---|---:|---:|---:|")
    speed_rows = {}
    for speed in SPEEDS:
        late = [f for f in files if f["reencoded"] and f["real_s"] / speed > BUDGET_S]
        late_ids = {id(f) for f in late}
        a1 = sum(f["before"] if id(f) in late_ids else f["after"] for f in files)
        a2 = sum(f["before"] if id(f) in late_ids else f["after_hevc"] for f in files)
        speed_rows[speed] = dict(late=len(late), saved_h264=b - a1, saved_hevc=b - a2)
        lines.append(f"| {speed:g}x the video's length | {len(late)} | {(b - a1) / GB:.2f} GB | {(b - a2) / GB:.2f} GB |")
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
                    "before_mb", "after_mb_h264", "after_mb_hevc_estimate", "outcome"])
        for f in files:
            r = f["row"]
            w.writerow([f["name"], r["group"], r["label"], r["folder"], f"{f['real_s'] / 60:.2f}", r["width"], r["height"],
                        r["fps"], r["codec"], r["video_kbps"], f"{f['before'] / 1e6:.1f}", f"{f['after'] / 1e6:.1f}",
                        f"{f['after_hevc'] / 1e6:.1f}", f["outcome"]])
    with open(os.path.join(a.out, "summary.json"), "w") as fh:
        json.dump(dict(videos=len(files), measured=n_measured, before_bytes=b, after_bytes_h264=af,
                       after_bytes_hevc_estimate=ah, landed_median=landed_typ,
                       by_kind={label: dict(zip(("before", "after_h264"), totals(sel))) | dict(
                           after_hevc=totals(sel, "after_hevc")[1], videos=len(sel)) for label, sel in groups.items()},
                       time_limit={str(k): v for k, v in speed_rows.items()}, devices=devices), fh, indent=2)
    print("\n".join(lines))


if __name__ == "__main__":
    main()
