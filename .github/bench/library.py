#!/usr/bin/env python3
"""The savings benchmark's video library: one ordinary phone's worth of videos.

Every kind of video is described once, in PROFILES: where Android keeps it,
its resolution, frame rate, codec and bitrate, and how long such videos run.
A fixed seed draws the library from that - the same files on every run - and
sizes it to LIBRARY_GB.

The files themselves are made shorter than the videos they stand for (gen_s
against real_s), so three emulators can get through the whole library in one
CI run. Everything the app decides by - resolution, rotation, frame rate,
codec, bitrate, audio - is the real video's, and at a fixed bitrate a file's
size grows in step with its length, so report.py can put each measured result
back at the real length. The picture is a moving test pattern under sensor-
like noise, so an encoder has to spend real bits on it, as it would on a
camera's; a screen recording of menus gets less noise, as it would.

  library.py manifest --out manifest.csv
  library.py make --shard 0 --shards 3 --out bench-library
"""
import argparse
import concurrent.futures
import csv
import datetime
import math
import os
import random
import subprocess
import sys

LIBRARY_GB = 46.0
SEED = 20231016
# A made file is this share of the real video's length, but never shorter
# than MIN_S or longer than MAX_S.
SCALE, MIN_S, MAX_S = 0.08, 3.0, 12.0
# A constant-bitrate H.264 or HEVC stream comes out a few percent over the
# rate it was asked for (headers, the HRD's padding); sizing the library on
# the asked-for rate alone would overshoot LIBRARY_GB by that much.
OVERHEAD = 1.065

WA = "Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Video"
TG = "Android/media/org.telegram.messenger/Telegram/Telegram Video"


def P(pid, label, folder, count, dur, size, fps, codec, vkbps, akbps, names, portrait=0.0, noise=20,
      channels=2, rate=48000):
    w, h = size
    return dict(id=pid, label=label, folder=folder, count=count, dur=dur, width=w, height=h, fps=fps,
                codec=codec, video_kbps=vkbps, audio_kbps=akbps, names=names, portrait=portrait, noise=noise,
                channels=channels, sample_rate=rate)


# width x height as stored. A camera stores a portrait clip as landscape
# pixels with a rotation tag (portrait = the share filmed upright); WhatsApp,
# reels and downloads store portrait pixels as they are.
PROFILES = [
    # Realme 11 Pro 5G rear camera, default 1080p 30 fps, H.264.
    P("cam1080", "Camera 1080p 30fps", "DCIM/Camera", 150, (6, 45, 600), (1920, 1080), 30, "h264", 17000, 128,
      "camera", portrait=0.7),
    P("cam1080_60", "Camera 1080p 60fps", "DCIM/Camera", 22, (8, 40, 300), (1920, 1080), 60, "h264", 25000, 128,
      "camera", portrait=0.5),
    P("cam4k", "Camera 4K 30fps", "DCIM/Camera", 14, (8, 50, 240), (3840, 2160), 30, "h264", 45000, 128,
      "camera", portrait=0.4),
    P("slowmo", "Camera slow motion 120fps", "DCIM/Camera", 6, (4, 10, 30), (1920, 1080), 120, "h264", 40000, 128,
      "camera", portrait=0.3),
    P("front", "Front camera 1080p", "DCIM/Camera", 20, (5, 30, 180), (1920, 1080), 30, "h264", 14000, 128,
      "camera", portrait=1.0),
    P("cam_long", "Long family videos (functions)", "DCIM/Camera", 4, (900, 1500, 2400), (1920, 1080), 30, "h264",
      17000, 128, "camera", portrait=0.5),
    # Received and saved from apps: already compressed by whoever sent them.
    P("wa", "WhatsApp videos", WA, 170, (5, 40, 300), (480, 848), 30, "h264", 1100, 64, "whatsapp", noise=14,
      channels=1, rate=44100),
    P("wa_hd", "WhatsApp HD videos", WA, 30, (5, 45, 240), (720, 1280), 30, "h264", 2600, 96, "whatsapp",
      noise=14),
    P("status", "WhatsApp status saves", "Pictures/Status Saver", 30, (8, 25, 30), (720, 1280), 30, "h264",
      1600, 64, "status", noise=14),
    P("reels", "Instagram reels (saved)", "Movies/Instagram", 40, (8, 30, 90), (1080, 1920), 30, "h264", 3500, 128,
      "instagram", noise=14),
    P("shorts", "Moj / ShareChat / Shorts downloads", "Download", 18, (8, 25, 60), (720, 1280), 30, "h264", 2000,
      96, "download", noise=14),
    P("yt720", "YouTube / Snaptube downloads 720p", "Download/Snaptube", 6, (240, 600, 1500), (1280, 720), 30,
      "h264", 2200, 128, "download", noise=10),
    P("screen_game", "Screen recordings (games)", "DCIM/Screenrecorder", 6, (120, 480, 1200), (1080, 2400), 60,
      "h264", 16000, 128, "screen", noise=12),
    P("screen", "Screen recordings (apps)", "DCIM/Screenrecorder", 8, (20, 90, 300), (1080, 2400), 30, "h264",
      8000, 128, "screen", noise=2),
    P("movie", "Telegram movie downloads", TG, 2, (6000, 8100, 9000), (1280, 720), 24, "hevc", 1100, 128,
      "telegram", noise=10),
]


def draw():
    """The library: every file's kind, real length, name and place, from SEED."""
    rng = random.Random(SEED)
    start = datetime.datetime(2023, 7, 1)
    files = []
    for p in PROFILES:
        lo, typ, hi = p["dur"]
        sigma = math.log(hi / lo) / 5
        for i in range(p["count"]):
            real = min(max(typ * math.exp(rng.gauss(0, sigma)), lo), hi)
            when = start + datetime.timedelta(seconds=rng.randrange(0, 820 * 86400))
            files.append(dict(p=p, i=i, real_s=real, when=when, rot=90 if rng.random() < p["portrait"] else 0,
                              n=rng.randrange(1000, 9999)))
    # Lengths scaled together so the library adds up to LIBRARY_GB.
    total = sum((f["p"]["video_kbps"] + f["p"]["audio_kbps"]) * 1000 * OVERHEAD / 8 * f["real_s"] for f in files)
    k = LIBRARY_GB * 1e9 / total
    seen = set()
    for idx, f in enumerate(files):
        p = f["p"]
        lo, _, hi = p["dur"]
        f["real_s"] = round(min(max(f["real_s"] * k, lo), hi * 1.25), 1)
        f["gen_s"] = round(min(max(f["real_s"] * SCALE, MIN_S), MAX_S), 1)
        name = name_for(p["names"], f, idx)
        while name in seen:
            f["when"] += datetime.timedelta(seconds=1)
            name = name_for(p["names"], f, idx)
        seen.add(name)
        f["name"] = name
        f["seed"] = idx + 1
    return files


def name_for(style, f, idx):
    t = f["when"]
    if style == "camera":
        return t.strftime("VID%Y%m%d%H%M%S") + ".mp4"
    if style == "whatsapp":
        return t.strftime("VID-%Y%m%d-WA") + f"{f['n'] % 1000:04d}.mp4"
    if style == "status":
        return f"{(f['n'] * 2654435761 + idx) & 0xFFFFFFFF:08x}{t.strftime('%H%M%S')}.mp4"
    if style == "instagram":
        return f"VID_{f['n']}{t.strftime('%m%d')}_{t.strftime('%H%M%S')}_{idx % 1000:03d}.mp4"
    if style == "download":
        return f"video_{t.strftime('%Y%m%d_%H%M%S')}.mp4"
    if style == "screen":
        return t.strftime("Screenrecorder-%Y-%m-%d-%H-%M-%S") + f"-{f['n'] % 1000:03d}.mp4"
    if style == "telegram":
        return t.strftime("video_%Y-%m-%d_%H-%M-%S") + ".mp4"
    raise ValueError(style)


def manifest_rows(files, shards):
    for idx, f in enumerate(files):
        p = f["p"]
        yield dict(name=f["name"], profile=p["id"], label=p["label"], folder=p["folder"], real_s=f["real_s"],
                   gen_s=f["gen_s"], width=p["width"], height=p["height"], rotation=f["rot"], fps=p["fps"],
                   codec=p["codec"], video_kbps=p["video_kbps"], audio_kbps=p["audio_kbps"],
                   shard=idx % shards, seed=f["seed"])


def make_one(f, out_root):
    """One file, at its real bitrate and its made length."""
    p = f["p"]
    folder = os.path.join(out_root, p["folder"])
    os.makedirs(folder, exist_ok=True)
    dest = os.path.join(folder, f["name"])
    tmp = dest + ".tmp.mp4"
    s, fps, vk, ak = f["gen_s"], p["fps"], p["video_kbps"], p["audio_kbps"]
    video = (f"testsrc2=size={p['width']}x{p['height']}:rate={fps}:duration={s},"
             f"noise=alls={p['noise']}:allf=t+u:all_seed={f['seed']},format=yuv420p")
    audio = (f"anoisesrc=color=pink:amplitude=0.05:sample_rate={p['sample_rate']}:duration={s}:seed={f['seed']}")
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", video,
           "-f", "lavfi", "-i", audio]
    if p["codec"] == "hevc":
        cmd += ["-c:v", "libx265", "-preset", "ultrafast", "-tag:v", "hvc1", "-x265-params",
                f"bitrate={vk}:vbv-maxrate={vk}:vbv-bufsize={vk}:keyint={fps}:strict-cbr=1:log-level=error"]
    else:
        cmd += ["-c:v", "libx264", "-preset", "ultrafast", "-g", str(fps), "-b:v", f"{vk}k", "-minrate", f"{vk}k",
                "-maxrate", f"{vk}k", "-bufsize", f"{vk}k", "-x264-params", "nal-hrd=cbr:force-cfr=1"]
    cmd += ["-c:a", "aac", "-b:a", f"{ak}k", "-ac", str(p["channels"]), "-threads", "2",
            "-metadata", "creation_time=" + f["when"].strftime("%Y-%m-%dT%H:%M:%SZ"),
            "-movflags", "+faststart", tmp if f["rot"] else dest]
    subprocess.run(cmd, check=True)
    if f["rot"]:
        # A camera writes upright clips as landscape pixels plus a rotation
        # tag; -90 here is what Android reads back as 90.
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-display_rotation:v:0",
                        str(-f["rot"]), "-i", tmp, "-c", "copy", "-movflags", "+faststart", dest], check=True)
        os.remove(tmp)
    t = f["when"].timestamp()
    os.utime(dest, (t, t))
    return f["name"], f["gen_s"], os.path.getsize(dest)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("manifest")
    m.add_argument("--out", required=True)
    m.add_argument("--shards", type=int, default=3)
    mk = sub.add_parser("make")
    mk.add_argument("--shard", type=int, required=True)
    mk.add_argument("--shards", type=int, required=True)
    mk.add_argument("--out", required=True)
    mk.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    mk.add_argument("--only", default="", help="comma-separated profile ids (for trying it out)")
    a = ap.parse_args()

    files = draw()
    if a.cmd == "manifest":
        rows = list(manifest_rows(files, a.shards))
        with open(a.out, "w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=list(rows[0]))
            w.writeheader()
            w.writerows(rows)
        gb = sum((float(r["video_kbps"]) + float(r["audio_kbps"])) * OVERHEAD * 1000 / 8 * float(r["real_s"])
                 for r in rows) / 1e9
        hours = sum(float(r["real_s"]) for r in rows) / 3600
        print(f"{len(rows)} videos, about {gb:.1f} GB, {hours:.1f} hours")
        return

    mine = [f for idx, f in enumerate(files) if idx % a.shards == a.shard]
    if a.only:
        keep = set(a.only.split(","))
        mine = [f for f in mine if f["p"]["id"] in keep]
    made = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as pool:
        for name, gen_s, size in pool.map(lambda f: make_one(f, a.out), mine):
            made.append((name, gen_s, size))
    made_csv = os.path.join(os.path.dirname(os.path.abspath(a.out)), os.path.basename(a.out) + "-made.csv")
    with open(made_csv, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["name", "gen_s", "bytes"])
        w.writerows(made)
    print(f"made {len(made)} videos, {sum(s for _, _, s in made) / 1e9:.2f} GB, "
          f"{sum(g for _, g, _ in made) / 60:.1f} minutes, listed in {made_csv}")


if __name__ == "__main__":
    sys.exit(main())
