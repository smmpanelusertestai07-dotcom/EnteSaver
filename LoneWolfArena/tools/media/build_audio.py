"""Build every audio asset, write manifest.json, run QA, then copy the shipped files into the game.

Usage: python3 build_audio.py [ship_dir]

Everything is rendered into the work dir tools/media/_work/audio/ (outside res://, git-ignored):
every WAV including lobby_music.wav (the master audio_qa.py checks for the loop seam),
manifest.json and the QA contact sheet audio_qa.png. Then only the files the game plays are
copied into ship_dir (default assets/audio/): the game loads every .wav/.ogg there and the export
ships the folder, so nothing else may land in it.
"""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import make_music  # noqa: E402
import make_sfx  # noqa: E402

WORK = os.path.join(HERE, "_work", "audio")
SHIP = os.path.normpath(os.path.join(HERE, "..", "..", "assets", "audio"))
# Rendered for QA only: the game plays lobby_music.ogg (Audio.stream() tries .ogg before .wav).
WORK_ONLY = {"lobby_music.wav"}


def main():
    ship = sys.argv[1] if len(sys.argv) > 1 else SHIP
    os.makedirs(WORK, exist_ok=True)
    print("SFX:")
    entries = make_sfx.build(WORK)
    print("Music / ambience:")
    entries += make_music.build(WORK)
    for e in entries:
        e["bytes"] = os.path.getsize(os.path.join(WORK, e["name"]))
        e["shipped"] = e["name"] not in WORK_ONLY
    manifest = {
        "format": "WAV PCM 16-bit, 44100 Hz, mono (lobby_music stereo), peak-normalised to -1 dBFS",
        "generator": "procedural synthesis (tools/media/make_sfx.py, make_music.py); no samples",
        "notes": [
            "Looping files (loop=true) loop over the whole file: loop_begin=0, loop_end=length. "
            "Set the import loop mode to Forward in Godot (or enable loop on the .ogg).",
            "Loop files start mid-signal (wrapped tails), so fade them in briefly when starting playback.",
            "Only shipped=true files are copied into assets/audio/; lobby_music.wav is the QA master "
            "of lobby_music.ogg.",
        ],
        "sounds": entries,
    }
    with open(os.path.join(WORK, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"manifest: {len(entries)} entries")
    subprocess.run([sys.executable, os.path.join(HERE, "audio_qa.py"), WORK, os.path.join(WORK, "audio_qa.png")],
                   check=True)
    shipped = [e["name"] for e in entries if e["shipped"]]
    if "lobby_music.ogg" not in shipped:
        sys.exit("lobby_music.ogg was not written (soundfile needs libsndfile with Ogg Vorbis): nothing copied")
    os.makedirs(ship, exist_ok=True)
    for name in shipped:
        shutil.copyfile(os.path.join(WORK, name), os.path.join(ship, name))
    print(f"copied {len(shipped)} shipped files to {os.path.normpath(ship)}")


if __name__ == "__main__":
    main()
