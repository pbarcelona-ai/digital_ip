"""cocotb tests of isp_window against its model (ip/video/isp_window/model/isp_window_model.py).

test_windows_exact: frames of random pixels and random sizes (the minimum R + 1, up to MAX_W wide), with
random input gaps and random output back-pressure; the size changes while the scan waits at (0, 0)
(sof_wait_o). Resync: beats without tuser before a frame start (dropped) and short frames cut by the next
frame's start-of-frame beat (restart). Every output beat (window data, m_x, m_y, tlast, tuser) equals the
model's, in order, and nothing else is output.
Environment: ISPW_CASE (the parameter set the runner built), ISPW_FRAMES (default 30), ISPW_SEED."""
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

model_path(IP / "model")
import isp_window_model as wm                                    # noqa: E402

CASES = {"n3c": dict(N=3, PW=10, MAX_W=64, BORDER=0),
         "n3m": dict(N=3, PW=10, MAX_W=64, BORDER=1),
         "n5c": dict(N=5, PW=8, MAX_W=64, BORDER=0),
         "n5m": dict(N=5, PW=8, MAX_W=64, BORDER=1)}
CASE = os.environ.get("ISPW_CASE", "n3c")
P = CASES[CASE]
FRAMES = int(os.environ.get("ISPW_FRAMES", "30"))
SEED = int(os.environ.get("ISPW_SEED", "20261021"))
COV = collections.Counter()


def segments(rng, n, pw, max_w):
    """The input as segments: (width, height, beats [(data, tuser, tlast)], set_size)."""
    r = n // 2
    segs = []
    w, h = max_w, r + 1
    for f in range(FRAMES):
        set_size = f == 0 or rng.random() < 0.5
        if set_size and f:
            w = rng.choice([r + 1, max_w, rng.randrange(r + 1, max_w + 1), rng.randrange(r + 1, 17)])
            h = rng.choice([r + 1, rng.randrange(r + 1, 9), rng.randrange(r + 1, 17)])
        beats = [(rng.getrandbits(pw), 0, rng.getrandbits(1)) for _ in range(rng.choice([0, 0, 0, 1, 3]))]
        COV["dropped"] += len(beats)
        npx = w * h
        if rng.random() < 0.15 and npx > 1:                       # a short frame: the next frame restarts it
            npx = rng.randrange(1, npx)
            COV["short"] += 1
        beats += [(rng.getrandbits(pw), int(i == 0), int(i % w == w - 1)) for i in range(npx)]
        segs.append((w, h, beats, set_size))
        if npx < w * h:                                           # same size for the frame that cuts it
            segs.append((w, h, [(rng.getrandbits(pw), int(i == 0), int(i % w == w - 1)) for i in range(w * h)],
                         False))
        COV[f"w{'min' if w == r + 1 else 'max' if w == max_w else 'mid'}"] += 1
        COV[f"h{'min' if h == r + 1 else 'mid'}"] += 1
    return segs


@cocotb.test()
async def test_windows_exact(dut):
    """Random frames, sizes, gaps, back-pressure and resyncs: every window equals the model's."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    n, pw, max_w = P["N"], P["PW"], P["MAX_W"]
    rng = random.Random(SEED)
    segs = segments(rng, n, pw, max_w)
    m = wm.IspWindow(n, P["BORDER"])
    exp = []
    for w, h, beats, _ in segs:
        for d, u, _ in beats:
            exp += m.push(d, u, w, h)
    exp += m.flush(segs[-1][0], segs[-1][1])
    dut.rst_n.value = 0
    for s in ("s_tvalid", "s_tdata", "s_tuser", "s_tlast", "m_tready"):
        getattr(dut, s).value = 0
    dut.width_i.value, dut.height_i.value = segs[0][0], segs[0][1]
    for _ in range(4):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    flat = [(si, b) for si, (_, _, beats, _) in enumerate(segs) for b in beats]
    k = got = 0
    sized = 0                                                     # segments whose size is applied
    gap, bp = 0.3, 0.3
    for _ in range(40 * (len(flat) + len(exp)) + 2000):
        await FallingEdge(dut.clk)
        if rng.random() < 0.01:
            gap, bp = rng.choice([0.0, 0.3, 0.7]), rng.choice([0.0, 0.3, 0.7])
        dut.m_tready.value = int(rng.random() >= bp)
        valid = 0
        if k < len(flat):
            si, (d, u, last) = flat[k]
            if si >= sized and not segs[si][3]:
                sized = si + 1
            if si < sized:
                dut.s_tdata.value, dut.s_tuser.value, dut.s_tlast.value = d, u, last
                valid = int(rng.random() >= gap)
        dut.s_tvalid.value = valid
        await Timer(1, unit="ns")
        if valid and dut.s_tready.value:
            k += 1
        if k < len(flat) and flat[k][0] >= sized and segs[flat[k][0]][3] and dut.sof_wait_o.value:
            si = flat[k][0]                                       # a new size while the scan waits at (0, 0)
            dut.width_i.value, dut.height_i.value = segs[si][0], segs[si][1]
            sized = si + 1
        if dut.m_tvalid.value and dut.m_tready.value:
            assert got < len(exp), f"extra window: x {int(dut.m_x.value)} y {int(dut.m_y.value)}"
            e = exp[got]
            rtl = (int(dut.m_tdata.value), int(dut.m_x.value), int(dut.m_y.value), int(dut.m_tlast.value),
                   int(dut.m_tuser.value))
            ref = (wm.pack(e["win"], pw), e["x"], e["y"], e["last"], e["user"])
            if rtl != ref:
                raise AssertionError(f"window {got}: rtl x {rtl[1]} y {rtl[2]} last {rtl[3]} user {rtl[4]} "
                                     f"data {rtl[0]:#x}; model x {ref[1]} y {ref[2]} last {ref[3]} user "
                                     f"{ref[4]} data {ref[0]:#x}")
            got += 1
            COV["backpressure"] += int(bp > 0)
        if k == len(flat) and got == len(exp):
            break
    dut.s_tvalid.value = 0
    assert k == len(flat) and got == len(exp), f"beats {k} of {len(flat)} taken, windows {got} of {len(exp)}"
    for _ in range(20):                                           # nothing more comes out
        await FallingEdge(dut.clk)
        await Timer(1, unit="ns")
        assert not dut.m_tvalid.value, "window after the last frame"
    dut._log.info("%s: %d beats, %d windows compared, coverage %s", CASE, len(flat), len(exp), dict(COV))
    if FRAMES >= 20:
        for c in ("dropped", "short", "wmin", "wmax", "hmin", "backpressure"):
            assert COV[c], f"not covered: {c}"
