"""Build every audio asset and write manifest.json, then run QA.

Usage: python3 build_audio.py [out_dir]
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import make_music  # noqa: E402
import make_sfx  # noqa: E402


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "assets", "audio")
    os.makedirs(out, exist_ok=True)
    print("SFX:")
    entries = make_sfx.build(out)
    print("Music / ambience:")
    entries += make_music.build(out)
    for e in entries:
        e["bytes"] = os.path.getsize(os.path.join(out, e["name"]))
    manifest = {
        "format": "WAV PCM 16-bit, 44100 Hz, mono (lobby_music stereo), peak-normalised to -1 dBFS",
        "generator": "procedural synthesis (tools/media/make_sfx.py, make_music.py); no samples",
        "notes": [
            "Looping files (loop=true) loop over the whole file: loop_begin=0, loop_end=length. "
            "Set the import loop mode to Forward in Godot (or enable loop on the .ogg).",
            "Loop files start mid-signal (wrapped tails), so fade them in briefly when starting playback.",
        ],
        "sounds": entries,
    }
    with open(os.path.join(out, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"manifest: {len(entries)} entries")
    subprocess.run([sys.executable, os.path.join(HERE, "audio_qa.py"), out], check=True)


if __name__ == "__main__":
    main()
