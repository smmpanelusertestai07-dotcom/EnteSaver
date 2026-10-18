#!/usr/bin/env python3
"""The savings benchmark's video library (v3): one ordinary phone's worth of videos.

Every kind of video is described once, in PROFILES: where Android keeps it,
its resolution, rotation, frame rate, codec, bitrate and sound, how long such
videos run, and what is in the picture. The numbers are a Realme 11 Pro 5G's
own camera where they have been measured (1080p30 H.264 at 20 Mbps, 4K at
50 Mbps, AAC at 256 kbps) and what WhatsApp, Instagram, YouTube downloaders,
the screen recorder and Telegram actually write; the rest are estimates,
marked in the table. A fixed seed draws the library from it - the same files
on every run - and sizes it to LIBRARY_GB.

The files themselves are made shorter than the videos they stand for (gen_s
against real_s), so eight emulators get through the whole library in one CI
run. Everything the app decides by - resolution, rotation, frame rate, codec,
bitrate, sound, container - is the real video's, and at a fixed bitrate a
file's size grows in step with its length, so report.py can put each measured
result back at the real length. Clips that really are a few seconds long (an
accidental tap, a WhatsApp GIF) are made at their real length.

What is in the picture is a scene, drawn per file from its profile's mix
(the manifest's scene column):

  day     a daylight camera pan: a large detailed plate - a fractal under
          four octaves of texture, with signs and buildings - panned and
          slowly zoomed by hand, leaves moving, mild sensor noise
  night   night or indoors: the same, darker, with lights and strong noise
  motion  high motion: fast pans and zooms, many fast objects, some
          spinning, leaves, flicker - the hardest
  static  mostly static: a talking head in front of a still scene - easy
  screen  a phone's screen: flat colours, a feed of text in a system font
          scrolled in flings, sometimes a video playing, almost no noise
  game    gameplay: a colourful world turning and zooming, sprites, sparks
          and a HUD, no sensor noise

v3 keeps v2's 491 files and 46 GB and makes the pictures harder: more of
the camera's clips and of the forwards are in motion or at night (camera:
30% motion and 30% night, was 25% and 25%; forwards: 30% motion, was 20%),
and the long function videos are 35% motion (was 30%).

The v1 library was one test pattern under uniform noise in every file. When
v2 was made, one file of every kind and scene was made both ways - same size,
rate, bitrate and encoder - re-encoded by x264 (veryfast) at the app's
standard bitrate and scored against its source; weighted by the library's
real bytes, v2 loses twice v1's VMAF (92.1 down to 83.8), 1.4 times its SSIM
(0.940 down to 0.915) and 2.3 dB more PSNR. Night, motion and gameplay are
the hard ones; a talking head and a screen are easier than v1 was, as they
are in life.

  library.py manifest --out manifest.csv [--summary]
  library.py make --shard 0 --shards 8 --out bench-library
"""
import argparse
import concurrent.futures
import csv
import datetime
import math
import os
import random
import shutil
import subprocess
import sys
import time

LIBRARY_GB = 46.0
SEED = 20231016
# A made file is this share of the real video's length, but never shorter
# than MIN_S or longer than MAX_S. An encoder spends a burst of about 0.7 s
# worth of bits getting started, whatever the length - a quarter more than
# its rate on a 3 s clip, which a 37 s camera clip never shows - so no file
# is shorter than 20 s, where the burst is under 4%; profiles marked exact
# are short in real life too and are made at their real length.
SCALE, MIN_S, MAX_S = 0.08, 20.0, 45.0
# x264's constant-bitrate mode lands a little over the asked-for rate (the
# first keyframe, the HRD's padding); asking for this share of it lands on the
# real rate. x265's strict CBR lands on it as asked.
X264_ASK = 0.985
# Real files are not all at one rate: each is drawn within this much of its
# profile's.
SPREAD = 0.15
# The quality sample: this many files of every kind, plus every file longer
# than KEEP_LONG_S, have the app's copy kept and graded (quality.py).
KEEP_PER_PROFILE = 2
KEEP_LONG_S = 20 * 60
# The plates the camera, screen and game scenes are cut from.
PLATE_W, PLATE_H = 4096, 2304
CAMERA_PLATES, GAME_PLATES = 4, 2

WA = "Android/media/com.whatsapp/WhatsApp/Media"

SCENES = {
    "day": "Daylight camera pan",
    "night": "Night / indoor",
    "motion": "High motion",
    "static": "Mostly static (talking head)",
    "screen": "Screen UI",
    "game": "Gameplay",
}

# How each camera scene moves, in shares of the frame's long side: pan speed
# per second, zoom (amplitude, cycles per second), handheld shake, moving
# objects (count, speed, size as a share of the height, spinning), leaves (share
# of the height they fill), brightness flicker, lights, darkening, and sensor
# noise (luma, chroma) as ffmpeg's noise filter strengths.
CAMERA_TUNE = {
    "day": dict(pan=0.08, zoom=0.06, zoom_hz=0.05, shake=0.002, movers=2, speed=0.06, size=(0.2, 0.3), spin=False,
                leaves=0.35, flicker=0.0, lights=0, dark=False, noise=(5, 3)),
    "night": dict(pan=0.03, zoom=0.05, zoom_hz=0.04, shake=0.0025, movers=3, speed=0.05, size=(0.2, 0.3), spin=False,
                  leaves=0.0, flicker=0.03, lights=4, dark=True, noise=(11, 6)),
    "motion": dict(pan=0.68, zoom=0.25, zoom_hz=0.30, shake=0.005, movers=10, speed=0.57, size=(0.12, 0.3), spin=True,
                   leaves=0.5, flicker=0.05, lights=0, dark=False, noise=(8, 4)),
    "static": dict(pan=0.0, zoom=0.0, zoom_hz=0.0, shake=0.0008, movers=0, speed=0.0, size=(0.4, 0.45), spin=False,
                   leaves=0.0, flicker=0.0, lights=0, dark=False, noise=(4, 2)),
}

# The camera's mixes: most clips are of people and places by day, evenings
# and indoor functions, children and festivals in motion, and a few still.
CAMERA_MIX = dict(day=0.25, night=0.30, motion=0.30, static=0.15)
FORWARD_MIX = dict(day=0.25, night=0.25, static=0.20, motion=0.30)


def P(pid, group, label, folder, count, dur, size, fps, codec, vkbps, akbps, names, scenes, rot=(), landscape=0.0,
      channels=2, rate=48000, container="mp4", exact30=0.0, hidden=False, exact=False, silent=0.0, mono=0.0,
      variants=(), fixed=(), bframes=0, profile="", compressed=False, noise_k=1.0, era=(2023, 7, 1, 820)):
    """One kind of video. dur is (shortest, mean, longest) in seconds; size is
    width x height as stored; rot lists (rotation, share) for the files a
    camera tags as turned; landscape is the share of a portrait profile whose
    pixels are stored the other way round; hidden folders carry a .nomedia,
    as the app that writes them leaves one, so no gallery - Ente Saver's
    included - ever sees what is in them. scenes is the mix of pictures;
    exact files are made at their real length; silent and mono are the shares
    of files with no sound track and with one channel; variants are other
    sizes the kind comes in, used in turn; fixed gives the real lengths of the
    kind's longest files outright; compressed marks videos that another app
    (WhatsApp, Instagram, YouTube, Telegram) had already compressed before they
    reached the phone; era is (year, month, day, days) of the files' dates."""
    w, h = size
    return dict(id=pid, group=group, label=label, folder=folder, count=count, dur=dur, width=w, height=h,
                fps=fps, codec=codec, video_kbps=vkbps, audio_kbps=akbps, names=names, scenes=scenes, rot=rot,
                landscape=landscape, channels=channels, sample_rate=rate, container=container, exact30=exact30,
                hidden=hidden, exact=exact, silent=silent, mono=mono, variants=variants, fixed=fixed,
                bframes=bframes, profile=profile, compressed=compressed, noise_k=noise_k, era=era)


CAM, WAG, SHORT, YT, SCREEN, TG, OLD = ("Camera", "WhatsApp", "Reels and short videos", "YouTube downloads",
                                        "Screen recordings", "Telegram", "From older phones")

# [E] marks an estimate; everything else was measured or is documented.
PROFILES = [
    # Realme 11 Pro 5G rear camera, default 1080p30 H.264, 20 Mbps, AAC 256k.
    P("cam_1080p30", CAM, "Camera 1080p 30fps (default)", "DCIM/Camera", 100, (3, 37, 300), (1920, 1080), 30,
      "h264", 20000, 256, "camera", CAMERA_MIX, rot=((90, 0.75),)),
    # Weddings, pujas, birthdays, school functions, mostly indoors and in the
    # evening [E: lengths]; the two longest run 22 and 26 minutes in one take.
    P("cam_long", CAM, "Long function videos", "DCIM/Camera", 9, (300, 560, 1100), (1920, 1080), 30, "h264",
      20000, 256, "camera", dict(night=0.5, motion=0.35, static=0.1, day=0.05), rot=((90, 0.4),), fixed=(1320, 1560)),
    P("cam_4k", CAM, "Camera 4K 30fps", "DCIM/Camera", 12, (5, 40, 180), (3840, 2160), 30, "h264", 50000, 256,
      "camera", dict(day=0.6, motion=0.2, night=0.2)),
    P("cam_1080p60", CAM, "Camera 1080p 60fps", "DCIM/Camera", 10, (5, 30, 120), (1920, 1080), 60, "h264",
      30000, 256, "camera", dict(motion=0.5, day=0.3, night=0.2)),  # [E: bitrate]
    P("cam_slowmo", CAM, "Camera slow motion 1080p 120fps", "DCIM/Camera", 6, (3, 12, 30), (1920, 1080), 120,
      "h264", 40000, 256, "camera", dict(motion=0.8, day=0.2), rot=((90, 1.0),)),  # [E: bitrate]
    P("cam_front", CAM, "Front camera 1080p", "DCIM/Camera", 22, (3, 30, 180), (1920, 1080), 30, "h264", 20000,
      256, "camera", dict(static=0.6, night=0.25, day=0.15), rot=((270, 1.0),)),  # [E: bitrate]
    # WhatsApp: 480p standard, 720p HD [E: bitrates].
    P("wa_sd", WAG, "WhatsApp videos (standard)", WA + "/WhatsApp Video", 105, (3, 45, 600), (480, 848), 30,
      "h264", 1200, 96, "whatsapp", FORWARD_MIX, landscape=0.4, rate=44100, exact30=0.15, mono=0.3,
      compressed=True),
    P("wa_hd", WAG, "WhatsApp videos (HD)", WA + "/WhatsApp Video", 30, (3, 40, 300), (720, 1280), 30, "h264",
      2500, 128, "whatsapp", FORWARD_MIX, landscape=0.4, rate=44100, exact30=0.15, mono=0.2, compressed=True),
    # WhatsApp keeps a .nomedia in Sent, so these are on the phone but in no gallery.
    P("wa_sent", WAG, "WhatsApp sent copies", WA + "/WhatsApp Video/Sent", 22, (3, 30, 180), (480, 848), 30,
      "h264", 1200, 96, "whatsapp", FORWARD_MIX, landscape=0.4, rate=44100, hidden=True, mono=0.3,
      compressed=True),
    P("wa_status", WAG, "Saved WhatsApp statuses", "Pictures/Status Saver", 20, (5, 30, 90), (720, 1280), 30,
      "h264", 2000, 128, "status", dict(static=0.3, day=0.25, motion=0.25, screen=0.2), rate=44100, exact30=0.15,
      compressed=True),
    # Originals sent as documents are not recompressed: an iPhone's 1080p HEVC.
    P("wa_docs_iphone", WAG, "iPhone videos sent as documents", WA + "/WhatsApp Documents", 8, (30, 180, 600),
      (1920, 1080), 30, "hevc", 7800, 160, "iphone", dict(day=0.5, night=0.25, motion=0.25), rot=((90, 1.0),),
      rate=44100, container="mov"),
    P("reels", SHORT, "Instagram reels (saved in the app)", "Movies/Instagram", 26, (6, 25, 180), (720, 1280),
      30, "h264", 3000, 128, "instagram", dict(motion=0.4, day=0.3, night=0.15, static=0.15), rate=44100,
      bframes=2, compressed=True),  # [E: bitrate]
    P("short_dl", SHORT, "Reels / Shorts / Moj / ShareChat downloads", "Download", 21, (6, 22, 60),
      (720, 1280), 30, "h264", 1400, 72, "short", dict(motion=0.4, static=0.3, day=0.3), bframes=2,
      compressed=True),
    P("yt_720", YT, "YouTube downloads 720p (Snaptube)", "snaptube/download/SnapTube Video", 12,
      (120, 600, 3600), (1280, 720), 30, "h264", 1300, 128, "youtube",
      dict(static=0.4, day=0.3, screen=0.15, motion=0.15), rate=44100, bframes=2, compressed=True),
    # realme's recorder at its native size [E: size, bitrate, folder]; it
    # records no sound unless asked to.
    P("screen_apps", SCREEN, "Screen recordings (apps, calls)", "DCIM/Screenshots", 8, (10, 90, 600),
      (1080, 2412), 30, "h264", 10000, 128, "screen", dict(screen=1.0), silent=0.4),
    P("screen_games", SCREEN, "Screen recordings (games)", "DCIM/Screenshots", 5, (120, 600, 1800),
      (2412, 1080), 30, "h264", 10000, 128, "screen", dict(game=1.0)),
    P("tg_episodes", TG, "Telegram web-series episodes 720p", "Download/Telegram", 6, (2100, 2580, 3300),
      (1280, 720), 23.976, "h264", 1000, 128, "episode", dict(static=0.4, night=0.3, day=0.15, motion=0.15),
      bframes=2, compressed=True),  # [E: bitrate]
    P("tg_movies", TG, "Telegram movies 720p HEVC", "Download/Telegram", 2, (7800, 9000, 10200), (1280, 536),
      23.976, "hevc", 900, 128, "movie", dict(night=0.35, motion=0.25, static=0.25, day=0.15),
      compressed=True),  # [E: bitrate]
    # What v1 did not have: the camera's other modes, clips a few seconds
    # long, files with one channel or none, and the odd sizes other phones and
    # apps leave behind.
    P("cam_720p", CAM, "Camera 720p 30fps", "DCIM/Camera", 15, (3, 30, 240), (1280, 720), 30, "h264", 10000, 256,
      "camera", CAMERA_MIX, rot=((90, 0.7),)),  # [E: bitrate]
    P("cam_timelapse", CAM, "Camera time-lapse (no sound)", "DCIM/Camera", 5, (5, 15, 40), (1920, 1080), 30,
      "h264", 20000, 0, "camera", dict(day=0.6, motion=0.4), rot=((90, 0.5),), silent=1.0),  # [E: bitrate]
    P("cam_short", CAM, "Very short camera clips (1-3 s)", "DCIM/Camera", 10, (1, 2, 3), (1920, 1080), 30, "h264",
      20000, 256, "camera", dict(day=0.4, night=0.3, motion=0.3), rot=((90, 0.75),), exact=True),
    P("wa_gif", WAG, "WhatsApp GIFs (MP4, no sound)", WA + "/WhatsApp Animated Gifs", 12, (1, 3, 6), (480, 270),
      25, "h264", 600, 0, "whatsapp", dict(motion=0.5, static=0.3, game=0.2), landscape=0.3, silent=1.0,
      exact=True, compressed=True),  # [E: size, bitrate]
    P("ig_square", SHORT, "Instagram square posts (1080x1080)", "Download", 8, (5, 25, 60), (1080, 1080), 30,
      "h264", 3500, 128, "insta", dict(day=0.4, motion=0.3, static=0.3), rate=44100, bframes=2,
      compressed=True),  # [E: bitrate]
    # Brought over from the previous phone with Clone Phone: a Samsung's 3:4
    # mode (1440x1080) and a Redmi's screen recorder (1080x2340, the mic in
    # mono) [E: bitrates].
    P("old_43", OLD, "Older phone's 3:4 videos (1440x1080)", "DCIM/Camera", 6, (5, 40, 200), (1440, 1080), 30,
      "h264", 13000, 256, "samsung", dict(day=0.4, night=0.3, motion=0.3), rot=((90, 0.6),),
      era=(2019, 3, 1, 1300)),
    P("old_screen", OLD, "Older phone's screen recordings (1080x2340)", "DCIM/ScreenRecorder", 5, (10, 60, 300),
      (1080, 2340), 30, "h264", 8000, 96, "miui", dict(screen=0.6, game=0.4), channels=1, rate=44100,
      era=(2020, 1, 1, 1000)),
    # A feature phone's and an early smartphone's clips, sent over Bluetooth
    # long ago: H.264 and AAC in 3GP, one channel [E: bitrates].
    P("old_3gp", OLD, "Old phone clips (3GP)", "Bluetooth", 6, (5, 40, 180), (640, 480), 30, "h264", 2000, 64,
      "nokia", dict(day=0.5, night=0.3, static=0.2), channels=1, rate=22050, container="3gp", profile="baseline",
      noise_k=1.4, era=(2011, 1, 1, 1400),
      variants=(dict(), dict(width=352, height=288, fps=15, video_kbps=384, audio_kbps=32, sample_rate=16000))),
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


def mixed(weights, n, rng):
    """n scene names in the given proportions, as near as whole files allow,
    in a shuffled order."""
    names = list(weights)
    total = sum(weights.values())
    raw = [weights[k] / total * n for k in names]
    counts = [int(x) for x in raw]
    for i in sorted(range(len(names)), key=lambda i: raw[i] - counts[i], reverse=True)[:n - sum(counts)]:
        counts[i] += 1
    seq = [names[i] for i in range(len(names)) for _ in range(counts[i])]
    rng.shuffle(seq)
    return seq


def draw():
    """The library: every file's kind, real length, bitrate, picture, name and place."""
    rng = random.Random(SEED)
    files = []
    for p in PROFILES:
        lengths = durations(p, rng)
        fixed = list(p["fixed"])
        if fixed:
            order = sorted(range(len(lengths)), key=lambda i: lengths[i])
            for i, real in zip(order[-len(fixed):], fixed):
                lengths[i] = float(real)
        scenes = mixed(p["scenes"], p["count"], rng)
        y, mo, day, span = p["era"]
        start = datetime.datetime(y, mo, day)
        for i, real in enumerate(lengths):
            rot = 0
            r = rng.random()
            for angle, share in p["rot"]:
                if r < share:
                    rot = angle
                    break
                r -= share
            v = dict(width=p["width"], height=p["height"], fps=p["fps"], video_kbps=p["video_kbps"],
                     audio_kbps=p["audio_kbps"], sample_rate=p["sample_rate"])
            if p["variants"]:
                v.update(p["variants"][i % len(p["variants"])])
            w, h = v["width"], v["height"]
            if rng.random() < p["landscape"]:
                w, h = h, w
            channels = p["channels"]
            akbps = v["audio_kbps"]
            if rng.random() < p["silent"] or akbps == 0:
                channels, akbps = 0, 0
            elif channels == 2 and rng.random() < p["mono"]:
                channels, akbps = 1, round(akbps * 2 / 3)
            files.append(dict(p=p, i=i, real_s=real, width=w, height=h, rot=rot, fps=v["fps"],
                              video_kbps=round(v["video_kbps"] * rng.uniform(1 - SPREAD, 1 + SPREAD)),
                              audio_kbps=akbps, channels=channels, sample_rate=v["sample_rate"], scene=scenes[i],
                              fixed=p["exact"] or real in fixed,
                              when=start + datetime.timedelta(seconds=rng.randrange(0, span * 86400)),
                              n=rng.randrange(1000, 9999)))
    size = lambda f: (f["video_kbps"] + f["audio_kbps"]) * 1000 / 8 * f["real_s"]
    k = (LIBRARY_GB * 1e9 - sum(size(f) for f in files if f["fixed"])) / sum(size(f) for f in files if not f["fixed"])
    seen = set()
    for idx, f in enumerate(files):
        if f["p"]["exact"]:
            f["real_s"] = f["gen_s"] = round(max(f["real_s"], 1.0), 1)
        else:
            if not f["fixed"]:
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
    taken = {}
    for f in files:
        pid = f["p"]["id"]
        f["keep"] = taken.get(pid, 0) < KEEP_PER_PROFILE or f["real_s"] > KEEP_LONG_S
        taken[pid] = taken.get(pid, 0) + 1
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
    if style == "insta":
        return f"Insta_{n}{t.strftime('%y%m%d%H%M')}.mp4"
    if style == "youtube":
        return f"Video {n}(720P_HD).mp4"
    if style == "screen":
        return t.strftime("Screen_Recording_%Y%m%d_%H%M%S") + ".mp4"
    if style == "episode":
        return f"Series {n % 7 + 1} S01E{f['i'] + 1:02d} 720p.mp4"
    if style == "movie":
        return f"Movie {n} ({t.year}) 720p HEVC.mp4"
    if style == "samsung":
        return t.strftime("%Y%m%d_%H%M%S") + ".mp4"
    if style == "miui":
        return t.strftime("Screenrecorder-%Y-%m-%d-%H-%M-%S-") + f"{n % 1000:03d}.mp4"
    if style == "nokia":
        return f"Video{n % 1000:04d}.3gp" if f["i"] % 2 else t.strftime("VID_%Y%m%d_%H%M%S") + ".3gp"
    raise ValueError(style)


def manifest_rows(files, shards):
    for idx, f in enumerate(files):
        p = f["p"]
        yield dict(name=f["name"], profile=p["id"], group=p["group"], label=p["label"], folder=p["folder"],
                   real_s=f["real_s"], gen_s=f["gen_s"], width=f["width"], height=f["height"], rotation=f["rot"],
                   fps=f["fps"], codec=p["codec"], video_kbps=f["video_kbps"], audio_kbps=f["audio_kbps"],
                   in_gallery=0 if p["hidden"] else 1, shard=idx % shards, seed=f["seed"], scene=f["scene"],
                   channels=f["channels"], container=p["container"], already_compressed=int(p["compressed"]),
                   keep=int(f["keep"]))


def summary_lines(rows):
    """Videos, real GB and hours by kind and by scene."""
    gb = lambda r: (float(r["video_kbps"]) + float(r["audio_kbps"])) * 1000 / 8 * float(r["real_s"]) / 1e9
    out = []
    for key, title, label in (("profile", "kind", lambda r: r["label"]),
                              ("scene", "scene", lambda r: SCENES[r["scene"]])):
        table = {}
        for r in rows:
            t = table.setdefault(r[key], dict(label=label(r), n=0, gb=0.0, h=0.0, gen=0.0, long=0))
            t["n"] += 1
            t["gb"] += gb(r)
            t["h"] += float(r["real_s"]) / 3600
            t["gen"] += float(r["gen_s"]) / 60
            t["long"] += float(r["real_s"]) > KEEP_LONG_S
        out.append(f"By {title}: videos, GB, hours (made minutes, longer than 20 min)")
        for k, t in table.items():
            out.append(f"  {t['label']:46s} {t['n']:4d} {t['gb']:6.2f} {t['h']:6.2f}  ({t['gen']:5.1f}, {t['long']})")
    mono = sum(1 for r in rows if r["channels"] == 1 or r["channels"] == "1")
    silent = sum(1 for r in rows if str(r["channels"]) == "0")
    short = sum(1 for r in rows if float(r["real_s"]) <= 3.5)
    long = sum(1 for r in rows if float(r["real_s"]) > KEEP_LONG_S)
    keep = sum(1 for r in rows if str(r["keep"]) == "1")
    out.append(f"Mono: {mono}, no sound: {silent}, 3.5 s or shorter: {short}, longer than 20 min: {long}, "
               f"quality sample: {keep}")
    return out


def rate_of(fps):
    return "24000/1001" if abs(fps - 23.976) < 0.01 else f"{fps:g}"


def find_font():
    """A system font for the screen and game text; None leaves text out."""
    for path in ("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", "/usr/share/fonts/dejavu/DejaVuSans.ttf",
                 "/usr/share/fonts/TTF/DejaVuSans.ttf",
                 "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf"):
        if os.path.isfile(path):
            return path
    try:
        path = subprocess.run(["fc-match", "-f", "%{file}", "sans"], capture_output=True, text=True,
                              timeout=20).stdout.strip()
        if path and os.path.isfile(path) and ":" not in path and "'" not in path:
            return path
    except (OSError, subprocess.SubprocessError):
        pass
    return None


# Places in the Mandelbrot set with detail at every scale: (x, y, view width).
SPOTS = [(-0.7453, 0.1127, 0.012), (-0.7436, 0.1318, 0.02), (-0.088, 0.654, 0.03), (-1.25066, 0.02012, 0.004),
         (-0.16, 1.0405, 0.025), (0.2925, 0.0149, 0.006), (-0.722, 0.246, 0.02), (-0.235125, 0.827215, 0.008)]
SIGNS = ["SALE 50%", "Sharma Sweets", "NO PARKING", "Gate No. 2", "OPEN", "Chai 10/-", "Happy Birthday",
         "Welcome", "Mobile Repair", "Jio 5G", "Shubh Vivah", "Ganesh Utsav"]


def plate_graph(kind, k, font):
    """One large still: a fractal at half size, four octaves of texture over
    it, then boxes and signs - straight edges and text a scene has."""
    rng = random.Random(SEED + 101 * k + (7 if kind == "game" else 0))
    w, h = PLATE_W, PLATE_H
    x, y, sc = SPOTS[(k + (3 if kind == "game" else 0)) % len(SPOTS)]
    sat = 1.3 if kind == "game" else 0.55
    g = [f"mandelbrot=s={w // 2}x{h // 2}:rate=1:maxiter=150:start_x={x}:start_y={y}:start_scale={sc}:"
         f"end_scale={sc}:outer=normalized_iteration_count:inner=mincol,trim=end_frame=1,"
         f"scale={w}x{h}:flags=bicubic,format=gbrp,hue=h={rng.uniform(-60, 60):.0f}:s={sat}[m]"]
    for o, d in enumerate((64, 16, 4, 1), 1):
        g.append(f"color=c=gray:s={w // d}x{h // d}:r=1,trim=end_frame=1,format=gray,"
                 f"noise=alls={100 - o * 15}:allf=u:all_seed={k * 10 + o},scale={w}x{h}:flags=bicubic,"
                 f"format=gbrp[n{o}]")
    g.append("[n1][n2]blend=all_mode=overlay[a];[a][n3]blend=all_mode=overlay[b];[b][n4]blend=all_mode=overlay[tex]")
    g.append("[m][tex]blend=all_mode=softlight,format=yuv420p[c]")
    marks = []
    for _ in range(14):
        bw, bh = rng.randrange(80, 700), rng.randrange(60, 900)
        bx, by = rng.randrange(0, w - bw), rng.randrange(0, h - bh)
        col = "0x%02x%02x%02x" % tuple(rng.randrange(30, 230) for _ in range(3))
        marks.append(f"drawbox=x={bx}:y={by}:w={bw}:h={bh}:color={col}@0.85:t=fill")
        if rng.random() < 0.6:
            marks.append(f"drawbox=x={bx}:y={by}:w={bw}:h={bh}:color=0x101010@0.9:t={rng.randrange(2, 9)}")
    if font:
        for i in range(5):
            marks.append(f"drawtext=fontfile={font}:expansion=none:text='{SIGNS[(k * 5 + i) % len(SIGNS)]}':"
                         f"fontsize={rng.randrange(40, 150)}:fontcolor=0x{rng.randrange(0x202020, 0xffffff):06x}:"
                         f"x={rng.randrange(0, w - 1000)}:y={rng.randrange(0, h - 200)}")
    g.append("[c]" + ",".join(marks) + "[out]")
    return ";".join(g)


def plate_path(work, kind, k):
    return os.path.join(work, f"plate-{kind}{k}.bmp")


def make_plate(work, kind, k, font):
    path = plate_path(work, kind, k)
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-filter_threads", "2",
                    "-filter_complex", plate_graph(kind, k, font), "-map", "[out]", "-frames:v", "1",
                    "-c:v", "bmp", "-pix_fmt", "bgr24", path], check=True)
    return path


def plate_for(f):
    # Files are dealt to shards in turn, so the plate follows the turn, not
    # the seed: each shard gets every plate.
    turn = (f["seed"] - 1) // 8
    if f["scene"] == "game":
        return "game", turn % GAME_PLATES
    return "cam", turn % CAMERA_PLATES


def even(v):
    return max(2, int(v) // 2 * 2)


def disc(label, sz, src, rng, plate_x=None, plate_y=None, scale=1.0, falloff=None, color=None):
    """A round object, sz pixels across, cut from the plate (src) or of one
    colour, with soft edges (or a glow), repeated for ever: [label]."""
    g = []
    if color:
        g.append(f"color=c={color}:s={sz}x{sz}:r=1,trim=end_frame=1,format=yuva420p[{label}c]")
    else:
        cut = even(sz * scale)
        x = plate_x if plate_x is not None else rng.randrange(0, PLATE_W - cut)
        y = plate_y if plate_y is not None else rng.randrange(0, PLATE_H - cut)
        g.append(f"[{src}]crop={cut}:{cut}:{x}:{y}" + (f",scale={sz}:{sz}" if cut != sz else "") +
                 f",format=yuva420p[{label}c]")
    r = sz // 2
    near = f"(1-hypot(X-{r},Y-{r})/{r})"
    edge = f"pow(clip({near},0,1),{falloff})" if falloff else f"clip(3*{near},0,1)"
    g.append(f"color=c=black:s={sz}x{sz}:r=1,trim=end_frame=1,format=gray,geq=lum='255*{edge}'[{label}m]")
    g.append(f"[{label}c][{label}m]alphamerge,loop=loop=-1:size=1:start=0[{label}]")
    return g


def camera_graph(f, rng, font):
    """day, night, motion, static: a moving window on the plate (input 0)."""
    t = CAMERA_TUNE[f["scene"]]
    w, h, fps = f["width"], f["height"], f["fps"]
    long_side = max(w, h)
    zmax = 1 + 2 * t["zoom"]
    # Plate pixels per output pixel: a 1080p frame is cut at 1:1, a smaller
    # one from a wider view (a phone's 480p is its 1080p made smaller), a 4K
    # one from a narrower view made larger - as dense in detail as a real one.
    ws = min(max(1920 / long_side, 0.6), 2.4, (PLATE_W - 96) / (w * zmax * 1.15), (PLATE_H - 96) / (h * zmax * 1.15))
    cw, ch = even(w * ws * zmax), even(h * ws * zmax)
    ax, ay = max(0, (PLATE_W - cw) // 2 - 8), max(0, (PLATE_H - ch) // 2 - 8)
    speed = t["pan"] * long_side * ws
    fx = min(speed / (2 * math.pi * ax), 0.5) if speed and ax else 0.0
    shake = t["shake"] * long_side * ws
    p1, p2 = rng.uniform(0, 6.28), rng.uniform(0, 6.28)
    x = (f"{PLATE_W // 2 - cw // 2}+{ax}*sin(2*PI*t*{fx:.5f}+{p1:.2f})+{shake:.1f}*sin(2*PI*t*1.3+{p2:.2f})"
         f"+{shake * 0.6:.1f}*sin(2*PI*t*3.1)")
    y = (f"{PLATE_H // 2 - ch // 2}+{int(ay * 0.5)}*sin(2*PI*t*{fx * 0.6:.5f}+{p2:.2f})"
         f"+{shake:.1f}*sin(2*PI*t*1.7+{p1:.2f})+{shake * 0.5:.1f}*sin(2*PI*t*2.3)")
    head = f["scene"] == "static"
    movers = t["movers"]
    cuts = 2 if head else movers  # objects cut from the plate; a head's mouth is a colour
    g = [f"[0:v]format=yuv420p,split={1 + cuts}[bg]" + "".join(f"[sp{i}]" for i in range(cuts)),
         f"[bg]loop=loop=-1:size=1:start=0,crop={cw}:{ch}:'{x}':'{y}'[pan]"]
    if t["zoom"]:
        z = f"{1 + t['zoom']:.3f}+{t['zoom']:.3f}*sin(2*PI*on/{fps:g}*{t['zoom_hz']:.3f}+{p1:.2f})"
        g.append(f"[pan]zoompan=z='{z}':x='iw/2-iw/zoom/2+{shake:.1f}*sin(on*0.9)':"
                 f"y='ih/2-ih/zoom/2+{shake:.1f}*sin(on*0.7)':d=1:s={w}x{h}:fps={rate_of(fps)}[cam]")
    else:
        g.append(f"[pan]crop={even(w * ws)}:{even(h * ws)}" + (f",scale={w}:{h}" if abs(ws - 1) > 1e-6 else "") +
                 "[cam]")
    last = "cam"
    if t["leaves"]:
        lh = even(h * t["leaves"])
        g.append(f"life=s={max(32, w // 4)}x{max(16, lh // 4)}:r={rate_of(fps)}:ratio=0.45:mold=12:"
                 f"life_color=0x5a8f3a:death_color=0x1f3315:mold_color=0x3d6b2a:seed={f['seed']},"
                 f"scale={w}:{lh}:flags=bicubic,format=yuva420p,lutyuv=a=128[lv]")
        g.append(f"[{last}][lv]overlay=0:{h - lh}[lvd]")
        last = "lvd"
    if head:
        # A talking head: shoulders, a head and a mouth that moves.
        hd = even(h * rng.uniform(*t["size"]))
        bx = rng.randrange(max(1, w // 2 - w // 6), max(2, w // 2 + w // 6)) - hd // 2
        by = int(h * 0.12)
        sway = f"{max(1, hd // 40)}*sin(2*PI*t*0.45+{p1:.2f})"
        bob = f"{max(1, hd // 35)}*sin(2*PI*t*0.8+{p2:.2f})"
        parts = [("body", even(hd * 1.7), f"{bx - int(hd * 0.35)}+{sway}", f"{by + int(hd * 0.85)}+{bob}/2", None),
                 ("head", hd, f"{bx}+{sway}", f"{by}+{bob}", None),
                 ("mouth", even(hd * 0.18), f"{bx + int(hd * 0.41)}+{sway}",
                  f"{by + int(hd * 0.68)}+{bob}+{max(1, hd // 50)}*sin(2*PI*t*5.3)", "0x3a1d1d")]
        for i, (label, sz, mx, my, color) in enumerate(parts):
            g += disc(label, sz, None if color else f"sp{i}", rng, scale=ws, color=color)
            g.append(f"[{last}][{label}]overlay=x='{mx}':y='{my}':eval=frame[o{i}]")
            last = f"o{i}"
    else:
        for i in range(movers):
            sz = even(h * rng.uniform(*t["size"]))
            g += disc(f"m{i}", sz, f"sp{i}", rng, scale=ws)
            if t["spin"] and i % 2 == 0:
                g[-1] = g[-1].replace(f"[m{i}]", f",rotate=a='t*{rng.uniform(1.5, 4):.2f}':c=none[m{i}]")
            period = (w + sz) / max(t["speed"] * long_side, 1) * rng.uniform(0.7, 1.3)
            mx = f"-{sz}+mod(t/{period:.3f}+{rng.random():.3f},1)*{w + sz}"
            if rng.random() < 0.5:
                mx = f"{w - sz}-({mx})"
            my = f"{rng.randrange(0, max(1, h - sz))}+{h // 6}*sin(2*PI*t*{rng.uniform(0.2, 0.9):.3f})"
            g.append(f"[{last}][m{i}]overlay=x='{mx}':y='{my}':eval=frame[o{i}]")
            last = f"o{i}"
    post = []
    if t["dark"]:
        post.append("eq=brightness=-0.10:contrast=0.75:gamma=0.55:saturation=0.8")
    if post:
        g.append(f"[{last}]" + ",".join(post) + "[dk]")
        last = "dk"
    for i in range(t["lights"]):
        sz = even(h * rng.uniform(0.08, 0.2))
        col = rng.choice(("0xffd890", "0xff9a50", "0x9fd0ff", "0xfff2c0", "0xff70b0"))
        g += disc(f"l{i}", sz, None, rng, color=col, falloff=1.6)
        lx = f"{rng.randrange(0, max(1, w - sz))}+{w // 50}*sin(2*PI*t*{rng.uniform(0.05, 0.2):.3f})"
        ly = f"{rng.randrange(0, max(1, h - sz))}+{h // 60}*sin(2*PI*t*{rng.uniform(0.05, 0.2):.3f})"
        g.append(f"[{last}][l{i}]overlay=x='{lx}':y='{ly}':eval=frame[li{i}]")
        last = f"li{i}"
    post = []
    if t["flicker"]:
        post.append(f"eq=brightness='{t['flicker']}*sin(2*PI*t*1.9)':eval=frame")
    # Noise is a sensor's, so a picture made smaller from a wider view has
    # less of it per pixel.
    k = f["p"]["noise_k"] / max(1.0, ws)
    ny, nc = max(1, round(t["noise"][0] * k)), max(1, round(t["noise"][1] * k))
    post.append(f"noise=c0s={ny}:c1s={nc}:c2s={nc}:allf=t:all_seed={f['seed']}")
    g.append(f"[{last}]" + ",".join(post) + ",format=yuv420p[v]")
    return ";".join(g)


FEED = ("namaste kal milte hain photo bhejo ok done order delivered recharge offer cashback UPI payment received "
        "250 rupees meeting at 5 pm shared a video reel like comment good morning ji happy diwali train late "
        "ticket confirmed PNR exam result class 10 tuition fees school bus mummy papa didi bhaiya cricket score "
        "India won by 6 wickets new song trending").split()


def screen_graph(f, rng, font, work):
    """A phone's screen: a long page of cards and text, flung up a screen at
    a time, sometimes a video playing at the top, the status bar on top."""
    w, h, fps = f["width"], f["height"], f["fps"]
    page_h = even(h * 6)
    dark = rng.random() < 0.35
    bg, ink = ("0x121212", "0xe8eaed") if dark else ("0xfafafa", "0x202124")
    marks, y0 = [], h // 10
    while y0 < page_h:
        card = rng.randrange(h // 10, h // 4)
        lo, hi = (24, 48) if dark else (200, 250)
        col = "0x%02x%02x%02x" % tuple(rng.randrange(lo, hi) for _ in range(3))
        marks.append(f"drawbox=x={w // 24}:y={y0}:w={w - w // 12}:h={card}:color={col}:t=fill")
        if rng.random() < 0.4:
            # A photo in the feed: a flat-coloured stand-in, as a screen
            # recording keeps whatever the app showed.
            pc = "0x%02x%02x%02x" % tuple(rng.randrange(40, 220) for _ in range(3))
            marks.append(f"drawbox=x={w // 12}:y={y0 + card // 6}:w={w // 3}:h={card * 2 // 3}:color={pc}:t=fill")
        y0 += card + h // 40
    fs = max(14, w // 26)
    if font:
        page = os.path.join(work, f"page-{f['seed']}.txt")
        with open(page, "w") as fh:
            for _ in range(page_h // (fs + fs // 2) + 2):
                fh.write(" ".join(rng.choice(FEED) for _ in range(rng.randrange(3, 7))) + "\n")
        marks.append(f"drawtext=fontfile={font}:expansion=none:textfile={os.path.basename(page)}:fontsize={fs}:"
                     f"fontcolor={ink}:line_spacing={fs // 2}:x={w // 8}:y={h // 30}")
    else:
        for yl in range(h // 30, page_h, fs + fs // 2):
            marks.append(f"drawbox=x={w // 8}:y={yl}:w={rng.randrange(w // 4, w * 3 // 4)}:h={fs * 2 // 3}:"
                         f"color={ink}:t=fill")
    fling = rng.uniform(2.2, 3.5)
    step = int(h * rng.uniform(0.4, 0.8))
    scroll = f"mod({step}*(floor(t/{fling:.2f})+min(1,mod(t,{fling:.2f})/0.5)),{page_h - h})"
    g = [f"color=c={bg}:s={w}x{page_h}:r={rate_of(fps)},trim=end_frame=1," + ",".join(marks) +
         ",format=yuv420p,loop=loop=-1:size=1:start=0[page]",
         f"[page]crop={w}:{h}:0:'{scroll}'[pc]"]
    last = "pc"
    if rng.random() < 0.5:
        vw, vh = w, even(w * 9 / 16)
        g.append(f"[0:v]format=yuv420p,loop=loop=-1:size=1:start=0,crop={vw}:{vh}:"
                 f"'{(PLATE_W - vw) // 2}+{(PLATE_W - vw) // 3}*sin(t*0.11)':'{(PLATE_H - vh) // 2}+"
                 f"{(PLATE_H - vh) // 3}*sin(t*0.07)',noise=c0s=2:allf=t[vid]")
        g.append(f"[{last}][vid]overlay=0:{h // 22}[pv]")
        last = "pv"
    bar = f"drawbox=x=0:y=0:w={w}:h={h // 28}:color=0x000000:t=fill"
    if font:
        bar += f",drawtext=fontfile={font}:text='10\\:24':fontsize={h // 50}:fontcolor=white:x={w // 30}:y={h // 200}"
    g.append(f"[{last}]{bar},noise=c0s=1:allf=t:all_seed={f['seed']},format=yuv420p[v]")
    return ";".join(g)


def game_graph(f, rng, font):
    """Gameplay: a colourful world turning and zooming under sprites, sparks
    and a HUD; rendered, so no sensor noise."""
    w, h, fps = f["width"], f["height"], f["fps"]
    ws = min(1.0, (PLATE_W - 96) / (w * 1.5), (PLATE_H - 96) / (h * 1.5))
    cw, ch = even(w * 1.5 * ws), even(h * 1.5 * ws)
    sprites = 6
    g = [f"[0:v]format=yuv420p,split={1 + sprites}[bg]" + "".join(f"[sp{i}]" for i in range(sprites)),
         f"[bg]loop=loop=-1:size=1:start=0,crop={cw}:{ch}:'{(PLATE_W - cw) // 2}+{(PLATE_W - cw) // 2 - 4}*sin(t*0.9)':"
         f"'{(PLATE_H - ch) // 2}+{(PLATE_H - ch) // 3}*sin(t*1.3)',"
         f"zoompan=z='1.2+0.1*sin(2*PI*on/{fps:g}*0.3)':x='iw/2-iw/zoom/2+30*sin(on*0.11)':y='ih/2-ih/zoom/2':"
         f"d=1:s={w}x{h}:fps={rate_of(fps)},hue=h='t*25'[cam0]",
         f"life=s={max(32, w // 12)}x{max(16, h // 8)}:r={rate_of(fps)}:ratio=0.3:mold=20:life_color=0xffcc33:"
         f"death_color=0x000000:mold_color=0xff3300:seed={f['seed']},scale={even(w / 3)}:{even(h / 2)}:"
         f"flags=bicubic,format=yuva420p,lutyuv=a=77[fx]",
         f"[cam0][fx]overlay=x='{w // 3}+{w // 4}*sin(t*0.7)':y='{h // 4}+{h // 5}*sin(t*1.1)'[cam]"]
    last = "cam"
    short = min(w, h)
    for i in range(sprites):
        sz = even(max(32, short // 6))
        g += disc(f"m{i}", sz, f"sp{i}", rng, scale=ws)
        if i % 2 == 0:
            g[-1] = g[-1].replace(f"[m{i}]", f",rotate=a='t*{rng.uniform(2, 5):.2f}':c=none[m{i}]")
        period = (w + sz) / (0.5 * max(w, h)) * rng.uniform(0.6, 1.4)
        mx = f"-{sz}+mod(t/{period:.3f}+{rng.random():.3f},1)*{w + sz}"
        my = f"{rng.randrange(0, max(1, h - sz))}+{h // 5}*sin(2*PI*t*{rng.uniform(0.5, 1.5):.2f})"
        g.append(f"[{last}][m{i}]overlay=x='{mx}':y='{my}':eval=frame[o{i}]")
        last = f"o{i}"
    hud = (f"drawbox=x={short // 50}:y={short // 50}:w={w // 4}:h={short // 22}:color=red@0.8:t=fill,"
           f"drawbox=x={short // 50}:y={short // 50}:w={w // 4}:h={short // 22}:color=white:t=3,"
           f"drawbox=x={w - short // 4 - short // 50}:y={short // 50}:w={short // 4}:h={short // 4}:"
           f"color=black@0.5:t=fill")
    if font:
        hud += (f",drawtext=fontfile={font}:text='KILLS %{{eif\\:n/45\\:d}}   %{{pts\\:hms}}':"
                f"fontsize={short // 20}:fontcolor=yellow:x={w // 2 - short // 2}:y={short // 50}:borderw=3")
    g.append(f"[{last}]{hud},format=yuv420p[v]")
    return ";".join(g)


def video_graph(f, font, work):
    rng = random.Random(SEED * 1000 + f["seed"])
    if f["scene"] == "screen":
        return screen_graph(f, rng, font, work)
    if f["scene"] == "game":
        return game_graph(f, rng, font)
    return camera_graph(f, rng, font)


def make_one(f, out_root, work, font):
    """One file, at its real bitrate and its made length."""
    started = time.time()
    p = f["p"]
    folder = os.path.join(out_root, p["folder"])
    os.makedirs(folder, exist_ok=True)
    if p["hidden"]:
        open(os.path.join(folder, ".nomedia"), "a").close()
    dest = os.path.join(folder, f["name"])
    fmt = p["container"]
    tmp = dest + ".tmp." + fmt
    s, fps, ak = f["gen_s"], f["fps"], f["audio_kbps"]
    gop = round(fps) if not p["bframes"] else round(fps) * 2
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-filter_threads", "2",
           "-framerate", rate_of(fps), "-i", plate_path(work, *plate_for(f))]
    if f["channels"]:
        cmd += ["-f", "lavfi", "-i",
                f"anoisesrc=color=pink:amplitude=0.05:sample_rate={f['sample_rate']}:duration={s}:seed={f['seed']}"]
    cmd += ["-filter_complex", video_graph(f, font, work), "-map", "[v]"]
    if f["channels"]:
        cmd += ["-map", "1:a"]
    cmd += ["-t", f"{s}"]
    if p["codec"] == "hevc":
        vk = f["video_kbps"]
        cmd += ["-c:v", "libx265", "-preset", "ultrafast", "-tag:v", "hvc1", "-x265-params",
                f"bitrate={vk}:vbv-maxrate={vk}:vbv-bufsize={vk}:keyint={gop}:strict-cbr=1:log-level=error"]
    else:
        vk = round(f["video_kbps"] * X264_ASK)
        cmd += ["-c:v", "libx264", "-preset", "superfast", "-bf", str(p["bframes"]), "-g", str(gop),
                "-b:v", f"{vk}k", "-minrate", f"{vk}k", "-maxrate", f"{vk}k", "-bufsize", f"{vk}k",
                "-x264-params", "nal-hrd=cbr:force-cfr=1"]
        if p["profile"]:
            cmd += ["-profile:v", p["profile"]]
    cmd += ["-threads", "2"]
    if f["channels"]:
        cmd += ["-c:a", "aac", "-b:a", f"{ak}k", "-ac", str(f["channels"]), "-ar", str(f["sample_rate"])]
    else:
        cmd += ["-an"]
    cmd += ["-metadata", "creation_time=" + f["when"].strftime("%Y-%m-%dT%H:%M:%SZ"),
            "-movflags", "+faststart", "-f", fmt, tmp if f["rot"] else dest]
    subprocess.run(cmd, check=True, cwd=work)
    if f["rot"]:
        # A camera writes upright clips as landscape pixels plus a rotation
        # tag; ffmpeg counts the other way, so -90 here reads back as 90.
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-display_rotation:v:0",
                        str(-f["rot"]), "-i", tmp, "-c", "copy", "-movflags", "+faststart", "-f", fmt, dest],
                       check=True)
        os.remove(tmp)
    t = f["when"].timestamp()
    os.utime(dest, (t, t))
    return f["name"], f["gen_s"], os.path.getsize(dest), f["scene"], round(time.time() - started, 1)


def cost(f):
    """Roughly how long a file takes to make, to start the longest first."""
    weight = dict(day=1.0, night=1.0, motion=1.6, static=0.6, screen=0.5, game=1.2)[f["scene"]]
    return f["gen_s"] * f["fps"] * f["width"] * f["height"] * weight


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    m = sub.add_parser("manifest")
    m.add_argument("--out", required=True)
    m.add_argument("--shards", type=int, default=8)
    m.add_argument("--summary", action="store_true", help="also print videos, GB and hours by kind and scene")
    mk = sub.add_parser("make")
    mk.add_argument("--shard", type=int, required=True)
    mk.add_argument("--shards", type=int, required=True)
    mk.add_argument("--out", required=True)
    mk.add_argument("--jobs", type=int, default=max(1, os.cpu_count() or 2))
    mk.add_argument("--only", default="", help="comma-separated profile ids (for trying it out)")
    mk.add_argument("--sample", type=int, default=1, help="make every n-th file only (for timing it)")
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
        if a.summary:
            print("\n".join(summary_lines(rows)))
        return

    mine = [f for idx, f in enumerate(files) if idx % a.shards == a.shard]
    if a.only:
        keep = set(a.only.split(","))
        mine = [f for f in mine if f["p"]["id"] in keep]
    mine = mine[::max(1, a.sample)]
    out_root = os.path.abspath(a.out)
    base = os.path.join(os.path.dirname(out_root), os.path.basename(out_root))
    work = base + "-work"
    os.makedirs(work, exist_ok=True)
    font = find_font()
    if not font:
        print("No system font found: screen and game text are drawn as bars.")
    started = time.time()
    plates = sorted({plate_for(f) for f in mine})
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as pool:
        list(pool.map(lambda pk: make_plate(work, pk[0], pk[1], font), plates))
    plated = time.time() - started
    with concurrent.futures.ThreadPoolExecutor(max_workers=a.jobs) as pool:
        made = list(pool.map(lambda f: make_one(f, out_root, work, font), sorted(mine, key=cost, reverse=True)))
    shutil.rmtree(work, ignore_errors=True)
    order = {f["name"]: i for i, f in enumerate(mine)}
    made.sort(key=lambda r: order[r[0]])
    with open(base + "-made.csv", "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["name", "gen_s", "bytes", "scene", "make_s"])
        w.writerows(made)
    # What the emulator's gallery should end up listing: the hidden folders' files never appear.
    with open(base + "-in-gallery.txt", "w") as fh:
        fh.write(f"{sum(1 for f in mine if not f['p']['hidden'])}\n")
    # The files whose copies the app keeps for quality.py.
    with open(base + "-keep.txt", "w") as fh:
        fh.writelines(f["name"] + "\n" for f in mine if f["keep"])
    took = time.time() - started
    print(f"made {len(made)} videos, {sum(r[2] for r in made) / 1e9:.2f} GB, "
          f"{sum(r[1] for r in made) / 60:.1f} minutes in {took / 60:.1f} minutes "
          f"({plated:.0f} s of it the {len(plates)} plates), listed in {base}-made.csv")
    by_scene = {}
    for _, gen_s, _, scene, make_s in made:
        t = by_scene.setdefault(scene, [0, 0.0, 0.0])
        t[0] += 1
        t[1] += gen_s
        t[2] += make_s
    for scene, (n, gen_s, make_s) in sorted(by_scene.items()):
        print(f"  {SCENES[scene]:30s} {n:3d} files, {gen_s / 60:5.1f} minutes of video, "
              f"{make_s / 60:5.1f} minutes of work")


if __name__ == "__main__":
    sys.exit(main())
