"""Procedural music + ambience: lobby loop (stereo), victory/defeat stingers, match ambience.

Loops are rendered *circularly*: every note tail, delay echo and reverb tail that
runs past the loop end wraps around to the start, so the file loops seamlessly.

`build(out_dir)` also writes lobby_music.wav, the master that audio_qa.py checks for the loop
seam; the game ships only its .ogg copy. Run tools/media/build_audio.py to rebuild the game's
audio: it renders into tools/media/_work/audio/ (also this script's default out_dir) and copies
only the shipped files into assets/audio/.
"""
from __future__ import annotations

import os

import numpy as np

from dsp import (SR, circular, shelf, bp, circ_conv, colored, env_ad, env_adsr, fade, finalize, hp, hp_circular,
                 lp, lp_circular, make_ir, mtof, normalize, ns, pan, periodic_smooth, place,
                 ramp_exp, reverb, sat, saw, sine, softclip, square, supersaw, svf,
                 svf_circular, sweep_exp, triangle, tvec, undb, white, wrap_add, write_wav,
                 bp_circular, reson, PEAK)

# ----------------------------------------------------------------------------
# instruments (mono unless noted)
# ----------------------------------------------------------------------------


def inst_kick(rng, tone=1.0):
    n = ns(0.5)
    f = sweep_exp(n, 210 * tone, 50 * tone, 0.028)
    body = sine(f, n) * env_ad(n, 0.0008, 0.17)
    click = hp(white(n, rng), 2500) * env_ad(n, 0.0001, 0.0018)
    y = sat(1.3 * body, 1.6) + 0.22 * normalize(click)
    return fade(normalize(y), 0, 0.03)


def inst_808(rng, note, dur, glide_to=None, glide_time=0.08, punch=0.5):
    n = ns(dur + 0.03)
    t = tvec(n)
    f = mtof(note) * (1 + punch * np.exp(-t / 0.014))
    if glide_to is not None:
        g0 = max(dur - glide_time, 0.0)
        k = np.clip((t - g0) / glide_time, 0, 1)
        k = k * k * (3 - 2 * k)
        f = f * (mtof(glide_to) / mtof(note)) ** k
    y = sine(f, n)
    env = np.clip(t / 0.002, 0, 1) * (0.35 + 0.65 * np.exp(-t / 0.9))
    env *= np.clip((dur + 0.03 - t) / 0.03, 0, 1)
    y = sat(1.0 * y, 2.6) * env
    y = lp(y, 1100, 2)
    return y


def inst_snare(rng):
    n = ns(0.45)
    t = tvec(n)
    noise = bp(white(n, rng), 1300, 9500) * env_ad(n, 0.0005, 0.075)
    body = sine(sweep_exp(n, 290, 190, 0.018), n) * env_ad(n, 0.0005, 0.04)
    clap = np.zeros(n)
    for k, d in enumerate([0.0, 0.0085, 0.017]):
        m = ns(0.03)
        burst = bp(white(m, rng), 900, 5000) * env_ad(m, 0.0002, 0.004)
        place(clap, burst, d)
    tail = bp(white(n, rng), 900, 6000) * env_ad(n, 0.001, 0.07)
    place(clap, tail[: n - ns(0.026)], 0.026, 0.9)
    y = 0.55 * normalize(noise) + 0.45 * body + 0.8 * normalize(clap)
    return fade(normalize(y), 0, 0.05)


_HAT_F = np.array([205.3, 304.4, 369.6, 522.7, 540.0, 800.0])


def inst_hat(rng, open_=False, tone=1.0):
    n = ns(0.6 if open_ else 0.12)
    metal = sum(square(f * tone, n, 0.5, rng.random()) for f in _HAT_F)
    y = bp(metal, 7000, 15000, 2) + 0.5 * hp(white(n, rng), 8000) * 2.0
    env = env_ad(n, 0.0003, 0.16 if open_ else 0.018)
    return fade(normalize(y * env), 0, 0.01)


def inst_crash(rng, dur=2.4):
    n = ns(dur)
    metal = sum(square(f * 1.47, n, 0.5, rng.random()) for f in _HAT_F) + sum(
        square(f * 2.13, n, 0.5, rng.random()) for f in _HAT_F)
    y = hp(0.6 * bp(metal, 3000, 15000) + hp(white(n, rng), 4000), 3000)
    y *= env_ad(n, 0.0008, 0.55) * (1 - 0.4 * np.exp(-tvec(n) / 0.02))
    return fade(normalize(y), 0, 0.2)


def inst_rim(rng):
    n = ns(0.08)
    y = sine(1700, n) * env_ad(n, 0.0002, 0.008) + 0.6 * sine(820, n) * env_ad(n, 0.0002, 0.012)
    y += 0.5 * normalize(bp(white(n, rng), 2000, 8000) * env_ad(n, 0.0001, 0.003))
    return fade(normalize(y), 0, 0.02)


def inst_pluck(rng, note, vel=1.0, decay=0.2):
    n = ns(0.55)
    t = tvec(n)
    f = mtof(note)
    osc = 0.55 * saw(f, n, rng.random()) + 0.45 * square(f * 1.004, n, 0.42, rng.random())
    cut = 500 + 7500 * vel * np.exp(-t / 0.07)
    y = svf(osc, cut, 1.3, "lp")
    y *= env_ad(n, 0.0015, decay)
    return fade(y, 0, 0.05) * vel


def inst_lead(rng, note, dur, vel=1.0):
    n = ns(dur + 0.35)
    t = tvec(n)
    vib = 0.0045 * np.sin(2 * np.pi * 5.6 * t) * np.clip((t - 0.16) / 0.2, 0, 1)
    f = mtof(note) * (1 + vib) * 2 ** (-12 * np.exp(-t / 0.012) / 1200)
    osc = (0.5 * square(f, n, 0.33, rng.random()) + 0.35 * saw(f * 1.003, n, rng.random())
           + 0.25 * sine(2 * f, n) * np.exp(-t / 0.25))
    cut = 2200 + 5000 * np.exp(-t / 0.11)
    y = svf(osc, cut, 1.1, "lp")
    y *= env_adsr(n, 0.004, 0.12, 0.62, 0.09, dur)
    return fade(y, 0, 0.05) * vel


def inst_pad(rng, notes, dur, cutoff=1500):
    n = ns(dur + 0.6)
    t = tvec(n)
    out = np.zeros((n, 2))
    for k, m in enumerate(notes):
        out += supersaw(mtof(m), n, voices=5, detune_cents=13, rng=rng, stereo=True, spread=0.85)
    cut = cutoff * (0.75 + 0.25 * np.sin(np.pi * np.clip(t / (dur + 0.6), 0, 1)))
    out[:, 0] = svf(out[:, 0], cut, 0.8, "lp", poles=4)
    out[:, 1] = svf(out[:, 1], cut, 0.8, "lp", poles=4)
    env = env_adsr(n, 0.25, 0.6, 0.85, 0.35, dur)
    return out * env[:, None] / len(notes)


def inst_riser(rng, dur):
    n = ns(dur)
    t = tvec(n)
    k = t / dur
    y = svf(white(n, rng), 400 * (12000 / 400) ** k, 2.0, "bp")
    return y * k ** 2.2


# ----------------------------------------------------------------------------
# lobby loop
# ----------------------------------------------------------------------------
BPM = 140
BEAT = SR * 60 / BPM            # 18900 samples
STEP = BEAT / 4                 # 4725 samples per 16th
BARS = 16
BUS = {"drums": 1.0, "bass": 0.33, "music": 1.85, "delay": 1.9, "reverb": 1.6}

CHORDS = [  # (808 root, pad voicing, arp pool)
    (30, [54, 61, 66, 69, 73], [66, 69, 73, 78]),   # F#m
    (38, [50, 57, 62, 66, 69], [66, 69, 74, 78]),   # D
    (35, [47, 54, 59, 62, 66], [66, 71, 74, 78]),   # Bm
    (37, [49, 56, 61, 65, 68], [65, 68, 73, 77]),   # C#
]

# lead hook for bars 8-15: per 2-bar chord block, (step, length, midi)
LEAD = [
    [(0, 2, 73), (2, 2, 78), (4, 2, 76), (6, 4, 73), (10, 2, 69), (12, 2, 71), (14, 2, 73),
     (16, 6, 69), (22, 2, 66), (24, 4, 68), (28, 4, 69)],
    [(0, 2, 74), (2, 2, 78), (4, 2, 76), (6, 4, 74), (10, 2, 69), (12, 2, 71), (14, 2, 74),
     (16, 6, 73), (22, 2, 69), (24, 4, 71), (28, 4, 73)],
    [(0, 2, 74), (2, 2, 78), (4, 2, 76), (6, 4, 74), (10, 2, 71), (12, 2, 73), (14, 2, 74),
     (16, 6, 78), (22, 2, 76), (24, 4, 74), (28, 4, 73)],
    [(0, 2, 77), (2, 2, 80), (4, 2, 78), (6, 4, 77), (10, 2, 73), (12, 2, 74), (14, 2, 77),
     (16, 6, 80), (22, 2, 78), (24, 4, 77), (28, 4, 73)],
]

ARP_PAT = [0, 1, 2, 3, 1, 2, 3, 2, 0, 1, 2, 3, 2, 3, 1, 2]
ARP_ACC = [1.0, .55, .7, 1.0, .55, .7, 1.0, .6, 1.0, .55, .7, 1.0, .55, .7, 1.0, .6]


def pos(bar, step):
    return int(round((bar * 16 + step) * STEP))


def lobby_music(seed=4242):
    rng = np.random.default_rng(seed)
    L = int(round(BARS * 16 * STEP))
    drums = np.zeros((L, 2))
    bass = np.zeros(L)
    music = np.zeros((L, 2))          # ducked bus (pad, arp, lead)
    rev_send = np.zeros((L, 2))
    dly_send = np.zeros(L)
    kick_times = []

    kicks = [inst_kick(rng, 1.0), inst_kick(rng, 0.97)]
    snares = [inst_snare(rng) for _ in range(3)]
    hats = [inst_hat(rng, False, 1.0 + 0.03 * k) for k in range(4)]
    ohat = inst_hat(rng, True)
    rim = inst_rim(rng)
    crash = inst_crash(rng)

    def add_drum(sig, idx, gain, p=0.0, send=0.0):
        st = pan(sig, p)
        wrap_add(drums, st, idx, gain)
        if send:
            wrap_add(rev_send, st, idx, gain * send)

    # ---- drums & 808 ------------------------------------------------------
    for bar in range(BARS):
        sec_b = bar >= 8
        chord = CHORDS[(bar // 2) % 4]
        nxt = CHORDS[((bar + 1) // 2) % 4]
        first = bar % 2 == 0
        ksteps = [0, 6, 10] if first else [0, 3, 7, 11, 14]
        if not first and bar in (7, 15):
            ksteps = [0, 3, 7, 10]
        for i, s in enumerate(ksteps):
            idx = pos(bar, s)
            add_drum(kicks[i % 2], idx, 0.85 if s == 0 else 0.7)
            kick_times.append(idx)
            # 808 note lasts until the next kick
            if i + 1 < len(ksteps):
                nstep = ksteps[i + 1] + bar * 16
            else:
                nb = bar + 1
                nstep = nb * 16 + 0
            dur = (nstep - (bar * 16 + s)) * STEP / SR - 0.01
            note = chord[0]
            glide = None
            if not first and i == len(ksteps) - 1:
                if bar in (7, 15):
                    note = chord[0] + 12
                    glide = nxt[0]
                else:
                    note = chord[0] + 12
                    glide = nxt[0]
            if first and s == 6:
                note = chord[0] + 12 if bar % 4 == 2 else chord[0]
            wrap_add(bass, inst_808(rng, note, dur, glide), idx, 0.8)
        # snare / clap on beat 3
        add_drum(snares[bar % 3], pos(bar, 8), 0.8, 0.0, 0.18)
        if sec_b and bar % 2 == 1:
            add_drum(snares[(bar + 1) % 3], pos(bar, 15), 0.25, 0.05, 0.1)
        # hats
        hat_steps = []
        if not sec_b:
            hat_steps = [(s, 1.0 if s % 4 == 0 else 0.65) for s in range(0, 16, 2)]
            if bar % 4 == 1:
                hat_steps += [(13, 0.45), (15, 0.5)]
        else:
            hat_steps = [(s, [1.0, .45, .7, .45][s % 4]) for s in range(16)]
        roll = None
        if bar % 4 == 3:
            # 32nd-note roll over beat 4 (crescendo)
            hat_steps = [hs for hs in hat_steps if hs[0] < 12]
            roll = [(12 + k * 0.5, 0.4 + 0.08 * k) for k in range(8)]
        elif sec_b and bar % 4 == 1:
            # 16th-triplet roll over beat 2
            hat_steps = [hs for hs in hat_steps if not (4 <= hs[0] < 8)]
            roll = [(4 + k * (4 / 6), 0.5 + 0.06 * k) for k in range(6)]
        for s, v in hat_steps + (roll or []):
            idx = int(round((bar * 16 + s) * STEP))
            add_drum(hats[int(s * 2) % 4], idx, 0.42 * v, 0.18)
        if sec_b and bar % 2 == 0:
            add_drum(ohat, pos(bar, 14), 0.24, -0.2, 0.15)
        if sec_b:
            add_drum(rim, pos(bar, 3), 0.28, -0.35, 0.2)
            add_drum(rim, pos(bar, 11), 0.2, -0.35, 0.2)
        # snare roll into the loop start
        if bar == 15:
            for k, s in enumerate([12, 13, 14, 14.5, 15, 15.5]):
                idx = int(round((bar * 16 + s) * STEP))
                add_drum(snares[k % 3], idx, 0.25 + 0.08 * k, 0.0, 0.15)

    for bar in (0, 8):
        add_drum(crash, pos(bar, 0), 0.32, 0.25, 0.25)
    # reverse crash + noise riser into bar 8 and the loop start
    rc = crash[: ns(1.2)][::-1] * np.linspace(0, 1, ns(1.2)) ** 2
    rs = inst_riser(rng, BEAT * 4 / SR)
    for bar in (8, 16):
        idx = pos(bar, 0)
        wrap_add(drums, pan(rc, -0.2), idx - rc.shape[0], 0.22)
        wrap_add(drums, pan(normalize(rs), 0.2), idx - rs.shape[0], 0.07)

    # ---- pad --------------------------------------------------------------
    for blk in range(8):
        root, voicing, pool = CHORDS[blk % 4]
        dur = 32 * STEP / SR
        p = inst_pad(rng, voicing, dur, cutoff=1300 if blk < 4 else 1900)
        wrap_add(music, p, pos(blk * 2, 0), 0.55)
        wrap_add(rev_send, p, pos(blk * 2, 0), 0.25)

    # ---- arp (all bars) -----------------------------------------------------
    for bar in range(BARS):
        pool = CHORDS[(bar // 2) % 4][2]
        lvl = 0.17 if bar < 8 else 0.11
        for s in range(16):
            note = pool[ARP_PAT[s]] + 12
            v = ARP_ACC[s]
            sig = inst_pluck(rng, note, v)
            idx = pos(bar, s)
            p = -0.35 if s % 2 == 0 else 0.35
            wrap_add(music, pan(sig, p), idx, lvl)
            wrap_add(rev_send, pan(sig, p), idx, lvl * 0.4)
            dly_send[:] += 0
            wrap_add(dly_send, sig, idx, lvl * 0.35)

    # ---- lead (bars 8-15) -------------------------------------------------
    for blk in range(4):
        for s, ln, m in LEAD[blk]:
            idx = pos(8 + blk * 2, s)
            dur = ln * STEP / SR * 0.92
            sig = inst_lead(rng, m, dur)
            wrap_add(music, pan(sig, 0.0), idx, 0.3)
            wrap_add(rev_send, pan(sig, 0.0), idx, 0.12)
            wrap_add(dly_send, sig, idx, 0.12)

    # ---- sidechain ducking ------------------------------------------------
    imp = np.zeros(L)
    for k in kick_times:
        imp[k % L] = 1.0
    kern_n = ns(0.4)
    tk = tvec(kern_n)
    kern = np.clip(tk / 0.004, 0, 1) * np.exp(-tk / 0.11)
    duck_env = np.clip(circ_conv(imp, np.concatenate([kern, np.zeros(L - kern_n)])[:kern_n]), 0, 1)
    duck = 1 - 0.55 * duck_env
    music *= duck[:, None]

    # ---- delay (ping-pong dotted 8th) & reverb ------------------------------
    dly = np.zeros((L, 2))
    d = int(round(BEAT * 0.75))
    src = lp_circular(hp_circular(dly_send, 300), 4500)
    for k in range(1, 7):
        dly[:, (k - 1) % 2] += (0.45 ** (k - 1)) * np.roll(src, k * d)
    dly *= duck[:, None]
    irL = make_ir(1.9, np.random.default_rng(seed + 1), predelay=0.02, hf_ratio=0.4, buildup=0.02)
    irR = make_ir(1.9, np.random.default_rng(seed + 2), predelay=0.023, hf_ratio=0.4, buildup=0.02)
    rs_in = hp_circular(rev_send, 250)
    rev = np.stack([circ_conv(rs_in[:, 0], irL), circ_conv(rs_in[:, 1], irR)], axis=1)

    bass_st = np.stack([bass, bass], axis=1)
    if os.environ.get("DEBUG_STEMS"):
        for nm, b in [("drums", BUS["drums"] * drums), ("bass", BUS["bass"] * bass_st),
                      ("music", BUS["music"] * music), ("delay", BUS["delay"] * dly),
                      ("reverb", BUS["reverb"] * rev)]:
            print(f"    stem {nm:7s} rms {20 * np.log10(np.sqrt(np.mean(b ** 2)) + 1e-12):6.1f} dB "
                  f"peak {20 * np.log10(np.max(np.abs(b)) + 1e-12):6.1f} dB")
    mix = (BUS["drums"] * drums + BUS["bass"] * bass_st + BUS["music"] * music
           + BUS["delay"] * dly + BUS["reverb"] * rev)
    mix = hp_circular(mix, 28, 2)
    mix = circular(shelf, mix, 70, -3.0, "low")
    mix = circular(shelf, mix, 4000, 4.0, "high")
    # master: gentle saturation-limiting
    mix = mix / np.max(np.abs(mix)) * 1.35
    mix = np.tanh(mix) / np.tanh(1.35)
    mix = mix - mix.mean(axis=0)
    return normalize(mix, PEAK)


# ----------------------------------------------------------------------------
# stingers (mono)
# ----------------------------------------------------------------------------
def inst_brass(rng, note, dur, vel=1.0):
    n = ns(dur + 0.7)
    t = tvec(n)
    vib = 0.004 * np.sin(2 * np.pi * 5.4 * t) * np.clip((t - 0.25) / 0.3, 0, 1)
    f = mtof(note) * 2 ** (-30 * np.exp(-t / 0.03) / 1200) * (1 + vib)
    osc = supersaw(f, n, voices=5, detune_cents=9, rng=rng)
    cut = 350 + 3800 * vel * (1 - np.exp(-t / 0.045)) * (0.55 + 0.45 * np.exp(-t / 0.3))
    y = svf(osc, cut, 0.9, "lp", poles=4)
    y += 0.08 * bp(white(n, rng), 800, 3000) * env_ad(n, 0.01, 0.05)
    return y * env_adsr(n, 0.018, 0.18, 0.78, 0.28, dur) * vel


def victory_sting():
    rng = np.random.default_rng(777)
    n = ns(3.8)
    out = np.zeros(n)
    for i, m in enumerate([67, 72, 76, 79, 84, 88]):
        place(out, inst_pluck(rng, m, 1.0, 0.14), 0.0 + i * 0.055, 0.42 + 0.06 * i)
    for st, chord, dur in [(0.36, [56, 60, 63, 68, 72], 0.16), (0.56, [58, 62, 65, 70, 74], 0.16),
                           (0.76, [48, 60, 64, 67, 72, 76], 1.55)]:
        for m in chord:
            place(out, inst_brass(rng, m, dur, 1.0 if st > 0.7 else 0.85), st, 0.2)
    for k in range(15):
        st = 0.82 + k * 0.095
        m = [84, 88, 91, 96][k % 4]
        place(out, inst_pluck(rng, m, 0.85, 0.1), st, 0.16 * np.exp(-k / 9))
    kick = inst_kick(rng)
    snare = inst_snare(rng)
    for st in (0.36, 0.56):
        place(out, kick, st, 0.5)
        place(out, snare, st, 0.35)
    for k, st in enumerate([0.66, 0.6925, 0.725]):
        place(out, snare, st, 0.15 + 0.06 * k)
    place(out, kick, 0.76, 0.8)
    place(out, sat(sine(ramp_exp(ns(1.2), 110, 55, 0.08), ns(1.2)) * env_ad(ns(1.2), 0.002, 0.35), 1.5), 0.76, 0.45)
    place(out, inst_crash(rng, 2.6), 0.76, 0.3)
    out = reverb(out, make_ir(1.6, rng, predelay=0.02, hf_ratio=0.45, buildup=0.02), wet=0.28)
    return finalize(out, max_len=3.05, fout=0.7, fin=0.002)


def victory_sting_check():
    return victory_sting()


def defeat_sting():
    rng = np.random.default_rng(666)
    n = ns(3.8)
    out = np.zeros(n)
    m = ns(2.0)
    boom = sine(ramp_exp(m, 80, 38, 0.4), m) * env_ad(m, 0.003, 0.45)
    place(out, sat(boom, 2.0), 0.0, 0.5)
    place(out, lp(white(m, rng), 300, 4) * env_ad(m, 0.003, 0.3), 0.0, 0.08)
    for i, (mn, st) in enumerate([(79, 0.0), (75, 0.32), (72, 0.64), (67, 0.96)]):
        k = ns(0.75)
        t = tvec(k)
        bend = 2 ** (-35 * np.clip((t - 0.2) / 0.15, 0, 1) / 1200)
        f = mtof(mn) * bend
        v = 0.6 * square(f, k, 0.5, rng.random()) + 0.4 * triangle(f, k)
        v = svf(v, 900 + 1800 * np.exp(-t / 0.15), 0.9, "lp")
        v *= env_adsr(k, 0.006, 0.15, 0.6, 0.18, 0.3 if i < 3 else 0.5)
        place(out, v, st, 0.32)
    for st, chord, dur, droop in [(0.0, [56, 60, 63], 0.62, 0.0), (0.64, [53, 56, 60], 0.62, 0.0),
                                  (1.28, [48, 51, 55, 60], 1.25, 1.0)]:
        k = ns(dur + 0.9)
        t = tvec(k)
        for mn in chord:
            f = mtof(mn) * 2 ** (-45 * droop * np.clip((t - 0.2) / 1.6, 0, 1) / 1200)
            v = supersaw(f, k, voices=4, detune_cents=11, rng=rng)
            cut = 1800 * np.exp(-t / (1.4 if droop else 3.0)) + 300
            v = svf(v, cut, 0.8, "lp", poles=4) * env_adsr(k, 0.08, 0.5, 0.8, 0.5, dur)
            place(out, v, st, 0.12)
    k = ns(2.0)
    t = tvec(k)
    sub = sat(sine(mtof(36) * 2 ** (-45 * np.clip((t - 0.2) / 1.6, 0, 1) / 1200), k), 1.8)
    place(out, lp(sub * env_ad(k, 0.01, 0.8), 800), 1.28, 0.35)
    out = reverb(out, make_ir(1.8, rng, predelay=0.025, hf_ratio=0.35, buildup=0.03), wet=0.3)
    return finalize(out, max_len=3.05, fout=0.9, fin=0.002)


# ----------------------------------------------------------------------------
# match ambience (mono loop)
# ----------------------------------------------------------------------------
def match_ambience(seed=99):
    rng = np.random.default_rng(seed)
    L = ns(20.0)
    t = tvec(L)

    def gust(cut, lo, hi):
        g = periodic_smooth(L, rng, cut)
        g = 1 / (1 + np.exp(-1.6 * g))
        return lo + (hi - lo) * g

    g1, g2, g3 = gust(0.12, 0.35, 1.0), gust(0.2, 0.2, 1.0), gust(0.25, 0.0, 1.0)
    low = lp_circular(colored(L, rng, 2.0), 260, 2) * g1
    mid_fc = 380 + 650 * g2
    mid = svf_circular(colored(L, rng, 1.0), mid_fc, 2.2, "bp") * g2 ** 1.3
    whistle_fc = 900 + 500 * g3
    whistle = svf_circular(white(L, rng), whistle_fc, 14.0, "bp") * g3 ** 2.5
    hiss = hp_circular(white(L, rng), 3500, 2) * (0.3 + 0.7 * g2)
    leaves = bp_circular(white(L, rng), 2500, 8000) * (gust(0.6, 0.0, 1.0) ** 3) * g2

    amb = (0.5 * normalize(low) + 0.55 * normalize(mid) + 0.12 * normalize(whistle)
           + 0.05 * normalize(hiss) + 0.07 * normalize(leaves))
    # faint distant industrial hum with slow beating
    hum = (np.sin(2 * np.pi * 55 * t) + 0.5 * np.sin(2 * np.pi * 110.25 * t)
           + 0.25 * np.sin(2 * np.pi * 165.15 * t)) * (0.7 + 0.3 * np.sin(2 * np.pi * t / 10.0))
    amb += 0.025 * hum
    # a few distant bird chirps (circularly placed, reverbed)
    birds = np.zeros(L)
    for st in (3.1, 3.35, 9.7, 14.2, 14.42, 14.6):
        k = ns(0.18)
        tk = tvec(k)
        f = 3200 + 900 * np.sin(np.pi * tk / 0.18) + rng.uniform(-200, 200)
        c = sine(f, k) * np.sin(np.pi * tk / 0.18) ** 2 * (1 + 0.5 * np.sin(2 * np.pi * 40 * tk))
        wrap_add(birds, c, ns(st), rng.uniform(0.6, 1.0))
    ir = make_ir(1.2, rng, predelay=0.03, hf_ratio=0.3, buildup=0.05)
    birds = lp_circular(circ_conv(birds, ir) * 0.8 + 0.2 * birds, 4500)
    amb += 0.03 * normalize(birds)
    amb = hp_circular(amb, 30, 2)
    amb = amb - amb.mean()
    return normalize(amb, PEAK)


def build(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    entries = []

    x = victory_sting()
    write_wav(os.path.join(out_dir, "victory_sting.wav"), x)
    entries.append({"name": "victory_sting.wav", "duration": round(x.shape[0] / SR, 3), "channels": 1,
                    "loop": False, "description": "Victory stinger: rising arp into Ab-Bb-C synth-brass "
                    "cadence with drums, crash and sparkle arp (~3 s)."})
    x = defeat_sting()
    write_wav(os.path.join(out_dir, "defeat_sting.wav"), x)
    entries.append({"name": "defeat_sting.wav", "duration": round(x.shape[0] / SR, 3), "channels": 1,
                    "loop": False, "description": "Defeat stinger: low boom, descending G-Eb-C-G lead over "
                    "Ab-Fm-Cm pads drooping in pitch (~3 s)."})
    x = match_ambience()
    write_wav(os.path.join(out_dir, "match_ambience.wav"), x)
    entries.append({"name": "match_ambience.wav", "duration": round(x.shape[0] / SR, 3), "channels": 1,
                    "loop": True, "loop_start": 0, "loop_end_samples": int(x.shape[0]),
                    "description": "Subtle gusting wind bed with faint distant hum and birds; "
                    "seamless 20 s loop (loop whole file)."})
    x = lobby_music()
    write_wav(os.path.join(out_dir, "lobby_music.wav"), x)
    entries.append({"name": "lobby_music.wav", "duration": round(x.shape[0] / SR, 3), "channels": 2,
                    "loop": True, "loop_start": 0, "loop_end_samples": int(x.shape[0]),
                    "bpm": BPM, "bars": BARS, "key": "F# minor",
                    "description": "Energetic trap-style lobby loop, 140 BPM, 16 bars (F#m-D-Bm-C#): "
                    "808 + kick, clap, rolling hats, supersaw pad, pluck arp, lead hook in 2nd half; "
                    "rendered circularly so it loops seamlessly (loop whole file)."})
    try:
        import soundfile as sf
        ogg = os.path.join(out_dir, "lobby_music.ogg")
        # Vorbis quality 0.4 (= 1 - compression_level; libsndfile's default, ~128 kbps) reproduces the
        # shipped lobby_music.ogg. The 0.2 passed before was evidently ignored where that file was made;
        # honoured (soundfile 0.14), it doubles the file (~256 kbps).
        sf.write(ogg, x, SR, format="OGG", subtype="VORBIS", compression_level=0.6)
        entries.append({"name": "lobby_music.ogg", "duration": round(x.shape[0] / SR, 3), "channels": 2,
                        "loop": True, "description": "Ogg Vorbis copy of lobby_music.wav (smaller; "
                        "same loop)."})
    except Exception as e:  # pragma: no cover
        print("ogg export skipped:", e)
    for e in entries:
        print(f"  {e['name']:20s} {e['duration']:7.3f}s")
    return entries


if __name__ == "__main__":
    import sys
    build(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "_work", "audio"))
