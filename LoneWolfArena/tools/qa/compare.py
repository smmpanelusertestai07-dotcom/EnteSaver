#!/usr/bin/env python3
"""Screen-by-screen comparison of two screenshot folders (e.g. last build vs this build, or a
capture vs approved "golden" images). For every PNG present in both folders it writes a
side-by-side sheet (A | B | difference heat map) and reports how much changed.

usage: compare.py <dir_a> <dir_b> <out_dir> [--fail-above 0.08]
Prints one line per screen and writes <out_dir>/report.json. Exit code 1 when any screen's
changed-pixel ratio is above --fail-above (use it to guard approved goldens)."""
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw


def load(path, size=None):
    im = Image.open(path).convert("RGB")
    if size and im.size != size:
        im = im.resize(size, Image.BILINEAR)
    return im


def ssim_gray(a, b):
    """Global-window SSIM on 8x8 blocks (cheap approximation, 1.0 = identical)."""
    a = a.astype(np.float64)
    b = b.astype(np.float64)
    h, w = a.shape
    h8, w8 = h - h % 8, w - w % 8
    a = a[:h8, :w8].reshape(h8 // 8, 8, w8 // 8, 8)
    b = b[:h8, :w8].reshape(h8 // 8, 8, w8 // 8, 8)
    ma, mb = a.mean((1, 3)), b.mean((1, 3))
    va, vb = a.var((1, 3)), b.var((1, 3))
    cov = ((a - ma[:, None, :, None]) * (b - mb[:, None, :, None])).mean((1, 3))
    c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
    s = ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma ** 2 + mb ** 2 + c1) * (va + vb + c2))
    return float(s.mean())


def compare(pa, pb, out_png):
    a = load(pa)
    b = load(pb, a.size)
    na = np.asarray(a).astype(np.int16)
    nb = np.asarray(b).astype(np.int16)
    diff = np.abs(na - nb).max(axis=2)
    changed = float((diff > 24).mean())
    mad = float(np.abs(na - nb).mean())
    ssim = ssim_gray(np.asarray(a.convert("L")), np.asarray(b.convert("L")))
    heat = np.zeros(na.shape, np.uint8)
    heat[..., 0] = np.clip(diff * 3, 0, 255)
    heat[..., 1] = (np.asarray(a.convert("L")) * 0.35).astype(np.uint8)
    heat[..., 2] = heat[..., 1]
    w, h = a.size
    sheet = Image.new("RGB", (w * 3, h + 28), (20, 20, 24))
    sheet.paste(a, (0, 28))
    sheet.paste(b, (w, 28))
    sheet.paste(Image.fromarray(heat), (w * 2, 28))
    d = ImageDraw.Draw(sheet)
    d.text((8, 8), "A: " + pa, fill=(255, 255, 255))
    d.text((w + 8, 8), "B: " + pb, fill=(255, 255, 255))
    d.text((2 * w + 8, 8), "changed %.1f%%  mean diff %.1f  ssim %.3f" % (changed * 100, mad, ssim), fill=(255, 200, 80))
    sheet.save(out_png)
    return {"changed_ratio": round(changed, 4), "mean_abs_diff": round(mad, 2), "ssim": round(ssim, 4)}


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        sys.exit(2)
    da, db, out = sys.argv[1:4]
    fail_above = float(sys.argv[sys.argv.index("--fail-above") + 1]) if "--fail-above" in sys.argv else None
    os.makedirs(out, exist_ok=True)
    names = sorted(set(f for f in os.listdir(da) if f.endswith(".png")) & set(f for f in os.listdir(db) if f.endswith(".png")))
    report = {}
    bad = False
    for n in names:
        r = compare(os.path.join(da, n), os.path.join(db, n), os.path.join(out, "cmp_" + n))
        report[n] = r
        flag = ""
        if fail_above is not None and r["changed_ratio"] > fail_above:
            bad = True
            flag = "  <-- above limit"
        print("%-28s changed %5.1f%%  diff %5.1f  ssim %.3f%s" % (n, r["changed_ratio"] * 100, r["mean_abs_diff"], r["ssim"], flag))
    only_a = sorted(set(os.listdir(da)) - set(os.listdir(db)))
    only_b = sorted(set(os.listdir(db)) - set(os.listdir(da)))
    report["_only_in_a"] = [n for n in only_a if n.endswith(".png")]
    report["_only_in_b"] = [n for n in only_b if n.endswith(".png")]
    with open(os.path.join(out, "report.json"), "w") as f:
        json.dump(report, f, indent=1)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
