#!/usr/bin/env python3
"""
Opens the four tabs of the installed RELEASE build, with R8 applied.

The instrumented suite runs the debug APK, so this is the only place a
screen past launch is drawn from minified code - and a missing keep rule
shows up as a crash on the screen that needs the stripped class, not at
launch. A fresh install opens on setup, which has no tab bar, so the walk
first finishes setup the way a person would: it reads each button's label
from strings.xml and taps the button that carries it. Taps by screen
fraction used to land on setup and pass without ever reaching a tab.

Every step checks what is on screen. Never reaching the tab bar, or a tab
that does not become the selected one, fails the run instead of passing
over a screen that was never drawn.

One step asks for a choice before it moves on: how to save space. Its
default, Replace on this phone, needs All files access, and its button
then opens Android's settings page instead of the next step. The walk
stays inside the app and picks Copies for Ente, whose button is Next.

Usage: release-tab-walk.py <package> <screenshot dir>
"""

import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

PKG = sys.argv[1]
SHOTS = sys.argv[2]
STRINGS = "app/src/main/res/values/strings.xml"
DUMP = "/sdcard/entesaver-release-ui.xml"

# The labels that move setup forward, in the order they are preferred. Only
# one of them is a step's main button at a time; "Skip" comes last because
# it is the way past the two steps whose main button leaves the app (the
# notification prompt and the usage access page).
FORWARD = ["onb_start", "onb_next", "onb_albums_confirm", "onb_done_next", "onb_ready_start", "skip"]
# A button that would leave the app, and the option on its step that turns
# it into one that moves setup forward.
CHOOSE_FIRST = {"file_access_grant": "save_mode_copies"}
TABS = ["nav_home", "nav_files", "nav_storage", "nav_options"]
BOUNDS = re.compile(r"\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]")


def android_text(raw):
    """A strings.xml value as the app shows it: escapes resolved, quotes dropped."""
    text = raw.strip()
    if len(text) >= 2 and text[0] == '"' and text[-1] == '"':
        text = text[1:-1]
    out, i = [], 0
    while i < len(text):
        c = text[i]
        if c == "\\" and i + 1 < len(text):
            n = text[i + 1]
            if n == "u" and i + 5 < len(text):
                out.append(chr(int(text[i + 2:i + 6], 16)))
                i += 6
                continue
            out.append({"n": "\n", "t": "\t"}.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def load_labels():
    labels = {}
    for el in ET.parse(STRINGS).getroot().iter("string"):
        labels[el.get("name")] = android_text("".join(el.itertext()))
    missing = [k for k in FORWARD + TABS + list(CHOOSE_FIRST) + list(CHOOSE_FIRST.values()) if k not in labels]
    if missing:
        fail("strings.xml no longer has %s" % missing)
    return labels


def adb(*args):
    return subprocess.run(["adb", *args], capture_output=True, text=True, timeout=90)


def alive():
    return adb("shell", "pidof", PKG).stdout.strip() != ""


def shot(name):
    with open(os.path.join(SHOTS, name), "wb") as f:
        subprocess.run(["adb", "exec-out", "screencap", "-p"], stdout=f, timeout=90)


def crash_log():
    print(adb("logcat", "-d", "-b", "crash").stdout[-8000:])


def fail(message):
    print("::error::" + message)
    try:
        shot("49-release-walk-failed.png")
        crash_log()
    except Exception:
        pass
    sys.exit(1)


def screen():
    """The app's nodes on screen, each with its label, centre and selection."""
    for _ in range(3):
        adb("shell", "rm", "-f", DUMP)
        adb("shell", "uiautomator", "dump", DUMP)
        xml = adb("exec-out", "cat", DUMP).stdout
        if "<hierarchy" in xml:
            break
        time.sleep(2)
    else:
        return None, 0
    root = ET.fromstring(xml[xml.index("<hierarchy"):xml.rindex("</hierarchy>") + len("</hierarchy>")])
    nodes, height = [], 0

    def walk(el, chosen):
        nonlocal height
        chosen = chosen or el.get("selected") == "true" or el.get("checked") == "true"
        m = BOUNDS.match(el.get("bounds", ""))
        if m:
            x1, y1, x2, y2 = map(int, m.groups())
            height = max(height, y2)
            if el.get("package") == PKG:
                for label in (el.get("text", ""), el.get("content-desc", "")):
                    if label:
                        nodes.append({"label": label, "x": (x1 + x2) // 2, "y": (y1 + y2) // 2,
                                      "selected": chosen})
        for child in el:
            walk(child, chosen)

    walk(root, False)
    return nodes, height


def tab_bar(nodes, height, labels):
    """Each tab's lowest node in the bottom fifth of the screen, or None."""
    bar = {}
    for key in TABS:
        hits = [n for n in nodes if n["label"] == labels[key] and n["y"] > height * 0.8]
        if not hits:
            return None
        bar[key] = max(hits, key=lambda n: n["y"])
    return bar


def tap(node):
    adb("shell", "input", "tap", str(node["x"]), str(node["y"]))


def main():
    labels = load_labels()
    os.makedirs(SHOTS, exist_ok=True)

    bar = None
    for _ in range(40):
        if not alive():
            fail("The released APK died during setup")
        nodes, height = screen()
        if nodes is None:
            fail("Could not read the release build's screen")
        bar = tab_bar(nodes, height, labels)
        if bar:
            break
        choice = next((n for button, option in CHOOSE_FIRST.items()
                       if any(m["label"] == labels[button] for m in nodes)
                       for n in nodes if n["label"] == labels[option]), None)
        forward = next((n for key in FORWARD for n in nodes if n["label"] == labels[key]), None)
        if choice:
            print("setup: choose " + choice["label"])
            tap(choice)
            time.sleep(2)
        elif forward:
            print("setup: " + forward["label"])
            tap(forward)
            time.sleep(2)
        else:
            # The step's button sits below the fold: scroll the card up.
            w = adb("shell", "wm", "size").stdout.strip().split()[-1].split("x")
            x, h = int(w[0]) // 2, int(w[1])
            adb("shell", "input", "swipe", str(x), str(h * 7 // 10), str(x), str(h * 3 // 10), "400")
            time.sleep(1)
    if not bar:
        fail("The release build never reached its tabs - setup did not finish")

    for i, key in enumerate(TABS, start=1):
        name = labels[key]
        selected = False
        for _ in range(2):
            tap(bar[key])
            time.sleep(3)
            if not alive():
                fail("The released APK died while opening the %s tab" % name)
            nodes, height = screen()
            if nodes is None:
                fail("Could not read the release build's screen on the %s tab" % name)
            bar = tab_bar(nodes, height, labels) or bar
            if any(n["selected"] for n in nodes if n["label"] == name and n["y"] > height * 0.8):
                selected = True
                break
        shot("4%d-release-tab-%s.png" % (i, name.lower()))
        if not selected:
            fail("The %s tab never opened in the release build" % name)
        print("tab: " + name)


main()
