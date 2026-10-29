"""QA for generated audio: format, peak, DC, clipping, edge clicks, loop seams,
plus a waveform/spectrogram contact sheet PNG.

Usage: python3 audio_qa.py <audio_dir> [sheet.png] [loop1.wav,loop2.wav]
"""
from __future__ import annotations

import glob
import os
import sys

import numpy as np
import soundfile as sf
from PIL import Image, ImageDraw, ImageFont
from scipy import signal

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
FONT = os.path.join(ROOT, "assets", "fonts", "ui_semibold.ttf")


def seam_report(x, sr):
    """Concatenate the loop twice and look for a discontinuity at the junction.

    The sample step across the junction must not be an outlier compared with the
    steps in its own +-20 ms neighbourhood (a click would be), and is also reported
    against the whole-file step distribution.  hf_* is the >7 kHz energy (1 ms RMS)
    at the junction vs the file's 99th percentile (informational: a loop that
    restarts on a drum hit legitimately has HF energy there).
    """
    mono = x.mean(axis=1) if x.ndim == 2 else x
    L = mono.shape[0]
    y = np.concatenate([mono, mono, mono])          # junctions at L and 2L
    d1 = np.abs(np.diff(y))
    j = 2 * L - 1                                   # step from last sample to first sample
    nb = int(0.02 * sr)
    local = np.concatenate([d1[j - nb:j - 1], d1[j + 2:j + nb]])
    sos = signal.butter(4, 7000, "highpass", fs=sr, output="sos")
    h = signal.sosfiltfilt(sos, y)
    w = int(0.001 * sr)
    seg = h[L:2 * L + w]
    e = np.sqrt(np.convolve(seg ** 2, np.ones(w) / w, mode="same"))
    return {"junction_step": float(d1[j]), "local_p995_step": float(np.percentile(local, 99.5)),
            "local_max_step": float(local.max()), "file_p99_step": float(np.percentile(d1, 99)),
            "hf_junction": float(np.max(e[L - w:L + w])), "hf_p99": float(np.percentile(e, 99))}


def analyse(path, loops):
    info = sf.info(path)
    x, sr = sf.read(path, dtype="int16", always_2d=True)
    xf = x.astype(float) / 32768.0
    mono = xf.mean(axis=1)
    peak = np.abs(xf).max()
    clips = int(np.sum(np.abs(x.astype(int)) >= 32767))
    dc = np.abs(xf.mean(axis=0)).max()
    edge = max(np.abs(xf[0]).max(), np.abs(xf[-1]).max())
    rms = np.sqrt(np.mean(mono ** 2))
    r = {
        "name": os.path.basename(path), "sr": sr, "ch": info.channels, "subtype": info.subtype,
        "dur": x.shape[0] / sr, "peak_db": 20 * np.log10(peak + 1e-12), "clips": clips,
        "dc_db": 20 * np.log10(dc + 1e-12), "edge": edge, "rms_db": 20 * np.log10(rms + 1e-12),
        "bytes": os.path.getsize(path),
    }
    if os.path.basename(path) in loops:
        r["seam"] = seam_report(xf, sr)
    return r, mono, sr


def colormap(v):
    """v in [0,1] -> RGB (inferno-ish)."""
    stops = np.array([[0, 0, 4], [40, 11, 84], [101, 21, 110], [159, 42, 99], [212, 72, 66],
                      [245, 125, 21], [250, 193, 39], [252, 255, 164]], float)
    p = np.clip(v, 0, 1) * (len(stops) - 1)
    i = np.minimum(p.astype(int), len(stops) - 2)
    f = (p - i)[..., None]
    return (stops[i] * (1 - f) + stops[i + 1] * f).astype(np.uint8)


def tile(name, mono, sr, w=420, h=230):
    img = Image.new("RGB", (w, h), (18, 18, 22))
    d = ImageDraw.Draw(img)
    try:
        fnt = ImageFont.truetype(FONT, 16)
    except OSError:
        fnt = ImageFont.load_default()
    dur = mono.shape[0] / sr
    d.text((6, 2), f"{name}  {dur:.2f}s", font=fnt, fill=(240, 240, 240))
    # waveform
    wy0, wh = 22, 60
    cols = np.array_split(mono, w)
    for xi, c in enumerate(cols):
        if c.size == 0:
            continue
        lo, hi = c.min(), c.max()
        d.line([(xi, wy0 + wh / 2 - hi * wh / 2), (xi, wy0 + wh / 2 - lo * wh / 2)], fill=(90, 200, 255))
    # spectrogram (log freq 30 Hz .. 20 kHz)
    nper = 1024 if mono.shape[0] > 4096 else 256
    f, t, S = signal.stft(mono, sr, nperseg=nper, noverlap=nper * 3 // 4)
    mag = 20 * np.log10(np.abs(S) + 1e-9)
    mag = (mag - (mag.max() - 80)) / 80
    sh = h - wy0 - wh - 4
    fy = np.geomspace(30, 20000, sh)[::-1]
    fi = np.clip(np.searchsorted(f, fy), 0, len(f) - 1)
    ti = np.clip((np.arange(w) / w * mag.shape[1]).astype(int), 0, mag.shape[1] - 1)
    spec = mag[fi][:, ti]
    img.paste(Image.fromarray(colormap(spec)), (0, wy0 + wh + 4))
    for fr in (100, 1000, 10000):
        yy = wy0 + wh + 4 + int(np.searchsorted(-fy, -fr))
        d.line([(0, yy), (6, yy)], fill=(255, 255, 255))
    return img


def main():
    adir = sys.argv[1]
    sheet = sys.argv[2] if len(sys.argv) > 2 else None
    loops = set(sys.argv[3].split(",")) if len(sys.argv) > 3 else {"lobby_music.wav", "match_ambience.wav"}
    files = sorted(glob.glob(os.path.join(adir, "*.wav")))
    tiles = []
    total = 0
    bad = 0
    for p in files:
        r, mono, sr = analyse(p, loops)
        total += r["bytes"]
        flag = []
        if r["sr"] != 44100 or r["subtype"] != "PCM_16":
            flag.append("FORMAT")
        if r["ch"] != 1 and r["name"] not in {"lobby_music.wav"}:
            flag.append("CHANNELS")
        if r["clips"]:
            flag.append("CLIP")
        if abs(r["peak_db"] + 1.0) > 0.15:
            flag.append("PEAK")
        if r["dc_db"] > -60:
            flag.append("DC")
        if r["edge"] > 0.002 and "seam" not in r:
            flag.append("EDGE")
        s = r.get("seam")
        if s and s["junction_step"] > max(s["local_p995_step"], 1e-4):
            flag.append("SEAM")
        bad += bool(flag)
        line = (f"{r['name']:22s} {r['ch']}ch {r['dur']:7.3f}s peak {r['peak_db']:6.2f} dBFS "
                f"rms {r['rms_db']:6.1f} dc {r['dc_db']:7.1f} edge {r['edge']:.4f} "
                f"{r['bytes'] / 1024:8.1f} KB {' '.join(flag)}")
        print(line)
        if s:
            print("    seam:", {k: round(v, 5) for k, v in s.items()})
        tiles.append(tile(r["name"], mono, sr))
    print(f"TOTAL {total / 1e6:.2f} MB in {len(files)} files, {bad} flagged")
    if sheet and tiles:
        cols = 4
        tw, th = tiles[0].size
        rows = (len(tiles) + cols - 1) // cols
        im = Image.new("RGB", (cols * tw + (cols - 1) * 4, rows * th + (rows - 1) * 4), (60, 60, 60))
        for i, tl in enumerate(tiles):
            im.paste(tl, ((i % cols) * (tw + 4), (i // cols) * (th + 4)))
        im.save(sheet)
        print("sheet:", sheet)


if __name__ == "__main__":
    main()
