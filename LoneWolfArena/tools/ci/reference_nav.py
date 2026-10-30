#!/usr/bin/env python3
"""Private reference probe, step two (run only by hand, after reference_probe.sh launched the app):
drives the app the way a tester would, by reading its screen. Nothing here is part of the game.

Every loop it takes a screenshot (kept for the encrypted results), reads the words on it
(tesseract) and taps the first word of the plan that is on screen; where a name is asked it types
one. Words of AVOID are never tapped (sign-ins, purchases, anything with other players or money).
Once a practice mode was entered it plays with the touch controls (move, look, fire, jump) at the
usual places of a shooter's layout. At the end the frames become a time-lapse video.

  reference_nav.py <out_dir> <minutes> <package>
"""
import json
import os
import random
import re
import shutil
import subprocess
import sys
import time

OUT = sys.argv[1]
MINUTES = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0
PKG = sys.argv[3] if len(sys.argv) > 3 else ""
FRAMES = os.path.join(OUT, "frames")
LOG = os.path.join(OUT, "nav.txt")

# Tapped in this order of preference when on screen (whole words, lower case).
PLAN = ["guest", "agree", "accept", "confirm", "ok", "okay", "yes", "continue", "next", "skip", "got it",
        "tap to start", "tap to begin", "touch to start", "download", "update", "later", "not now", "close",
        "claim", "collect", "training"]
# Never tapped: sign-ins, money, other players.
AVOID = ["facebook", "google", "vk", "twitter", "apple", "huawei", "line", "purchase", "buy", "top up", "topup",
         "recharge", "diamond", "pay", "ranked", "rank", "redeem", "delete", "logout", "log out", "exit", "quit",
         "bind", "invite", "friend", "squad", "duo", "team", "share", "report", "store", "shop"]
PRACTICE = ["training"]            # a screen with one of these words: its START enters solo practice


def sh(args, timeout=60):
    try:
        return subprocess.run(args, capture_output=True, timeout=timeout).stdout
    except Exception:
        return b""


def adb(*a, timeout=60):
    return sh(["adb"] + list(a), timeout)


def log(msg):
    with open(LOG, "a") as f:
        f.write("[%6.1f] %s\n" % (time.time() - T0, msg))


def screenshot(i):
    png = adb("exec-out", "screencap", "-p", timeout=30)
    path = os.path.join(FRAMES, "f%05d.png" % i)
    if len(png) > 1000:
        with open(path, "wb") as f:
            f.write(png)
        return path
    return None


def read_words(path):
    """Phrases on the screen: [(text, x, y, w, h)] from tesseract's word boxes, joined per line.
    One thread only: the emulator draws without a GPU and needs the rest of the machine."""
    try:
        tsv = subprocess.run(["nice", "-n", "19", "tesseract", path, "stdout", "--psm", "11", "-l", "eng", "tsv"],
                             capture_output=True, timeout=90, env=dict(os.environ, OMP_THREAD_LIMIT="1")).stdout
    except Exception:
        tsv = b""
    tsv = tsv.decode("utf-8", "ignore")
    lines = {}
    for row in tsv.splitlines()[1:]:
        c = row.split("\t")
        if len(c) < 12 or not c[11].strip():
            continue
        try:
            conf = float(c[10])
        except ValueError:
            continue
        if conf < 45:
            continue
        key = (c[2], c[3], c[4])
        x, y, w, h = int(c[6]), int(c[7]), int(c[8]), int(c[9])
        lines.setdefault(key, []).append((c[11].strip(), x, y, w, h))
    out = []
    for words in lines.values():
        text = " ".join(w[0] for w in words)
        x0 = min(w[1] for w in words)
        y0 = min(w[2] for w in words)
        x1 = max(w[1] + w[3] for w in words)
        y1 = max(w[2] + w[4] for w in words)
        out.append((text, x0, y0, x1 - x0, y1 - y0))
    return out


def has_word(text, word):
    return re.search(r"(^|[^a-z])" + re.escape(word) + r"([^a-z]|$)", text.lower()) is not None


def tap(x, y):
    adb("shell", "input", "tap", str(int(x)), str(int(y)))


def screen_size():
    m = re.search(rb"(\d+)x(\d+)", adb("shell", "wm", "size"))
    w, h = (int(m.group(1)), int(m.group(2))) if m else (1080, 2400)
    return max(w, h), min(w, h)        # the apps run in landscape


def decide(phrases, tapped):
    """The phrase to tap now, or None."""
    on_screen = " | ".join(p[0].lower() for p in phrases)
    practice = any(has_word(on_screen, w) for w in PRACTICE)
    for word in PLAN + ["start"]:
        if word == "start" and not practice:
            continue
        for p in phrases:
            t = p[0].lower()
            if not has_word(t, word) or any(has_word(t, a) for a in AVOID) or len(t) > 40:
                continue
            if tapped.get((word, p[1] // 40, p[2] // 40), 0) >= 3:
                continue                  # tapped there three times already: it does nothing
            return word, p
    return None


def play_step(k, W, H):
    """One move of a practice session at the usual places of a shooter's touch layout."""
    joy = (0.18 * W, 0.66 * H)
    fire = (0.80 * W, 0.68 * H)
    jump = (0.906 * W, 0.52 * H)
    look = (0.62 * W, 0.40 * H)
    step = k % 8
    if step in (0, 4):           # walk forward (a slow drag up on the stick)
        adb("shell", "input", "swipe", str(int(joy[0])), str(int(joy[1])), str(int(joy[0])), str(int(joy[1] - 0.12 * H)), "2500")
    elif step == 1:              # look right
        adb("shell", "input", "swipe", str(int(look[0])), str(int(look[1])), str(int(look[0] + 0.12 * W)), str(int(look[1])), "500")
    elif step in (2, 6):         # hold fire
        adb("shell", "input", "swipe", str(int(fire[0])), str(int(fire[1])), str(int(fire[0])), str(int(fire[1])), "1500")
    elif step == 3:
        tap(*jump)
    elif step == 5:              # look left
        adb("shell", "input", "swipe", str(int(look[0])), str(int(look[1])), str(int(look[0] - 0.12 * W)), str(int(look[1])), "500")
    else:                        # strafe right
        adb("shell", "input", "swipe", str(int(joy[0])), str(int(joy[1])), str(int(joy[0] + 0.1 * W)), str(int(joy[1])), "2000")


def make_video():
    frames = sorted(f for f in os.listdir(FRAMES) if f.endswith(".png"))
    if not frames or not shutil.which("ffmpeg"):
        return
    with open(os.path.join(OUT, "frames.txt"), "w") as f:
        for name in frames:
            f.write("file '%s'\nduration 0.5\n" % os.path.join(FRAMES, name))
    sh(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", os.path.join(OUT, "frames.txt"),
        "-vf", "scale=1280:-2,format=yuv420p", "-c:v", "libx264", "-preset", "veryfast", "-crf", "30",
        os.path.join(OUT, "session.mp4")], 900)
    # Keep every 10th frame as a picture; the video has the rest.
    for n, name in enumerate(frames):
        if n % 10:
            os.remove(os.path.join(FRAMES, name))


def main():
    os.makedirs(FRAMES, exist_ok=True)
    W, H = screen_size()
    log("screen %dx%d, %.0f min" % (W, H, MINUTES))
    tapped = {}
    state = "nav"
    since = time.time()
    named = False
    k = 0
    i = 0
    last = b""
    adb("shell", "svc", "power", "stayon", "true")
    adb("shell", "settings", "put", "system", "screen_off_timeout", "2147483647")
    while time.time() - T0 < MINUTES * 60:
        if i % 40 == 0:     # the app's recent log and window, in case the run is stopped early
            with open(os.path.join(OUT, "logcat_tail.txt"), "wb") as f:
                f.write(adb("logcat", "-d", "-t", "3000", timeout=60))
            log("window: " + adb("shell", "dumpsys", "window").decode("utf-8", "ignore").split("mCurrentFocus")[-1][:120].replace("\n", " "))
        path = screenshot(i)
        i += 1
        if path is None:
            time.sleep(3)
            continue
        with open(path, "rb") as f:
            png = f.read()
        if png == last or len(png) < 20000:
            # the same picture again, or a plain black one (still loading): nothing new to read
            os.remove(path) if png == last else None
            log("same screen" if png == last else "black screen")
            since = time.time() if len(png) < 20000 else since
            time.sleep(4)
            continue
        last = png
        phrases = read_words(path)
        log("seen: " + json.dumps([p[0] for p in sorted(phrases, key=lambda p: -p[3] * p[4])[:14]]))
        if state == "play":
            choice = decide([p for p in phrases if not has_word(p[0], "training")], tapped)
            if choice and choice[0] in ("ok", "confirm", "close", "skip", "continue", "got it"):
                tap(choice[1][1] + choice[1][3] / 2, choice[1][2] + choice[1][4] / 2)
                log("tap %r (dialog during practice)" % choice[1][0])
            else:
                play_step(k, W, H)
                k += 1
            continue
        text = " | ".join(p[0].lower() for p in phrases)
        if PKG and i % 10 == 0 and not adb("shell", "pidof", PKG).strip():
            adb("shell", "monkey", "-p", PKG, "-c", "android.intent.category.LAUNCHER", "1")
            log("the app was not running: launched it again")
            time.sleep(20)
            continue
        if has_word(text, "exit") or has_word(text, "quit"):
            # a "leave the game?" question (after a back key): never confirm it
            no = next((p for p in phrases if has_word(p[0], "cancel") or has_word(p[0], "no")), None)
            if no:
                tap(no[1] + no[3] / 2, no[2] + no[4] / 2)
                log("exit question: tap %r" % no[0])
                time.sleep(2)
                continue
        if not named and ("nickname" in text or "enter name" in text or "your name" in text):
            box = next((p for p in phrases if "enter" in p[0].lower()), None)
            tap(box[1] + box[3] / 2, box[2] + box[4] / 2) if box else tap(W / 2, H / 2)
            time.sleep(1.5)
            adb("shell", "input", "text", "Wolf%04d" % random.randint(0, 9999))
            adb("shell", "input", "keyevent", "66")
            named = True
            log("typed a name")
            continue
        choice = decide(phrases, tapped)
        if choice:
            word, p = choice
            key = (word, p[1] // 40, p[2] // 40)
            tapped[key] = tapped.get(key, 0) + 1
            tap(p[1] + p[3] / 2, p[2] + p[4] / 2)
            log("tap %r for %r at %d,%d" % (p[0], word, p[1] + p[3] / 2, p[2] + p[4] / 2))
            since = time.time()
            if word == "start":
                state = "play"
                log("practice started: playing from now on")
                time.sleep(60)            # the practice map loads
            else:
                time.sleep(2)
            continue
        if time.time() - since > 240:
            adb("shell", "input", "keyevent", "4")      # stuck on something with no words: back
            log("nothing to tap for 240 s: back")
            since = time.time()
        time.sleep(2)
    make_video()
    log("done: %d screenshots" % i)


T0 = time.time()
if __name__ == "__main__":
    main()
