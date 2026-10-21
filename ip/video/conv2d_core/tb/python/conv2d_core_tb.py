"""cocotb tests of conv2d_core against its model (ip/video/conv2d_core/model/conv2d_core_model.py, Conv2dCore).

test_conv_exact: frames of random pixels and sizes (the minimum R + 1 up to MAX_W wide) with random input gaps
and output back-pressure; between complete frames, while the scan waits at (0, 0) (sof_wait_o) and once the
frames before have taken their kernel (frame_o; a 2 x 2 frame of N = 3 can still be in flight), a new kernel
and shift (identity, binomial blur, unsharp mask, random full-range, all coefficients at the positive or
negative limit; shift 0..31) and sometimes a new size. Resync: beats without tuser before a frame start and
short frames cut by the next start of frame. Every output beat (data, tlast, tuser) equals the model's, in
order; frame_o pulses once per frame whose first window is formed.
Environment: C2D_CASE (the parameter set the runner built), C2D_FRAMES (default 24), C2D_SEED."""
from __future__ import annotations

import collections
import os
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

IP = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(IP.parents[1] / "shared" / "tb" / "python"))
from cocotb_lib import model_path                                # noqa: E402

model_path(IP / "model", IP.parent / "isp_window" / "model")
import conv2d_core_model as cm                                   # noqa: E402

CASES = {"n5c": dict(N=5, C=3, CW=8, COEF_W=12, MAX_W=64, BORDER=0),
         "n5m": dict(N=5, C=3, CW=8, COEF_W=12, MAX_W=64, BORDER=1),
         "n3w": dict(N=3, C=1, CW=10, COEF_W=10, MAX_W=48, BORDER=0)}
CASE = os.environ.get("C2D_CASE", "n5c")
P = CASES[CASE]
FRAMES = int(os.environ.get("C2D_FRAMES", "24"))
SEED = int(os.environ.get("C2D_SEED", "20261021"))
COV = collections.Counter()


def binom(n):
    row = [1, 2, 1] if n == 3 else [1, 4, 6, 4, 1]
    return [a * b for a in row for b in row]


KINDS = ["id", "blur", "sharp", "rand", "max", "min"]


def kernel(rng, n, coef_w, f):
    """(kernel, shift) for frame f: every kind once first, then random kinds."""
    lo, hi = -(1 << (coef_w - 1)), (1 << (coef_w - 1)) - 1
    one, b = 1 << (2 * (n - 1)), binom(n)
    kind = KINDS[f] if f < len(KINDS) else rng.choice(KINDS + ["rand"])
    if kind == "id":
        k, s = [int(i == n * n // 2) for i in range(n * n)], 0
    elif kind == "blur":
        k, s = b, 2 * (n - 1)
    elif kind == "sharp":
        a = rng.randrange(1, 3)
        k, s = [((1 + a) * one if i == n * n // 2 else 0) - a * b[i] for i in range(n * n)], 2 * (n - 1)
    elif kind == "rand":
        k, s = [rng.randrange(lo, hi + 1) for _ in range(n * n)], rng.randrange(0, 18)
    else:
        k, s = [hi if kind == "max" else lo] * (n * n), rng.choice([0, 1, 8, 12, 16, 20, 24, 25, 26, 27, 30, 31])
    if rng.random() < 0.15 or f == len(KINDS):
        s = rng.randrange(24, 32) if f == len(KINDS) else rng.randrange(32)
    COV[f"k_{kind}"] += 1
    COV["shift_big"] += int(s >= 24)
    return k, s


def pack_k(k, coef_w):
    v = 0
    for i, c in enumerate(k):
        v |= (c & ((1 << coef_w) - 1)) << (i * coef_w)
    return v


def segments(rng):
    """The input as segments: (width, height, kernel, shift, beats [(data, tuser, tlast)], set_cfg)."""
    n, pw, max_w, r = P["N"], P["C"] * P["CW"], P["MAX_W"], P["N"] // 2
    segs = []
    w, h = max_w, r + 1
    for f in range(FRAMES):
        if f and rng.random() < 0.5:
            w = rng.choice([r + 1, max_w, rng.randrange(r + 1, max_w + 1), rng.randrange(r + 1, 17)])
            h = rng.choice([r + 1, rng.randrange(r + 1, 9), rng.randrange(r + 1, 17)])
        k, s = kernel(rng, n, P["COEF_W"], f)
        beats = [(rng.getrandbits(pw), 0, 0) for _ in range(rng.choice([0, 0, 0, 1, 3]))]
        COV["dropped"] += len(beats)
        npx = w * h
        if rng.random() < 0.15:
            npx = rng.randrange(1, npx)
            COV["short"] += 1
        beats += [(rng.getrandbits(pw), int(i == 0), int(i % w == w - 1)) for i in range(npx)]
        segs.append((w, h, k, s, beats, True))
        if npx < w * h:
            segs.append((w, h, k, s, [(rng.getrandbits(pw), int(i == 0), int(i % w == w - 1))
                                      for i in range(w * h)], False))
        COV[f"w{'min' if w == r + 1 else 'max' if w == max_w else 'mid'}"] += 1
        COV[f"h{'min' if h == r + 1 else 'mid'}"] += 1
    return segs


@cocotb.test()
async def test_conv_exact(dut):
    """Random frames, kernels, shifts, sizes, gaps, back-pressure and resyncs: every output equals the model's."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    segs = segments(rng)
    m = cm.Conv2dCore(P["N"], P["C"], P["CW"], P["BORDER"])
    exp = []
    taken = []                                                    # first windows before each segment
    for w, h, k, s, beats, _ in segs:
        taken.append(sum(e[2] for e in exp))
        for d, u, _ in beats:
            exp += m.push(d, u, w, h, k, s)
    exp += m.flush(segs[-1][0], segs[-1][1], segs[-1][2], segs[-1][3])
    n_frames = sum(e[2] for e in exp)
    dut.rst_n.value = 0
    for sig in ("s_tvalid", "s_tdata", "s_tuser", "s_tlast", "m_tready"):
        getattr(dut, sig).value = 0
    dut.width_i.value, dut.height_i.value = segs[0][0], segs[0][1]
    for _ in range(4):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    flat = [(si, b) for si, seg in enumerate(segs) for b in seg[4]]
    k = got = frames = 0
    sized = 0                                                     # segments whose configuration is applied
    gap, bp = 0.3, 0.3
    for _ in range(40 * (len(flat) + len(exp)) + 4000):
        await FallingEdge(dut.clk)
        if rng.random() < 0.01:
            gap, bp = rng.choice([0.0, 0.3, 0.7]), rng.choice([0.0, 0.3, 0.7])
        dut.m_tready.value = int(rng.random() >= bp)
        valid = 0
        if k < len(flat):
            si, (d, u, last) = flat[k]
            if si >= sized and not segs[si][5]:
                sized = si + 1
            if si < sized:
                dut.s_tdata.value, dut.s_tuser.value, dut.s_tlast.value = d, u, last
                valid = int(rng.random() >= gap)
        dut.s_tvalid.value = valid
        await Timer(1, unit="ns")
        if valid and dut.s_tready.value:
            k += 1
        if dut.m_tvalid.value and dut.m_tready.value:
            assert got < len(exp), "output beat after the model's last"
            rtl = (int(dut.m_tdata.value), int(dut.m_tlast.value), int(dut.m_tuser.value))
            if rtl != exp[got]:
                raise AssertionError(f"beat {got}: rtl data {rtl[0]:#x} last {rtl[1]} user {rtl[2]}; model data "
                                     f"{exp[got][0]:#x} last {exp[got][1]} user {exp[got][2]}")
            got += 1
            COV["backpressure"] += int(bp > 0)
        if (k < len(flat) and flat[k][0] >= sized and segs[flat[k][0]][5] and dut.sof_wait_o.value
                and frames == taken[flat[k][0]]):
            si = flat[k][0]                       # the next frame's configuration: scan at (0, 0), kernels taken
            w, h, kk, s = segs[si][:4]
            dut.width_i.value, dut.height_i.value = w, h
            dut.coef_i.value, dut.shift_i.value = pack_k(kk, P["COEF_W"]), s
            sized = si + 1
        frames += int(dut.frame_o.value)                          # a take at the coming edge (after the check)
        if k == len(flat) and got == len(exp):
            break
    dut.s_tvalid.value = 0
    assert k == len(flat) and got == len(exp), f"beats {k} of {len(flat)} taken, outputs {got} of {len(exp)}"
    for _ in range(20):
        await FallingEdge(dut.clk)
        await Timer(1, unit="ns")
        assert not dut.m_tvalid.value, "output after the last frame"
    assert frames == n_frames, f"frame_o {frames} pulses, {n_frames} frames"
    dut._log.info("%s: %d beats, %d outputs compared, coverage %s", CASE, len(flat), len(exp), dict(COV))
    if FRAMES >= 20:
        for c in ("dropped", "short", "wmin", "wmax", "hmin", "backpressure", "k_rand", "k_max", "k_min",
                  "shift_big"):
            assert COV[c], f"not covered: {c}"
