#!/usr/bin/env python3
"""The savings benchmark's video library: one ordinary phone's worth of videos.

Every kind of video is described once, in PROFILES: where Android keeps it,
its resolution, rotation, frame rate, codec, bitrate and sound, and how long
such videos run. The numbers are a Realme 11 Pro 5G's own camera where they
have been measured (1080p30 H.264 at 20 Mbps, 4K at 50 Mbps, AAC at 256 kbps)
and what WhatsApp, Instagram, YouTube downloaders, the screen recorder and
Telegram actually write; the rest are estimates, marked in the table. A fixed
seed draws the library from it - the same files on every run - and sizes it
to LIBRARY_GB.

The files themselves are made shorter than the videos they stand for (gen_s
against real_s), so three emulators get through the whole library in one CI
run. Everything the app decides by - resolution, rotation, frame rate, codec,
bitrate, sound, container - is the real video's, and at a fixed bitrate a
file's size grows in step with its length, so report.py can put each measured
result back at the real length. The picture is a moving test pattern under
sensor-like noise, so an encoder has to spend real bits on it, as it would on
a camera's; a screen recording of menus gets little noise, as it would.

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
# than MIN_S or longer than MAX_S. An encoder spends a burst of about 0.7 s
# worth of bits getting started, whatever the length - a quarter more than
# its rate on a 3 s clip, which a 37 s camera clip never shows - so no file
# is shorter than 20 s, where the burst is under 4%.
SCALE, MIN_S, MAX_S = 0.08, 20.0, 45.0
# x264's constant-bitrate mode lands a little over the asked-for rate (the
# first keyframe, the HRD's padding); asking for this share of it lands on the
# real rate. x265's strict CBR lands on it as asked.
X264_ASK = 0.985
# Real files are not all at one rate: each is drawn within this much of its
# profile's.
SPREAD = 0.15

WA = "Android/media/com.whatsapp/WhatsApp/Media"


def P(pid, group, label, folder, count, dur, size, fps, codec, vkbps, akbps, names, rot=(), landscape=0.0,
      noise=20, channels=2, rate=48000, container="mp4", exact30=0.0, hidden=False):
    """One kind of video. dur is (shortest, mean, longest) in seconds; size is
    width x height as stored; rot lists (rotation, share) for the files a
    camera tags as turned; landscape is the share of a portrait profile whose
    pixels are stored the other way round; hidden folders carry a .nomedia,
    as the app that writes them leaves one, so no gallery - Ente Saver's
    included - ever sees what is in them."""
    w, h = size
    return dict(id=pid, group=group, label=label, folder=folder, count=count, dur=dur, width=w, height=h,
                fps=fps, codec=codec, video_kbps=vkbps, audio_kbps=akbps, names=names, rot=rot,
                landscape=landscape, noise=noise, channels=channels, sample_rate=rate, container=container,
                exact30=exact30, hidden=hidden)


CAM, WAG, SHORT, YT, SCREEN, TG = ("Camera", "WhatsApp", "Reels and short videos", "YouTube downloads",
                                   "Screen recordings", "Telegram")

# [E] marks an estimate; everything else was measured or is documented.
PROFILES = [
    # Realme 11 Pro 5G rear camera, default 1080p30 H.264, 20 Mbps, AAC 256k.
    P("cam_1080p30", CAM, "Camera 1080p 30fps (default)", "DCIM/Camera", 115, (3, 37, 300), (1920, 1080), 30,
      "h264", 20000, 256, "camera", rot=((90, 0.75),)),
    # Weddings, pujas, birthdays, school functions [E: lengths].
    P("cam_long", CAM, "Long function videos", "DCIM/Camera", 9, (300, 660, 1500), (1920, 1080), 30, "h264",
      20000, 256, "camera", rot=((90, 0.4),)),
    P("cam_4k", CAM, "Camera 4K 30fps", "DCIM/Camera", 12, (5, 40, 180), (3840, 2160), 30, "h264", 50000, 256,
      "camera"),
    P("cam_1080p60", CAM, "Camera 1080p 60fps", "DCIM/Camera", 10, (5, 30, 120), (1920, 1080), 60, "h264",
      30000, 256, "camera"),  # [E: bitrate]
    P("cam_slowmo", CAM, "Camera slow motion 1080p 120fps", "DCIM/Camera", 6, (3, 12, 30), (1920, 1080), 120,
      "h264", 40000, 256, "camera", rot=((90, 1.0),)),  # [E: bitrate]
    P("cam_front", CAM, "Front camera 1080p", "DCIM/Camera", 25, (3, 30, 180), (1920, 1080), 30, "h264", 20000,
      256, "camera", rot=((270, 1.0),)),  # [E: bitrate]
    # WhatsApp: 480p standard, 720p HD [E: bitrates].
    P("wa_sd", WAG, "WhatsApp videos (standard)", WA + "/WhatsApp Video", 135, (3, 45, 600), (480, 848), 30,
      "h264", 1200, 96, "whatsapp", landscape=0.4, noise=14, rate=44100, exact30=0.15),
    P("wa_hd", WAG, "WhatsApp videos (HD)", WA + "/WhatsApp Video", 35, (3, 40, 300), (720, 1280), 30, "h264",
      2500, 128, "whatsapp", landscape=0.4, noise=14, rate=44100, exact30=0.15),
    # WhatsApp keeps a .nomedia in Sent, so these are on the phone but in no gallery.
    P("wa_sent", WAG, "WhatsApp sent copies", WA + "/WhatsApp Video/Sent", 25, (3, 30, 180), (480, 848), 30,
      "h264", 1200, 96, "whatsapp", landscape=0.4, noise=14, rate=44100, hidden=True),
    P("wa_status", WAG, "Saved WhatsApp statuses", "Pictures/Status Saver", 25, (5, 30, 90), (720, 1280), 30,
      "h264", 2000, 128, "status", noise=14, rate=44100, exact30=0.15),
    # Originals sent as documents are not recompressed: an iPhone's 1080p HEVC.
    P("wa_docs_iphone", WAG, "iPhone videos sent as documents", WA + "/WhatsApp Documents", 8, (30, 180, 600),
      (1920, 1080), 30, "hevc", 7800, 160, "iphone", rot=((90, 1.0),), noise=18, rate=44100, container="mov"),
    P("reels", SHORT, "Instagram reels (saved in the app)", "Movies/Instagram", 30, (6, 25, 180), (720, 1280),
      30, "h264", 3000, 128, "instagram", noise=14, rate=44100),  # [E: bitrate]
    P("short_dl", SHORT, "Reels / Shorts / Moj / ShareChat downloads", "Download", 25, (6, 22, 60),
      (720, 1280), 30, "h264", 1400, 72, "short", noise=14),
    P("yt_720", YT, "YouTube downloads 720p (Snaptube)", "snaptube/download/SnapTube Video", 12,
      (120, 600, 3600), (1280, 720), 30, "h264", 1300, 128, "youtube", noise=10, rate=44100),
    # realme's recorder at its native size [E: size, bitrate, folder].
    P("screen_apps", SCREEN, "Screen recordings (apps, calls)", "DCIM/Screenshots", 8, (10, 90, 600),
      (1080, 2412), 30, "h264", 10000, 128, "screen", noise=2),
    P("screen_games", SCREEN, "Screen recordings (games)", "DCIM/Screenshots", 5, (120, 600, 1800),
      (2412, 1080), 30, "h264", 10000, 128, "screen", noise=12),
    P("tg_episodes", TG, "Telegram web-series episodes 720p", "Download/Telegram", 6, (2100, 2580, 3300),
      (1280, 720), 23.976, "h264", 1000, 128, "episode", noise=10),  # [E: bitrate]
    P("tg_movies", TG, "Telegram movies 720p HEVC", "Download/Telegram", 2, (7800, 9000, 10200), (1280, 536),
      23.976, "hevc", 900, 128, "movie", noise=10),  # [E: bitrate]
]


def durations(p, rng):
    """A profile's lengths: log-normal between its shortest and longest,
    averaging its mean, with WhatsApp's share of clips cut at 30 s."""
    lo, mean, hi = p["dur"]
    sigma = math.log(hi / lo) / 5
    d = [min(max(mean * math.exp(rng.gauss(0, sigma)), lo), hi) for _ in range(p["count"])]
    for _ in range(4):
        k = mean / (sum(d) / len(d))
        d = [min(max(x * k, lo), hi) for x in d]
    for i in range(len(d)):
        if lo <= 30 <= hi and rng.random() < p["exact30"]:
            d[i] = 30.0
    return d


def draw():
    """The library: every file's kind, real length, bitrate, name and place."""
    rng = random.Random(SEED)
    start = datetime.datetime(2023, 7, 1)
    files = []
    for p in PROFILES:
        for i, real in enumerate(durations(p, rng)):
            rot = 0
            r = rng.random()
            for angle, share in p["rot"]:
                if r < share:
                    rot = angle
                    break
                r -= share
            w, h = p["width"], p["height"]
            if rng.random() < p["landscape"]:
                w, h = h, w
            files.append(dict(p=p, i=i, real_s=real, width=w, height=h, rot=rot,
                              video_kbps=round(p["video_kbps"] * rng.uniform(1 - SPREAD, 1 + SPREAD)),
                              when=start + datetime.timedelta(seconds=rng.randrange(0, 820 * 86400)),
                              n=rng.randrange(1000, 9999)))
    total = sum((f["video_kbps"] + f["p"]["audio_kbps"]) * 1000 / 8 * f["real_s"] for f in files)
    k = LIBRARY_GB * 1e9 / total
    seen = set()
    for idx, f in enumerate(files):
        f["real_s"] = round(f["real_s"] * k, 1)
        f["gen_s"] = round(min(max(f["real_s"] * SCALE, MIN_S), MAX_S), 1)
        name = name_for(f["p"]["names"], f, idx)
        while name.lower() in seen:
            f["when"] += datetime.timedelta(seconds=1)
            f["n"] += 1
            name = name_for(f["p"]["names"], f, idx)
        seen.add(name.lower())
        f["name"] = name
        f["seed"] = idx + 1
    return files


def name_for(style, f, idx):
    t, n = f["when"], f["n"]
    if style == "camera":
        return t.strftime("VID%Y%m%d%H%M%S") + ".mp4"
    if style == "whatsapp":
        return t.strftime("VID-%Y%m%d-WA") + f"{n % 10000:04d}.mp4"
    if style == "status":
        return f"{(n * 2654435761 + idx) & 0xFFFFFFFF:08x}{t.strftime('%d%H%M%S')}.mp4"
    if style == "iphone":
        return f"IMG_{n:04d}.MOV"
    if style == "instagram":
        return f"VID_{n}{t.strftime('%m%d')}_{t.strftime('%H%M%S')}_{idx % 1000:03d}.mp4"
    if style == "short":
        app = ("Moj", "ShareChat", "Josh", "Shorts", "Reel")[idx % 5]
        return f"{app}_{t.strftime('%Y%m%d_%H%M%S')}.mp4"
    if style == "youtube":
        return f"Video {n}(720P_HD).mp4"
    if style == "screen":
        return t.strftime("Screen_Recording_%Y%m%d_%H%M%S") + ".mp4"
    if style == "episode":
        return f"Series {n % 7 + 1} S01E{f['i'] + 1:02d} 720p.mp4"
    if style == "movie":
        return f"Movie {n} ({t.year}) 720p HEVC.mp4"
    raise ValueError(style)


def manifest_rows(files, shards):
    for idx, f in enumerate(files):
        p = f["p"]
        yield dict(name=f["name"], profile=p["id"], group=p["group"], label=p["label"], folder=p["folder"],
                   real_s=f["real_s"], gen_s=f["gen_s"], width=f["width"], height=f["height"], rotation=f["rot"],
                   fps=p["fps"], codec=p["codec"], video_kbps=f["video_kbps"], audio_kbps=p["audio_kbps"],
                   in_gallery=0 if p["hidden"] else 1, shard=idx % shards, seed=f["seed"])


def rate_of(fps):
    return "24000/1001" if abs(fps - 23.976) < 0.01 else str(fps)


def make_one(f, out_root):
    """One file, at its real bitrate and its made length."""
    p = f["p"]
    folder = os.path.join(out_root, p["folder"])
    os.makedirs(folder, exist_ok=True)
    if p["hidden"]:
        open(os.path.join(folder, ".nomedia"), "a").close()
    dest = os.path.join(folder, f["name"])
    fmt = p["container"]
    tmp = dest + ".tmp." + fmt
    s, fps, ak = f["gen_s"], p["fps"], p["audio_kbps"]
    gop = round(fps)
    video = (f"testsrc2=size={f['width']}x{f['height']}:rate={rate_of(fps)}:duration={s},"
             f"noise=alls={p['noise']}:allf=t+u:all_seed={f['seed']},format=yuv420p")
    audio = f"anoisesrc=color=pink:amplitude=0.05:sample_rate={p['sample_rate']}:duration={s}:seed={f['seed']}"
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", video,
           "-f", "lavfi", "-i", audio]
    if p["codec"] == "hevc":
        vk = f["video_kbps"]
        cmd += ["-c:v", "libx265", "-preset", "ultrafast", "-tag:v", "hvc1", "-x265-params",
                f"bitrate={vk}:vbv-maxrate={vk}:vbv-bufsize={vk}:keyint={gop}:strict-cbr=1:log-level=error"]
    else:
        vk = round(f["video_kbps"] * X264_ASK)
        cmd += ["-c:v", "libx264", "-preset", "ultrafast", "-g", str(gop), "-b:v", f"{vk}k", "-minrate", f"{vk}k",
                "-maxrate", f"{vk}k", "-bufsize", f"{vk}k", "-x264-params", "nal-hrd=cbr:force-cfr=1"]
    cmd += ["-c:a", "aac", "-b:a", f"{ak}k", "-ac", str(p["channels"]), "-threads", "2",
            "-metadata", "creation_time=" + f["when"].strftime("%Y-%m-%dT%H:%M:%SZ"),
            "-movflags", "+faststart", "-f", fmt, tmp if f["rot"] else dest]
    subprocess.run(cmd, check=True)
    if f["rot"]:
        # A camera writes upright clips as landscape pixels plus a rotation
        # tag; ffmpeg counts the other way, so -90 here reads back as 90.
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-display_rotation:v:0",
                        str(-f["rot"]), "-i", tmp, "-c", "copy", "-movflags", "+faststart", "-f", fmt, dest],
                       check=True)
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
        gb = sum((float(r["video_kbps"]) + float(r["audio_kbps"])) * 1000 / 8 * float(r["real_s"]) for r in rows)
        hours = sum(float(r["real_s"]) for r in rows) / 3600
        print(f"{len(rows)} videos, about {gb / 1e9:.1f} GB, {hours:.1f} hours")
        return

    mine = [f for idx, f in enumerate(files) if idx % a.shards == a.shard]
    if a.only:
        keep = set(a.only.split(","))
        mine = [f for f in mine if f["p"]["id"] in keep]
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as pool:
        made = list(pool.map(lambda f: make_one(f, a.out), mine))
    made_csv = os.path.join(os.path.dirname(os.path.abspath(a.out)), os.path.basename(a.out) + "-made.csv")
    with open(made_csv, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["name", "gen_s", "bytes"])
        w.writerows(made)
    # What the emulator's gallery should end up listing: the hidden folders' files never appear.
    with open(made_csv.replace("-made.csv", "-in-gallery.txt"), "w") as fh:
        fh.write(f"{sum(1 for f in mine if not f['p']['hidden'])}\n")
    print(f"made {len(made)} videos, {sum(s for _, _, s in made) / 1e9:.2f} GB, "
          f"{sum(g for _, g, _ in made) / 60:.1f} minutes, listed in {made_csv}")


if __name__ == "__main__":
    sys.exit(main())
