"""Procedural one-shot sound effects for Lone Wolf Arena.

Every sound is synthesised from oscillators / noise (no samples).
`build(out_dir)` writes the WAVs and returns manifest entries.
"""
from __future__ import annotations

import os

import numpy as np

from dsp import (SR, bp, env_ad, env_adsr, fade, finalize, fm, hp, lp, make_ir, modal,
                 mtof, normalize, ns, peq, ramp_exp, reson, reverb, sat, saw, shelf,
                 sine, smear, square, svf, sweep_exp, triangle, tvec, white, colored,
                 write_wav, place)

REGISTRY: list[tuple[str, str, callable]] = []


def sfx(name, desc):
    def deco(fn):
        REGISTRY.append((name, desc, fn))
        return fn
    return deco


# ----------------------------------------------------------------------------
# building blocks
# ----------------------------------------------------------------------------
def nwave(dur=0.0005):
    n = max(3, ns(dur))
    return np.linspace(1.0, -1.0, n)


def thud(n, f0, f1, sweep, tau, attack=0.001):
    return sine(ramp_exp(n, f0, f1, sweep), n) * env_ad(n, attack, tau)


def metal_click(rng, n, base, decay=0.012, ratios=(1.0, 1.59, 2.37, 3.31, 4.52),
                noise_gain=0.6, noise_tau=0.0012, tilt=0.75):
    k = len(ratios)
    freqs = base * np.array(ratios) * (1 + 0.025 * rng.standard_normal(k))
    decays = decay * tilt ** np.arange(k)
    amps = 0.85 ** np.arange(k)
    y = normalize(modal(n, freqs, decays, amps, phases=rng.random(k) * 2 * np.pi))
    nz = hp(white(n, rng), min(base * 0.9, 9000), 2) * env_ad(n, 0.00008, noise_tau)
    return normalize(y + noise_gain * normalize(nz))


def scrape(rng, dur, f_start, f_end, q=2.5, grit=0.6, lo=900, hi=7000):
    n = ns(dur)
    nz = white(n, rng)
    center = ramp_exp(n, f_start, f_end, dur)
    y = svf(nz, center, q, "bp") + 0.35 * bp(nz, lo, hi)
    t = tvec(n)
    env = np.sin(np.pi * np.clip(t / dur, 0, 1)) ** 0.6
    am = 1.0 + grit * np.abs(lp(white(n, rng), 180)) * 4
    return normalize(y * env * am)


def grains(rng, n, count, t0, t1, lo, hi, q=(2.0, 5.0), glen=(0.0004, 0.0025),
           amp_tau=None, time_tau=None, amp_jitter=0.7):
    """Granular crunch: short resonant noise bursts (gravel, debris, crackle)."""
    y = np.zeros(n)
    if time_tau:
        times = t0 + rng.exponential(time_tau, count)
    else:
        times = rng.uniform(t0, t1, count)
    times = times[times < t1]
    for tt in times:
        L = max(8, ns(rng.uniform(*glen)))
        g = white(L + ns(0.004), rng)
        g[L:] = 0
        g[:L] *= np.hanning(L)
        f = np.exp(rng.uniform(np.log(lo), np.log(hi)))
        g = reson(g, f, rng.uniform(*q))
        a = (1 - amp_jitter) + amp_jitter * rng.random()
        if amp_tau:
            a *= np.exp(-(tt - t0) / amp_tau)
        place(y, g, tt, a)
    return y


def glass_shards(rng, n, count, t0, t1, time_tau, amp_tau, flo=2200, fhi=8000):
    y = np.zeros(n)
    times = np.concatenate([rng.uniform(t0, t0 + 0.03, count // 6),
                            t0 + rng.exponential(time_tau, count - count // 6)])
    times = times[times < t1]
    for tt in times:
        L = ns(0.09)
        f = np.exp(rng.uniform(np.log(flo), np.log(fhi)))
        d = rng.uniform(0.006, 0.045)
        ratios = np.array([1.0, 2.23 + 0.2 * rng.random(), 3.6 + 0.4 * rng.random()])
        g = modal(L, f * ratios, d * np.array([1.0, 0.6, 0.4]), [1.0, 0.5, 0.3],
                  phases=rng.random(3) * 6.28)
        g += 0.4 * hp(white(L, rng), 3000) * env_ad(L, 0.00005, 0.0008)
        place(y, g, tt, np.exp(-(tt - t0) / amp_tau) * (0.3 + 0.7 * rng.random()))
    return y


def bell(n, f, tau, bright=1.0, ratio=3.5, index=1.4, index_tau=0.04, attack=0.0015):
    """Chime: pure sine body + quickly decaying FM shimmer."""
    t = tvec(n)
    body = sine(f, n) + 0.22 * sine(2 * f, n) * np.exp(-t / (tau * 0.5))
    shimmer = fm(f, ratio, index * bright, n, np.exp(-t / index_tau))
    shimmer_env = np.exp(-t / (tau * 0.35))
    return (0.75 * body + 0.35 * shimmer * shimmer_env) * env_ad(n, attack, tau)


def room(rng, t60=0.3, **kw):
    return make_ir(t60, rng, **kw)


def gunshot(seed, length, *, thump=(170, 55, 0.06, 0.05, 0.9), body=(0.022, 250, 7000, 1700, 6, 1.0),
            crack=(0.5, 0.003, 2500), boom=(500, 0.05, 0.7), roar=(2200, 0.07, 0.35), drive=2.5,
            mech=None, ir=(0.35, 0.25), pellets=0, presence=(3200, 3.0), hpf=55.0):
    rng = np.random.default_rng(seed)
    n = ns(length + 0.8)
    out = np.zeros(n)
    cg, ctau, chp = crack
    nw = nwave(0.00045)
    out[: nw.size] += cg * nw
    out += cg * 0.8 * normalize(hp(white(n, rng), chp, 4) * env_ad(n, 0.00015, ctau))
    btau, blo, bhi, bpf, bpdb, bg = body
    for k in range(1 + pellets):
        b = bp(white(n, rng), blo, bhi, 2)
        b = peq(b, bpf, 1.1, bpdb) * env_ad(n, 0.0006, btau)
        off = 0 if k == 0 else rng.uniform(0.0008, 0.007)
        place(out, normalize(b), off, bg * (1.0 if k == 0 else 0.45))
    blp, btau2, bg2 = boom
    out += bg2 * normalize(lp(white(n, rng), blp, 4) * env_ad(n, 0.0025, btau2))
    rlp, rtau, rg = roar
    out += rg * normalize(lp(white(n, rng), rlp, 2) * env_ad(n, 0.004, rtau))
    f0, f1, sw, ttau, tg = thump
    th = thud(n, f0, f1, sw, ttau, 0.0012)
    out += tg * sat(th, 1.8)
    out = hp(out, hpf, 2)
    out = sat(normalize(out), drive)
    out = peq(out, presence[0], 1.0, presence[1])
    if mech is not None:
        mt, mbase, mg = mech
        place(out, metal_click(rng, ns(0.08), mbase, 0.01), mt, mg)
    t60, wet = ir
    out = reverb(out, room(rng, t60, predelay=0.006, early=[(0.011, 0.5), (0.019, 0.35), (0.031, 0.25)]),
                 wet=wet)
    return finalize(out, max_len=length, fout=min(0.12, length * 0.35))


# ----------------------------------------------------------------------------
# weapons
# ----------------------------------------------------------------------------
@sfx("ar_shot", "Assault rifle shot: N-wave crack, mid blast, low thump, bolt tick, short room tail.")
def ar_shot():
    return gunshot(101, 0.36, thump=(200, 74, 0.045, 0.038, 0.55),
                   body=(0.032, 220, 7500, 1500, 6, 1.0), crack=(0.6, 0.003, 2600),
                   boom=(650, 0.045, 0.45), roar=(2600, 0.085, 0.55), drive=2.8,
                   mech=(0.048, 2900, 0.10), ir=(0.38, 0.28), hpf=70)


@sfx("sg_shot", "Shotgun blast: heavy low boom, pellet-smeared body, long saturated roar and room tail.")
def sg_shot():
    return gunshot(202, 0.62, thump=(160, 58, 0.08, 0.07, 0.7),
                   body=(0.065, 160, 5500, 850, 5, 1.0), crack=(0.35, 0.004, 2000),
                   boom=(480, 0.09, 0.6), roar=(1900, 0.15, 0.7), drive=3.2,
                   ir=(0.6, 0.32), pellets=5, presence=(2400, 2.0), hpf=52)


@sfx("pistol_shot", "Pistol shot: sharp bright crack, short snappy body, slide tick.")
def pistol_shot():
    return gunshot(303, 0.3, thump=(260, 98, 0.03, 0.026, 0.5),
                   body=(0.016, 400, 9000, 2500, 6, 1.0), crack=(0.65, 0.0024, 3000),
                   boom=(720, 0.03, 0.45), roar=(3000, 0.05, 0.3), drive=2.3,
                   mech=(0.032, 3400, 0.13), ir=(0.3, 0.24), presence=(3800, 3.5), hpf=85)


@sfx("smg_shot", "SMG shot: tight high crack, light snappy body, very short tail for a fast rate of fire.")
def smg_shot():
    return gunshot(505, 0.24, thump=(240, 95, 0.028, 0.022, 0.4),
                   body=(0.018, 320, 9000, 2100, 7, 1.0), crack=(0.62, 0.0022, 3100),
                   boom=(800, 0.028, 0.35), roar=(3200, 0.045, 0.35), drive=2.6,
                   mech=(0.03, 3600, 0.08), ir=(0.28, 0.22), presence=(3600, 3.5), hpf=95)


@sfx("sniper_shot", "Sniper shot: huge supersonic crack, deep boom, long rolling tail, bolt cycled at the end.")
def sniper_shot():
    rng = np.random.default_rng(606)
    shot = gunshot(606, 0.95, thump=(150, 48, 0.09, 0.08, 0.85),
                   body=(0.05, 180, 8000, 1300, 6, 1.0), crack=(0.8, 0.004, 2200),
                   boom=(420, 0.12, 0.8), roar=(2000, 0.2, 0.75), drive=3.4,
                   ir=(0.9, 0.36), presence=(2800, 3.0), hpf=45)
    out = np.zeros(ns(1.25))
    out[: shot.size] += shot
    # bolt: lift + pull back, then push forward + lock
    place(out, 0.22 * metal_click(rng, ns(0.08), 2300, 0.012), 0.72, 1.0)
    place(out, 0.18 * normalize(scrape(rng, 0.09, 1800, 3200, grit=0.5)), 0.76, 1.0)
    place(out, 0.18 * normalize(scrape(rng, 0.08, 3000, 1900, grit=0.5)), 0.93, 1.0)
    place(out, 0.26 * metal_click(rng, ns(0.08), 2600, 0.01), 1.02, 1.0)
    return finalize(out, max_len=1.2, fout=0.08)


@sfx("shot_far", "Distant gunshot (enemy fire): low-passed muffled boom with outdoor echo slaps.")
def shot_far():
    rng = np.random.default_rng(404)
    n = ns(1.6)
    out = np.zeros(n)
    b = peq(bp(white(n, rng), 260, 3000, 2), 750, 1.0, 6) * env_ad(n, 0.0015, 0.035)
    out += normalize(b)
    out += 0.3 * normalize(lp(white(n, rng), 600, 4) * env_ad(n, 0.004, 0.06))
    out += 0.25 * sat(thud(n, 160, 80, 0.05, 0.05, 0.003), 1.5)
    out = hp(out, 120, 2)
    out = sat(normalize(out), 2.2)
    out = lp(out, 1900, 4)
    ir = make_ir(0.95, rng, predelay=0.02, hf_ratio=0.3, buildup=0.03,
                 early=[(0.085, 1.0), (0.19, 0.75), (0.31, 0.55), (0.45, 0.35)])
    out = reverb(out, ir, wet=0.6, dry=0.9)
    out = lp(out, 2600, 2)
    return finalize(out, max_len=0.62, fout=0.22)


@sfx("reload_mag", "Rifle magazine reload: release click, mag slide out, mag in clack + latch, bolt pull and slam.")
def reload_mag():
    rng = np.random.default_rng(505)
    n = ns(1.5)
    out = np.zeros(n)
    place(out, metal_click(rng, ns(0.06), 3600, 0.006), 0.04, 0.35)          # release button
    place(out, scrape(rng, 0.13, 1800, 3200, 3.0, 0.5), 0.07, 0.22)          # mag slides out
    place(out, metal_click(rng, ns(0.1), 1500, 0.02, noise_gain=0.4), 0.2, 0.45)  # mag leaves well
    place(out, thud(ns(0.08), 260, 150, 0.03, 0.02), 0.2, 0.25)
    place(out, scrape(rng, 0.07, 1400, 2600, 2.5, 0.4), 0.5, 0.25)          # mag in slide
    m = ns(0.18)
    clack = metal_click(rng, m, 820, 0.035, ratios=(1.0, 2.07, 3.48, 5.2, 7.1), noise_gain=0.7) \
        + 0.8 * thud(m, 180, 95, 0.03, 0.03)
    place(out, normalize(clack), 0.565, 1.0)                                  # mag in clack
    place(out, metal_click(rng, ns(0.06), 4200, 0.006), 0.6, 0.35)          # latch
    place(out, scrape(rng, 0.09, 1200, 3800, 2.8, 0.8), 0.82, 0.35)         # bolt back
    place(out, metal_click(rng, ns(0.08), 2400, 0.012), 0.905, 0.5)         # bolt at rear
    m = ns(0.3)
    slam = metal_click(rng, m, 1250, 0.07, ratios=(1.0, 1.73, 2.91, 4.1, 5.83), noise_gain=0.9, tilt=0.65) \
        + 0.7 * thud(m, 210, 90, 0.03, 0.025)
    place(out, normalize(slam), 1.0, 1.05)                                    # bolt slam
    out = reverb(out, room(rng, 0.22, predelay=0.003), wet=0.14)
    return finalize(out, max_len=1.22, fout=0.08)


@sfx("reload_shell", "Shotgun shell insert: short slide 'shk' then latch click with plastic body.")
def reload_shell():
    rng = np.random.default_rng(606)
    n = ns(0.5)
    out = np.zeros(n)
    place(out, scrape(rng, 0.055, 2200, 4800, 2.0, 0.9, 1500, 8000), 0.0, 0.5)
    m = ns(0.2)
    c = metal_click(rng, m, 1350, 0.03, ratios=(1.0, 1.93, 3.26, 4.4), noise_gain=0.7) \
        + 0.6 * thud(m, 320, 170, 0.02, 0.02) \
        + 0.35 * bp(white(m, rng), 300, 1800) * env_ad(m, 0.0002, 0.01)
    place(out, normalize(c), 0.06, 1.0)
    place(out, metal_click(rng, ns(0.05), 3900, 0.005), 0.085, 0.2)
    out = reverb(out, room(rng, 0.2), wet=0.12)
    return finalize(out, max_len=0.3, fout=0.06)


@sfx("pump", "Shotgun pump rack: back slide + heavy clack, forward slide + locking clack.")
def pump():
    rng = np.random.default_rng(707)
    n = ns(0.6)
    out = np.zeros(n)
    place(out, scrape(rng, 0.08, 900, 2600, 2.2, 0.8, 700, 6000), 0.0, 0.4)
    m = ns(0.16)
    c1 = metal_click(rng, m, 640, 0.03, ratios=(1.0, 2.18, 3.6, 5.3, 7.4), noise_gain=0.85) \
        + 0.9 * thud(m, 170, 90, 0.025, 0.03)
    place(out, normalize(c1), 0.075, 1.0)
    place(out, scrape(rng, 0.06, 2600, 1100, 2.2, 0.7, 700, 6000), 0.15, 0.35)
    c2 = metal_click(rng, m, 760, 0.04, ratios=(1.0, 2.11, 3.4, 4.9, 6.9), noise_gain=0.9) \
        + 0.8 * thud(m, 190, 100, 0.025, 0.03)
    place(out, normalize(c2), 0.205, 1.0)
    out = reverb(out, room(rng, 0.25), wet=0.13)
    return finalize(out, max_len=0.36, fout=0.07)


@sfx("empty_click", "Dry-fire click: hammer fall on empty chamber plus faint trigger reset.")
def empty_click():
    rng = np.random.default_rng(808)
    n = ns(0.2)
    out = np.zeros(n)
    place(out, metal_click(rng, ns(0.08), 2100, 0.012, ratios=(1.0, 1.62, 2.67, 3.8), noise_gain=0.8), 0.0, 1.0)
    place(out, metal_click(rng, ns(0.05), 3300, 0.005), 0.045, 0.3)
    out = reverb(out, room(rng, 0.15), wet=0.08)
    return finalize(out, max_len=0.15, fout=0.03)


# ----------------------------------------------------------------------------
# movement
# ----------------------------------------------------------------------------
def footstep(seed, heavy=1.0):
    rng = np.random.default_rng(seed)
    n = ns(0.3)
    out = np.zeros(n)
    p = 2 ** (rng.uniform(-0.2, 0.2))
    out += 0.3 * heavy * thud(n, 170 * p, 105 * p, 0.015, 0.012, 0.001)
    heel = bp(white(n, rng), 160 * p, 1400 * p, 2) * env_ad(n, 0.0008, 0.011)
    heel = reson(heel, rng.uniform(380, 560) * p, 2.5) * 0.7 + heel
    out += 0.8 * normalize(heel)
    out += 0.4 * normalize(bp(white(n, rng), 1500, 7500) * env_ad(n, 0.0015, 0.02))
    out += 0.75 * normalize(grains(rng, n, int(rng.integers(18, 32)), 0.0, 0.11, 1300, 7000,
                                   time_tau=0.025, amp_tau=0.05))
    toe = ns(rng.uniform(0.035, 0.055))
    m = ns(0.1)
    toe_sig = 0.35 * normalize(bp(white(m, rng), 250 * p, 1800 * p) * env_ad(m, 0.0006, 0.008)) \
        + 0.3 * normalize(grains(rng, m, 10, 0.0, 0.05, 1500, 6500, time_tau=0.015, amp_tau=0.03))
    place(out, toe_sig, start_idx=toe)
    out = hp(out, 90, 2)
    out = reverb(out, room(rng, 0.18, bright=0.6), wet=0.07)
    return finalize(out, max_len=0.15, fout=0.04)


for _i, _seed in enumerate([11, 23, 37, 41], start=1):
    REGISTRY.append((f"footstep_{_i}", f"Footstep {_i}/4 on concrete with gravel crunch (heel thud + toe roll).",
                     (lambda s=_seed: footstep(s))))


@sfx("jump", "Jump: gravel push-off scuff with upward cloth whoosh.")
def jump():
    rng = np.random.default_rng(909)
    n = ns(0.5)
    out = np.zeros(n)
    out += 0.6 * normalize(grains(rng, n, 25, 0.0, 0.08, 1400, 6500, time_tau=0.02, amp_tau=0.04))
    out += 0.5 * thud(n, 130, 80, 0.02, 0.015)
    out += 0.4 * normalize(bp(white(n, rng), 1500, 6000) * env_ad(n, 0.002, 0.03))
    m = ns(0.3)
    w = svf(white(m, rng), ramp_exp(m, 500, 2400, 0.22), 1.3, "bp")
    t = tvec(m)
    w *= np.sin(np.pi * np.clip(t / 0.26, 0, 1)) ** 1.5
    place(out, normalize(w), 0.02, 0.5)
    out = reverb(out, room(rng, 0.2), wet=0.07)
    return finalize(out, max_len=0.32, fout=0.08)


@sfx("land", "Landing: heavy body thud, double foot impact, gravel crunch and cloth rustle.")
def land():
    rng = np.random.default_rng(1010)
    n = ns(0.6)
    out = np.zeros(n)
    out += 0.65 * sat(thud(n, 160, 68, 0.05, 0.045, 0.0015), 1.8)
    out += 0.8 * normalize(bp(white(n, rng), 120, 1000) * env_ad(n, 0.0015, 0.03))
    out += 0.9 * normalize(grains(rng, n, 55, 0.0, 0.2, 1200, 7000, time_tau=0.045, amp_tau=0.09))
    out += 0.4 * normalize(bp(white(n, rng), 900, 3500) * env_ad(n, 0.004, 0.06))
    m = ns(0.2)
    second = 0.4 * normalize(bp(white(m, rng), 150, 1200) * env_ad(m, 0.001, 0.015)) + 0.35 * normalize(
        grains(rng, m, 15, 0.0, 0.08, 1500, 6500, time_tau=0.02, amp_tau=0.04))
    place(out, second, 0.075)
    out = hp(out, 55, 2)
    out = reverb(out, room(rng, 0.25, bright=0.6), wet=0.08)
    return finalize(out, max_len=0.38, fout=0.1)


# ----------------------------------------------------------------------------
# combat feedback
# ----------------------------------------------------------------------------
@sfx("hit_body", "Hitmarker tick: crisp short tonal tick with click transient (body hit confirm).")
def hit_body():
    rng = np.random.default_rng(1111)
    n = ns(0.15)
    t = tvec(n)
    out = 0.55 * normalize(hp(white(n, rng), 2800, 2) * env_ad(n, 0.00005, 0.0012))
    out += 0.9 * sine(ramp_exp(n, 1650, 1250, 0.012), n) * env_ad(n, 0.0004, 0.011)
    out += 0.35 * sine(4300, n) * env_ad(n, 0.0002, 0.005)
    out += 0.4 * sine(ramp_exp(n, 520, 300, 0.012), n) * env_ad(n, 0.0006, 0.01)
    out = sat(normalize(out), 1.4)
    out = reverb(out, room(rng, 0.12), wet=0.05)
    return finalize(out, max_len=0.09, fout=0.03)


@sfx("hit_head", "Headshot cue: bright metallic 'tink' followed by a short shimmering ding.")
def hit_head():
    rng = np.random.default_rng(1212)
    n = ns(0.7)
    out = np.zeros(n)
    tink = modal(n, 2450 * np.array([1.0, 2.756, 5.404]), [0.07, 0.03, 0.014], [1.0, 0.55, 0.3])
    tink += 0.5 * normalize(hp(white(n, rng), 4000) * env_ad(n, 0.00005, 0.0009))
    out += 0.85 * normalize(tink)
    out += 0.3 * sine(ramp_exp(n, 700, 320, 0.02), n) * env_ad(n, 0.0005, 0.012)
    m = ns(0.6)
    t = tvec(m)
    f = 1567.98
    ding = (sine(f, m) + 0.6 * sine(f * 1.0035, m, 0.3) + 0.3 * sine(2 * f, m) * np.exp(-t / 0.06)
            + 0.12 * fm(f, 3.0, 1.2, m, np.exp(-t / 0.02)))
    ding *= env_ad(m, 0.002, 0.15)
    place(out, normalize(ding), 0.014, 0.8)
    out = reverb(out, room(rng, 0.45, bright=1.2), wet=0.13)
    return finalize(out, max_len=0.55, fout=0.15)


@sfx("kill_confirm", "Kill confirm: rising whoosh into a two-note chime (E6 -> B6) with sub punch.")
def kill_confirm():
    rng = np.random.default_rng(1313)
    n = ns(1.4)
    out = np.zeros(n)
    m = ns(0.45)
    t = tvec(m)
    w = svf(white(m, rng), ramp_exp(m, 450, 3800, 0.3), 1.6, "bp")
    w *= np.clip(t / 0.14, 0, 1) ** 2 * np.exp(-np.maximum(t - 0.14, 0) / 0.08)
    place(out, normalize(w), 0.0, 0.35)
    place(out, normalize(bell(ns(0.8), mtof(88), 0.22)), 0.04, 0.65)
    b2 = bell(ns(1.2), mtof(95), 0.42) + 0.25 * sine(mtof(107), ns(1.2)) * env_ad(ns(1.2), 0.002, 0.12)
    place(out, normalize(b2), 0.15, 0.85)
    place(out, sat(thud(ns(0.3), 170, 60, 0.04, 0.06), 1.5), 0.15, 0.4)
    out = reverb(out, room(rng, 0.8, bright=1.1, predelay=0.012), wet=0.24)
    return finalize(out, max_len=0.95, fout=0.3)


@sfx("hurt", "Player damaged: dull body thud with low formant-filtered noise 'grunt' texture (no voice).")
def hurt():
    rng = np.random.default_rng(1414)
    n = ns(0.6)
    t = tvec(n)
    out = 0.6 * sat(thud(n, 150, 68, 0.06, 0.05, 0.002), 2.2)
    out += 0.45 * normalize(lp(white(n, rng), 600, 4) * env_ad(n, 0.001, 0.025))
    out += 0.7 * normalize(peq(bp(white(n, rng), 200, 1400), 450, 1.2, 6) * env_ad(n, 0.001, 0.025))
    m = ns(0.4)
    tm = tvec(m)
    src = colored(m, rng, 1.0) * (1 + 0.45 * np.sin(2 * np.pi * 72 * tm))
    f1 = ramp_exp(m, 560, 380, 0.25)
    g = svf(src, f1, 4.0, "bp") + 0.6 * svf(src, f1 * 2.1, 5.0, "bp") + 0.2 * reson(src, 2500, 6)
    g *= env_ad(m, 0.018, 0.1)
    g = lp(g, 1800, 2)
    place(out, normalize(g), 0.012, 0.75)
    out = hp(out, 60, 2)
    out = reverb(out, room(rng, 0.22, bright=0.5), wet=0.08)
    return finalize(out, max_len=0.42, fout=0.12)


# ----------------------------------------------------------------------------
# items / abilities
# ----------------------------------------------------------------------------
@sfx("heal", "Healing in progress: soft shimmering major arpeggio pad with sparkles (~1.5 s).")
def heal():
    rng = np.random.default_rng(1515)
    n = ns(2.4)
    t = tvec(n)
    out = np.zeros(n)
    notes = [72, 76, 79, 84, 88]
    for i, mn in enumerate(notes):
        st = 0.06 * i
        m = n - ns(st)
        tm = tvec(m)
        f = mtof(mn) * (1 + 0.003 * np.sin(2 * np.pi * 5.2 * tm + i))
        v = sine(f, m) + 0.15 * sine(2 * f, m)
        trem = (1 + 0.35 * np.sin(2 * np.pi * (6.0 + 0.8 * i) * tm + rng.random() * 6.28)) / 1.35
        env = np.clip(tm / 0.25, 0, 1) ** 1.5 * np.clip((1.45 - st - tm) / 0.35, 0, 1) ** 1.2
        place(out, v * trem * env, st, 0.25 * (1 - 0.1 * i))
    sparkle_notes = [96, 98, 100, 103, 105, 108]
    for k in range(26):
        st = rng.uniform(0.08, 1.15)
        m = ns(0.3)
        f = mtof(rng.choice(sparkle_notes))
        place(out, bell(m, f, 0.06, bright=0.6), st, 0.06 + 0.05 * rng.random())
    air = hp(white(n, rng), 5000) * np.clip(t / 0.4, 0, 1) * np.clip((1.45 - t) / 0.5, 0, 1)
    out += 0.03 * normalize(air)
    sw = svf(white(n, rng), ramp_exp(n, 700, 5000, 1.2), 2.0, "bp") * np.sin(np.pi * np.clip(t / 1.45, 0, 1)) ** 2
    out += 0.12 * normalize(sw)
    out = reverb(out, room(rng, 1.0, bright=1.1, predelay=0.015), wet=0.32)
    return finalize(out, max_len=1.52, fin=0.02, fout=0.25)


@sfx("heal_done", "Heal complete: quick ascending bell arpeggio (G5-C6-E6-G6) with soft glow.")
def heal_done():
    rng = np.random.default_rng(1616)
    n = ns(1.2)
    out = np.zeros(n)
    for i, (mn, st) in enumerate([(79, 0.0), (84, 0.06), (88, 0.12), (91, 0.18)]):
        tau = 0.1 if i < 3 else 0.32
        place(out, normalize(bell(ns(0.9), mtof(mn), tau, bright=0.8)), st, 0.55 + 0.15 * i)
    m = ns(0.5)
    tm = tvec(m)
    glow = sine(ramp_exp(m, 392, 784, 0.18), m) * env_ad(m, 0.03, 0.12)
    place(out, glow, 0.0, 0.15)
    out = reverb(out, room(rng, 0.8, bright=1.1, predelay=0.01), wet=0.28)
    return finalize(out, max_len=0.65, fout=0.22)


@sfx("shield_deploy", "Energy shield deploy: rising energy whoosh, crystalline arpeggio build, bright clamp.")
def shield_deploy():
    rng = np.random.default_rng(1717)
    n = ns(1.4)
    t = tvec(n)
    out = np.zeros(n)
    peak_t = 0.44
    w = svf(white(n, rng), ramp_exp(n, 250, 5200, peak_t), 2.5, "bp")
    w *= np.clip(t / peak_t, 0, 1) ** 2 * np.exp(-np.maximum(t - peak_t, 0) / 0.07)
    out += 0.5 * normalize(w)
    f = ramp_exp(n, 70, 280, peak_t)
    pw = sine(f, n) + 0.4 * sine(2 * f, n) + 0.2 * saw(3 * f, n) * 0.3
    pw *= np.clip(t / peak_t, 0, 1) ** 2.2 * np.exp(-np.maximum(t - peak_t, 0) / 0.04)
    out += 0.45 * sat(normalize(pw), 1.5)
    scale = [76, 80, 83, 88, 92, 95, 100, 104]
    for i, mn in enumerate(scale):
        st = 0.1 + i * 0.042
        m = ns(0.25)
        fr = mtof(mn)
        g = modal(m, fr * np.array([1.0, 2.32, 4.25]), [0.07, 0.04, 0.02], [1.0, 0.4, 0.2])
        place(out, normalize(g) * env_ad(m, 0.001, 0.2), st, 0.12 + 0.05 * i)
    m = ns(0.9)
    tm = tvec(m)
    clamp = np.zeros(m)
    for mn, a in [(88, 1.0), (95, 0.8), (100, 0.6), (107, 0.3)]:
        fr = mtof(mn)
        clamp += a * (sine(fr, m) + 0.3 * sine(fr * 2.32, m) * np.exp(-tm / 0.05)) * \
            (1 + 0.25 * np.sin(2 * np.pi * 9 * tm)) / 1.25
    clamp *= env_ad(m, 0.002, 0.18)
    clamp += 0.4 * normalize(hp(white(m, rng), 6000) * env_ad(m, 0.0005, 0.05))
    place(out, normalize(clamp), peak_t, 0.75)
    place(out, sat(thud(ns(0.3), 160, 55, 0.05, 0.06), 1.6), peak_t, 0.55)
    out = reverb(out, room(rng, 0.6, bright=1.2, predelay=0.01), wet=0.24)
    return finalize(out, max_len=0.82, fout=0.25)


@sfx("shield_break", "Energy shield break: impact crack, downward energy discharge and glassy shatter shards.")
def shield_break():
    rng = np.random.default_rng(1818)
    n = ns(1.4)
    t = tvec(n)
    out = np.zeros(n)
    out += 0.8 * normalize(hp(white(n, rng), 900) * env_ad(n, 0.0002, 0.012))
    out += 0.45 * sat(thud(n, 170, 75, 0.05, 0.04), 1.8)
    f = ramp_exp(n, 1500, 140, 0.32)
    dis = fm(f, 0.5, 3.0, n, np.exp(-t / 0.15)) * env_ad(n, 0.002, 0.13)
    out += 0.2 * dis
    out += 0.5 * normalize(bp(white(n, rng), 2500, 11000) * env_ad(n, 0.001, 0.08))
    out += 1.25 * normalize(glass_shards(rng, n, 150, 0.003, 0.75, 0.13, 0.24))
    out = hp(out, 60, 2)
    out = reverb(out, room(rng, 0.55, bright=1.3), wet=0.2)
    return finalize(out, max_len=0.9, fout=0.3)


@sfx("grenade_throw", "Grenade throw: pin pull ring, spoon flick 'tink', arm swing whoosh.")
def grenade_throw():
    rng = np.random.default_rng(1919)
    n = ns(0.8)
    t = tvec(n)
    out = np.zeros(n)
    place(out, scrape(rng, 0.03, 3000, 6000, 2.0, 0.5, 2500, 9000), 0.0, 0.25)
    m = ns(0.3)
    ring = modal(m, [3700, 5930, 8810, 11200], [0.11, 0.07, 0.045, 0.03], [1.0, 0.6, 0.35, 0.2])
    place(out, normalize(ring) + 0.3 * normalize(hp(white(m, rng), 3000) * env_ad(m, 0.0001, 0.001)), 0.025, 0.45)
    m = ns(0.15)
    tink = modal(m, [2950, 4720, 7330], [0.04, 0.025, 0.015], [1.0, 0.6, 0.3])
    place(out, normalize(tink), 0.13, 0.35)
    m = ns(0.4)
    tm = tvec(m)
    cf = 300 * np.exp(np.log(1500 / 300) * np.sin(np.pi * np.clip(tm / 0.32, 0, 1)))
    wh = svf(white(m, rng), cf, 1.2, "bp") + 0.4 * lp(white(m, rng), 700)
    wh *= np.sin(np.pi * np.clip(tm / 0.32, 0, 1)) ** 2
    place(out, normalize(wh), 0.17, 0.85)
    out = reverb(out, room(rng, 0.25), wet=0.1)
    return finalize(out, max_len=0.52, fout=0.1)


@sfx("explosion", "Grenade explosion: transient crack, saturated sub boom, falling-filter body, crackle and debris tail.")
def explosion():
    rng = np.random.default_rng(2020)
    n = ns(3.2)
    t = tvec(n)
    out = np.zeros(n)
    nw = nwave(0.0012)
    out[: nw.size] += 0.7 * nw
    out += 0.6 * normalize(hp(white(n, rng), 600) * env_ad(n, 0.0002, 0.007))
    boom = sine(ramp_exp(n, 120, 45, 0.45), n) * env_ad(n, 0.003, 0.33)
    out += 0.55 * sat(boom, 3.0)
    br = colored(n, rng, 1.5)
    body = svf(br, sweep_exp(n, 6000, 260, 0.25), 0.8, "lp", poles=4) * env_ad(n, 0.004, 0.38)
    out += 1.0 * normalize(body)
    out += 1.0 * sat(normalize(bp(white(n, rng), 250, 3000) * env_ad(n, 0.002, 0.18)), 3.0)
    out += 0.45 * normalize(grains(rng, n, 90, 0.01, 0.6, 2500, 9000, q=(1.0, 2.0),
                                   glen=(0.0002, 0.0008), time_tau=0.15, amp_tau=0.25))
    deb = grains(rng, n, 160, 0.15, 1.85, 700, 5000, q=(2.0, 6.0), glen=(0.0005, 0.003),
                 time_tau=0.45, amp_tau=0.55)
    for k in range(9):
        st = rng.uniform(0.3, 1.4)
        m = ns(0.12)
        place(deb, thud(m, rng.uniform(90, 180), 60, 0.02, 0.02) * 2.5, st, np.exp(-(st - 0.3) / 0.6))
    out += 0.7 * normalize(deb)
    out += 0.35 * normalize(lp(colored(n, rng, 2.0), 220, 4) * env_ad(n, 0.05, 0.7))
    out = hp(out, 42, 2)
    out = sat(normalize(out), 2.4)
    ir = make_ir(1.5, rng, predelay=0.02, hf_ratio=0.35, buildup=0.02,
                 early=[(0.09, 0.8), (0.21, 0.6), (0.37, 0.4)])
    out = reverb(out, ir, wet=0.38)
    return finalize(out, max_len=1.85, fout=0.45)


# ----------------------------------------------------------------------------
# UI / match flow
# ----------------------------------------------------------------------------
@sfx("countdown_beep", "Countdown tick: short digital beep at A5 (880 Hz).")
def countdown_beep():
    rng = np.random.default_rng(2121)
    n = ns(0.4)
    f = 880.0
    tone = sine(f, n) + 0.25 * sine(2 * f, n) + 0.12 * lp(square(f, n), 3000)
    tone *= env_adsr(n, 0.003, 0.05, 0.8, 0.025, 0.1)
    out = reverb(tone, room(rng, 0.25), wet=0.1)
    return finalize(out, max_len=0.2, fout=0.05)


@sfx("countdown_go", "Countdown GO: punchy bright A power-chord stab with impact and short tail.")
def countdown_go():
    rng = np.random.default_rng(2222)
    n = ns(1.2)
    t = tvec(n)
    out = np.zeros(n)
    pitch = 1 - 0.06 * np.exp(-t / 0.015)
    for mn, a in [(81, 1.0), (88, 0.8), (93, 0.7), (69, 0.6)]:
        f = mtof(mn) * pitch
        v = 0.6 * sine(f, n) + 0.4 * lp(saw(f, n, rng.random()), 5000)
        out += a * v
    out *= env_adsr(n, 0.004, 0.15, 0.55, 0.12, 0.32)
    out = normalize(out)
    out += 0.7 * sat(thud(n, 160, 50, 0.05, 0.08), 1.8)
    out += 0.4 * normalize(bp(white(n, rng), 1200, 7000) * env_ad(n, 0.0005, 0.02))
    out = reverb(out, room(rng, 0.6, predelay=0.01), wet=0.2)
    return finalize(out, max_len=0.62, fout=0.2)


@sfx("ui_click", "UI tap: soft short click.")
def ui_click():
    rng = np.random.default_rng(2323)
    n = ns(0.1)
    out = 0.8 * sine(2400, n) * env_ad(n, 0.0003, 0.005)
    out += 0.4 * normalize(hp(white(n, rng), 3000) * env_ad(n, 0.00005, 0.0012))
    out += 0.35 * sine(1200, n) * env_ad(n, 0.0005, 0.009)
    out = reverb(out, room(rng, 0.1), wet=0.04)
    return finalize(out, max_len=0.05, fout=0.015)


@sfx("ui_select", "UI confirm: bright two-note upward blip (E6 -> A6).")
def ui_select():
    rng = np.random.default_rng(2424)
    n = ns(0.4)
    out = np.zeros(n)
    for mn, st, tau, a in [(88, 0.0, 0.035, 0.8), (93, 0.05, 0.07, 1.0)]:
        m = ns(0.3)
        f = mtof(mn)
        v = sine(f, m) + 0.25 * triangle(2 * f, m) + 0.1 * sine(3 * f, m)
        place(out, v * env_ad(m, 0.002, tau), st, a)
    out = reverb(out, room(rng, 0.25), wet=0.08)
    return finalize(out, max_len=0.17, fout=0.05)


@sfx("ui_back", "UI back/cancel: soft two-note downward blip (A5 -> E5).")
def ui_back():
    rng = np.random.default_rng(2525)
    n = ns(0.4)
    out = np.zeros(n)
    for mn, st, tau, a in [(81, 0.0, 0.035, 1.0), (76, 0.05, 0.065, 0.85)]:
        m = ns(0.3)
        f = mtof(mn)
        v = sine(f, m) + 0.2 * triangle(2 * f, m)
        place(out, lp(v, 3000) * env_ad(m, 0.002, tau), st, a)
    out = reverb(out, room(rng, 0.25), wet=0.08)
    return finalize(out, max_len=0.17, fout=0.05)


def build(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    entries = []
    for name, desc, fn in REGISTRY:
        x = fn()
        path = os.path.join(out_dir, f"{name}.wav")
        write_wav(path, x)
        entries.append({"name": f"{name}.wav", "duration": round(x.shape[0] / SR, 3),
                        "channels": 1, "loop": False, "description": desc})
        print(f"  {name:16s} {x.shape[0] / SR:6.3f}s")
    return entries


if __name__ == "__main__":
    import sys
    build(sys.argv[1] if len(sys.argv) > 1 else "/root/work/assets/audio")
