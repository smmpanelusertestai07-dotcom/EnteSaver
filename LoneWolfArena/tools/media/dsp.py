"""Shared DSP helpers for procedural SFX / music synthesis.

Everything works on float64 numpy arrays at 44.1 kHz.  Mono signals are 1-D,
stereo signals are shape (n, 2).
"""
from __future__ import annotations

import numpy as np
import soundfile as sf
from numba import njit
from scipy import signal

SR = 44100
PEAK_DB = -1.0
PEAK = 10 ** (PEAK_DB / 20)


# ----------------------------------------------------------------------------
# basics
# ----------------------------------------------------------------------------
def ns(sec: float) -> int:
    return int(round(sec * SR))


def tvec(n: int) -> np.ndarray:
    return np.arange(n) / SR


def mtof(m):
    return 440.0 * 2.0 ** ((np.asarray(m, dtype=float) - 69.0) / 12.0)


def db(x):
    return 20 * np.log10(np.maximum(np.abs(x), 1e-12))


def undb(d):
    return 10 ** (np.asarray(d, dtype=float) / 20)


def place(buf, sig, start_sec=0.0, gain=1.0, start_idx=None):
    """Add `sig` into `buf` at time offset (in place, clipped to buffer)."""
    i0 = ns(start_sec) if start_idx is None else start_idx
    if i0 >= buf.shape[0]:
        return buf
    n = min(sig.shape[0], buf.shape[0] - i0)
    buf[i0:i0 + n] += gain * sig[:n]
    return buf


def wrap_add(buf, sig, start_idx, gain=1.0):
    """Circularly add `sig` into loop buffer `buf` (tail wraps to the start)."""
    L = buf.shape[0]
    start = start_idx % L
    n = sig.shape[0]
    i = 0
    while i < n:
        pos = (start + i) % L
        m = min(n - i, L - pos)
        buf[pos:pos + m] += gain * sig[i:i + m]
        i += m
    return buf


def pan(x, p):
    """Constant power pan, p in [-1, 1] -> (n, 2)."""
    th = (p + 1) * np.pi / 4
    return np.stack([x * np.cos(th), x * np.sin(th)], axis=1)


# ----------------------------------------------------------------------------
# noise
# ----------------------------------------------------------------------------
def white(n, rng):
    return rng.standard_normal(n)


def colored(n, rng, exponent=1.0, fmin=10.0):
    """Periodic (circular) noise with 1/f^exponent power spectrum, unit std."""
    k = n // 2 + 1
    spec = rng.standard_normal(k) + 1j * rng.standard_normal(k)
    f = np.fft.rfftfreq(n, 1 / SR)
    f = np.maximum(f, fmin)
    spec *= f ** (-exponent / 2)
    spec[0] = 0
    x = np.fft.irfft(spec, n)
    return x / (np.std(x) + 1e-12)


def periodic_smooth(n, rng, cutoff_hz, exponent=0.0):
    """Smooth periodic random curve (band-limited circular noise), unit std."""
    k = n // 2 + 1
    spec = rng.standard_normal(k) + 1j * rng.standard_normal(k)
    f = np.fft.rfftfreq(n, 1 / SR)
    w = np.exp(-(f / cutoff_hz) ** 2)
    if exponent:
        w *= np.maximum(f, f[1]) ** (-exponent / 2)
    spec *= w
    spec[0] = 0
    x = np.fft.irfft(spec, n)
    return x / (np.std(x) + 1e-12)


# ----------------------------------------------------------------------------
# filters
# ----------------------------------------------------------------------------
def _sos(kind, fc, order):
    return signal.butter(order, fc, btype=kind, fs=SR, output="sos")


def lp(x, fc, order=2):
    return signal.sosfilt(_sos("lowpass", min(fc, 0.45 * SR), order), x, axis=0)


def hp(x, fc, order=2):
    return signal.sosfilt(_sos("highpass", fc, order), x, axis=0)


def bp(x, lo, hi, order=2):
    return signal.sosfilt(_sos("bandpass", [lo, min(hi, 0.45 * SR)], order), x, axis=0)


def reson(x, fc, q):
    """RBJ constant-0dB-peak band-pass (resonator)."""
    w0 = 2 * np.pi * fc / SR
    alpha = np.sin(w0) / (2 * q)
    b = np.array([alpha, 0.0, -alpha])
    a = np.array([1 + alpha, -2 * np.cos(w0), 1 - alpha])
    return signal.lfilter(b / a[0], a / a[0], x, axis=0)


def peq(x, fc, q, gain_db):
    """RBJ peaking EQ."""
    A = 10 ** (gain_db / 40)
    w0 = 2 * np.pi * fc / SR
    alpha = np.sin(w0) / (2 * q)
    b = np.array([1 + alpha * A, -2 * np.cos(w0), 1 - alpha * A])
    a = np.array([1 + alpha / A, -2 * np.cos(w0), 1 - alpha / A])
    return signal.lfilter(b / a[0], a / a[0], x, axis=0)


def shelf(x, fc, gain_db, kind="high", s=1.0):
    A = 10 ** (gain_db / 40)
    w0 = 2 * np.pi * fc / SR
    cw, sw = np.cos(w0), np.sin(w0)
    alpha = sw / 2 * np.sqrt((A + 1 / A) * (1 / s - 1) + 2)
    sq = 2 * np.sqrt(A) * alpha
    if kind == "high":
        b = [A * ((A + 1) + (A - 1) * cw + sq), -2 * A * ((A - 1) + (A + 1) * cw), A * ((A + 1) + (A - 1) * cw - sq)]
        a = [(A + 1) - (A - 1) * cw + sq, 2 * ((A - 1) - (A + 1) * cw), (A + 1) - (A - 1) * cw - sq]
    else:
        b = [A * ((A + 1) - (A - 1) * cw + sq), 2 * A * ((A - 1) - (A + 1) * cw), A * ((A + 1) - (A - 1) * cw - sq)]
        a = [(A + 1) + (A - 1) * cw + sq, -2 * ((A - 1) + (A + 1) * cw), (A + 1) + (A - 1) * cw - sq]
    b, a = np.array(b), np.array(a)
    return signal.lfilter(b / a[0], a / a[0], x, axis=0)


@njit(cache=True)
def _svf(x, fc, q, mode, sr):
    n = x.shape[0]
    y = np.empty(n)
    ic1 = 0.0
    ic2 = 0.0
    for i in range(n):
        g = np.tan(np.pi * fc[i] / sr)
        k = 1.0 / q[i]
        a1 = 1.0 / (1.0 + g * (g + k))
        a2 = g * a1
        a3 = g * a2
        v3 = x[i] - ic2
        v1 = a1 * ic1 + a2 * v3
        v2 = ic2 + a2 * ic1 + a3 * v3
        ic1 = 2.0 * v1 - ic1
        ic2 = 2.0 * v2 - ic2
        if mode == 0:
            y[i] = v2
        elif mode == 1:
            y[i] = v1 * k
        else:
            y[i] = x[i] - k * v1 - v2
    return y


def svf(x, fc, q=0.707, mode="lp", poles=2):
    """Time-varying TPT state-variable filter.  fc/q may be scalars or arrays."""
    x = np.ascontiguousarray(x, dtype=float)
    n = x.shape[0]
    fc = np.clip(np.broadcast_to(np.asarray(fc, dtype=float), (n,)), 5.0, 0.45 * SR).copy()
    q = np.broadcast_to(np.asarray(q, dtype=float), (n,)).copy()
    m = {"lp": 0, "bp": 1, "hp": 2}[mode]
    y = _svf(x, fc, q, m, float(SR))
    for _ in range(poles // 2 - 1):
        y = _svf(y, fc, q, m, float(SR))
    return y


def svf_circular(x, fc, q=0.707, mode="lp", poles=2):
    """SVF applied to a periodic signal so that the output is periodic too."""
    n = x.shape[0]
    fc2 = np.concatenate([np.broadcast_to(fc, (n,)), np.broadcast_to(fc, (n,))])
    q2 = np.concatenate([np.broadcast_to(q, (n,)), np.broadcast_to(q, (n,))])
    y = svf(np.concatenate([x, x]), fc2, q2, mode, poles)
    return y[n:]


def circular(fn, x, *args, **kw):
    """Apply a causal filter to a periodic signal so the result is periodic."""
    n = x.shape[0]
    return fn(np.concatenate([x, x], axis=0), *args, **kw)[n:]


def lp_circular(x, fc, order=2):
    n = x.shape[0]
    return lp(np.concatenate([x, x], axis=0), fc, order)[n:]


def hp_circular(x, fc, order=2):
    n = x.shape[0]
    return hp(np.concatenate([x, x], axis=0), fc, order)[n:]


def bp_circular(x, lo, hi, order=2):
    n = x.shape[0]
    return bp(np.concatenate([x, x], axis=0), lo, hi, order)[n:]


# ----------------------------------------------------------------------------
# oscillators
# ----------------------------------------------------------------------------
def _farr(freq, n):
    return np.broadcast_to(np.asarray(freq, dtype=float), (n,))


def phase_cycles(freq, n, phase0=0.0):
    f = _farr(freq, n)
    return phase0 + np.concatenate([[0.0], np.cumsum(f[:-1])]) / SR


def sine(freq, n, phase0=0.0):
    return np.sin(2 * np.pi * phase_cycles(freq, n, phase0))


def _blep(t, dt):
    y = np.zeros_like(t)
    m = t < dt
    u = t[m] / dt[m]
    y[m] = u + u - u * u - 1.0
    m2 = t > 1.0 - dt
    u = (t[m2] - 1.0) / dt[m2]
    y[m2] = u * u + u + u + 1.0
    return y


def saw(freq, n, phase0=0.0):
    f = _farr(freq, n)
    dt = np.maximum(f / SR, 1e-9)
    ph = phase_cycles(f, n, phase0) % 1.0
    return 2 * ph - 1 - _blep(ph, dt)


def square(freq, n, pw=0.5, phase0=0.0):
    f = _farr(freq, n)
    dt = np.maximum(f / SR, 1e-9)
    ph = phase_cycles(f, n, phase0) % 1.0
    y = np.where(ph < pw, 1.0, -1.0)
    y += _blep(ph, dt)
    y -= _blep((ph - pw) % 1.0, dt)
    return y - (2 * pw - 1)


def triangle(freq, n, phase0=0.0):
    ph = phase_cycles(freq, n, phase0 + 0.25) % 1.0
    return 4 * np.abs(ph - 0.5) - 1


def supersaw(freq, n, voices=7, detune_cents=14.0, rng=None, stereo=False, spread=0.8):
    rng = rng or np.random.default_rng(0)
    offs = np.linspace(-1, 1, voices) * detune_cents
    out = np.zeros((n, 2)) if stereo else np.zeros(n)
    for i, c in enumerate(offs):
        v = saw(_farr(freq, n) * 2 ** (c / 1200), n, rng.random())
        if stereo:
            p = (i / (voices - 1) * 2 - 1) * spread if voices > 1 else 0.0
            out += pan(v, p)
        else:
            out += v
    return out / np.sqrt(voices)


def modal(n, freqs, decays, amps, phases=None):
    """Sum of exponentially decaying sinusoids (modal synthesis)."""
    t = tvec(n)
    y = np.zeros(n)
    for i, (f, d, a) in enumerate(zip(freqs, decays, amps)):
        ph = 0.0 if phases is None else phases[i]
        if f >= 0.45 * SR:
            continue
        y += a * np.sin(2 * np.pi * f * t + ph) * np.exp(-t / d)
    return y


def fm(carrier, ratio, index, n, index_env=None, phase0=0.0):
    """Two-operator FM.  index_env multiplies the modulation index over time."""
    f = _farr(carrier, n)
    mod = sine(f * ratio, n)
    idx = index if index_env is None else index * index_env
    ph = phase_cycles(f, n, phase0)
    return np.sin(2 * np.pi * ph + idx * mod)


# ----------------------------------------------------------------------------
# envelopes
# ----------------------------------------------------------------------------
def env_ad(n, attack, tau, curve=1.0):
    """Linear(ish) attack, exponential decay with time constant tau (seconds)."""
    t = tvec(n)
    a = np.clip(t / max(attack, 1e-6), 0, 1) ** curve
    d = np.exp(-np.maximum(t - attack, 0) / tau)
    return a * d


def env_adsr(n, a, d, s, r, gate):
    t = tvec(n)
    e = np.where(t < a, t / max(a, 1e-6), s + (1 - s) * np.exp(-(t - a) / max(d, 1e-6)))
    rel = t >= gate
    if rel.any():
        g_level = e[min(ns(gate), n - 1)]
        e = np.where(rel, g_level * np.exp(-(t - gate) / max(r, 1e-6)), e)
    return e


def ramp_exp(n, f0, f1, dur):
    """Exponential glide f0 -> f1 over `dur` seconds, then hold."""
    t = tvec(n)
    k = np.clip(t / max(dur, 1e-6), 0, 1)
    return f0 * (f1 / f0) ** k


def sweep_exp(n, f0, f1, tau):
    """Exponential approach f0 -> f1 with time constant tau (pitch envelope)."""
    t = tvec(n)
    return f1 + (f0 - f1) * np.exp(-t / tau)


def fade(x, fin=0.0005, fout=0.01):
    x = np.array(x, dtype=float, copy=True)
    n = x.shape[0]
    a, b = min(ns(fin), n), min(ns(fout), n)
    if a > 1:
        w = 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, a))
        x[:a] = (x[:a].T * w).T
    if b > 1:
        w = 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, b))
        x[n - b:] = (x[n - b:].T * w).T
    return x


# ----------------------------------------------------------------------------
# dynamics / colour
# ----------------------------------------------------------------------------
def normalize(x, peak=1.0):
    m = np.max(np.abs(x))
    return x * (peak / m) if m > 0 else x


def sat(x, drive=2.0):
    """tanh saturation with unity small-signal gain normalisation."""
    return np.tanh(drive * x) / np.tanh(drive)


def softclip(x, threshold=0.8):
    """Transparent below threshold, smooth knee above (keeps |y| < 1)."""
    y = np.array(x, dtype=float, copy=True)
    ax = np.abs(y)
    m = ax > threshold
    over = (ax[m] - threshold) / (1 - threshold)
    y[m] = np.sign(y[m]) * (threshold + (1 - threshold) * np.tanh(over))
    return y


def smear(x, ms=3.0):
    """Short boxcar-ish blur to soften transients (distance)."""
    k = max(1, ns(ms / 1000))
    w = np.hanning(k + 2)[1:-1]
    return signal.fftconvolve(x, w / w.sum(), mode="full")[: x.shape[0]]


# ----------------------------------------------------------------------------
# reverb
# ----------------------------------------------------------------------------
def make_ir(t60, rng, predelay=0.004, length=None, hf_ratio=0.45, lf_ratio=1.0,
            early=None, buildup=0.004, bright=1.0):
    """Synthetic room impulse response: decaying noise, faster HF decay."""
    n = ns(length if length is not None else t60 * 1.1)
    t = tvec(n)
    nz = rng.standard_normal(n)
    low = lp(nz, 700, 2)
    mid = bp(nz, 700, 4000, 2)
    high = hp(nz, 4000, 2) * bright
    k = 6.91
    ir = (low * np.exp(-k * t / (t60 * lf_ratio)) + mid * np.exp(-k * t / (t60 * 0.8))
          + high * np.exp(-k * t / (t60 * hf_ratio)))
    ir *= 1 - np.exp(-t / max(buildup, 1e-4))
    if early:
        for d, g in early:
            i = ns(d)
            if i < n:
                ir[i] += g * np.sign(rng.standard_normal()) * 6.0
    ir = np.concatenate([np.zeros(ns(predelay)), ir])
    ir *= np.exp(-k * np.maximum(tvec(ir.shape[0]) - t60, 0) / 0.05)  # clean end
    ir = fade(ir, 0, 0.02)
    return ir / np.sqrt(np.sum(ir ** 2))


def reverb(x, ir, wet=0.2, dry=1.0):
    """Linear convolution reverb; output is longer than input by len(ir)-1."""
    y = signal.fftconvolve(x, ir, mode="full")
    out = wet * y
    out[: x.shape[0]] += dry * x
    return out


def circ_conv(x, ir):
    """Circular convolution (period len(x)) — keeps loops seamless."""
    n = x.shape[0]
    assert ir.shape[0] < n
    X = np.fft.rfft(x, n)
    H = np.fft.rfft(ir, n)
    return np.fft.irfft(X * H, n)


# ----------------------------------------------------------------------------
# output
# ----------------------------------------------------------------------------
def finalize(x, max_len=None, fin=0.0004, fout=0.03, hp_hz=22.0, trim_db=-62.0,
             peak_db=PEAK_DB):
    """DC/subsonic removal, tail trim, edge fades, peak normalisation."""
    x = np.asarray(x, dtype=float)
    x = hp(x, hp_hz, 2)
    if max_len is not None:
        x = x[: ns(max_len)]
    mono = np.max(np.abs(x), axis=1) if x.ndim == 2 else np.abs(x)
    thr = mono.max() * undb(trim_db)
    idx = np.nonzero(mono > thr)[0]
    end = min(x.shape[0], idx[-1] + ns(0.004)) if idx.size else x.shape[0]
    x = x[:end]
    x = fade(x, fin, min(fout, x.shape[0] / SR * 0.5))
    x = x - _edge_safe_mean(x)
    return normalize(x, undb(peak_db))


def _edge_safe_mean(x):
    """Remove residual DC using a window so that the edges stay at zero."""
    n = x.shape[0]
    w = np.hanning(n)
    if x.ndim == 2:
        m = x.mean(axis=0)
        return np.outer(w / w.mean(), m) if n > 8 else 0.0
    m = x.mean()
    return w / w.mean() * m if n > 8 else 0.0


def to_pcm16(x):
    x = np.asarray(x, dtype=float)
    assert np.all(np.isfinite(x)), "non-finite samples"
    pcm = np.round(x * 32767.0)
    assert np.max(np.abs(pcm)) <= 32767, "clipping"
    return pcm.astype(np.int16)


def write_wav(path, x):
    sf.write(path, to_pcm16(x), SR, subtype="PCM_16")
