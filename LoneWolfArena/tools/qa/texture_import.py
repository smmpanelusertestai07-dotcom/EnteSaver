#!/usr/bin/env python3
"""Sets phone-friendly import options on the 3D textures (assets/textures/*.png): VRAM
compression (ETC2/ASTC on Android), mipmaps, and normal-map mode for *_n.png. Godot only
auto-detects 3D usage when a texture is assigned in the editor; our materials are built in
code, so without this the textures ship uncompressed (several times the GPU memory).
Run after adding textures, then `godot --headless --path . --import`.
usage: python3 tools/qa/texture_import.py [--check]   (--check: exit 1 if anything would change)"""
import glob
import os
import re
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
# UI sprites drawn in 2D keep their lossless import.
SKIP = {"glow.png", "muzzle_flash.png"}


def want(name):
    opts = {"compress/mode": "2", "mipmaps/generate": "true", "detect_3d/compress_to": "0"}
    if name.endswith("_n.png"):
        opts["compress/normal_map"] = "1"
    return opts


def main():
    check = "--check" in sys.argv
    changed = []
    for path in sorted(glob.glob(os.path.join(ROOT, "assets", "textures", "*.png.import"))):
        name = os.path.basename(path)[: -len(".import")]
        if name in SKIP:
            continue
        text = open(path).read()
        new = text
        for key, val in want(name).items():
            pat = re.compile(r"^%s=.*$" % re.escape(key), re.M)
            if pat.search(new):
                new = pat.sub("%s=%s" % (key, val), new)
            else:
                new = new.replace("[params]\n", "[params]\n\n%s=%s\n" % (key, val), 1)
        if new != text:
            changed.append(name)
            if not check:
                open(path, "w").write(new)
    print(("would change: " if check else "updated: ") + (", ".join(changed) if changed else "nothing"))
    sys.exit(1 if (check and changed) else 0)


if __name__ == "__main__":
    main()
