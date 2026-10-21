"""cocotb test of isp_stats against its model (ip/video/isp_stats/model/isp_stats_model.py, stats).

test_stats_exact: frames of random size (one pixel up) on the observed stream (tvalid / tready random; only
handshakes count), the saturation threshold changed between frames (0, the maximum and random values), frames
closed by the next frame's first pixel or by flush_i (also a flush with no frame open, which reports nothing).
At every frame_done_o pulse the sums, PIXELS, CLIPPED and FRAMES equal the model's for the frame it closed; the
outputs hold between reports. Environment: STATS_CASE, STATS_FRAMES (default 150), STATS_SEED."""
from __future__ import annotations

import collections
import os
import random
import sys
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

IP = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(IP.parents[1] / "shared" / "tb" / "python"))
from cocotb_lib import model_path                                # noqa: E402

model_path(IP / "model")
import isp_stats_model as sm                                     # noqa: E402

CASES = {"cw8": dict(CW=8), "cw10": dict(CW=10)}
CASE = os.environ.get("STATS_CASE", "cw8")
CW = CASES[CASE]["CW"]
FRAMES = int(os.environ.get("STATS_FRAMES", "150"))
SEED = int(os.environ.get("STATS_SEED", "20261021"))
COV = collections.Counter()


@cocotb.test()
async def test_stats_exact(dut):
    """Every report equals the model's totals of the frame it closes."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    nrng = np.random.default_rng(SEED)
    top = (1 << CW) - 1
    dut.rst_n.value = 0
    for s in ("tdata", "tuser", "tvalid", "tready", "flush_i", "sat_thr_i"):
        getattr(dut, s).value = 0
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    pending = []                                                  # reports expected: (model totals, frames)
    frames = 0
    seen = {"last": None}                                         # the outputs at the last sample

    async def tick(**sig):
        for k, v in sig.items():
            getattr(dut, k).value = v
        await Timer(1, unit="ns")
        r = (int(dut.sum_r_o.value), int(dut.sum_g_o.value), int(dut.sum_b_o.value), int(dut.pixels_o.value),
             int(dut.clipped_o.value), int(dut.frames_o.value))
        if int(dut.frame_done_o.value):
            assert pending, f"frame_done_o with no frame closed (outputs {r})"
            e = pending.pop(0)
            assert r == e, f"report {e[5]}: rtl {r} model {e}"
            COV["reports"] += 1
        elif seen["last"] is not None:
            assert r == seen["last"], f"outputs changed without frame_done_o: {seen['last']} -> {r}"
        seen["last"] = r
        await FallingEdge(dut.clk)

    open_frame = None                                             # (pixels, threshold) of the frame being counted
    for f in range(FRAMES):
        thr = rng.choice([0, top, rng.randrange(top + 1)])
        h, w = rng.choice([(1, 1), (rng.randrange(1, 8), rng.randrange(1, 30))])
        rgb = nrng.integers(0, top + 1, (h, w, 3))
        rgb[nrng.random((h, w)) < 0.1] = top
        px = rgb.reshape(-1, 3)
        dut.sat_thr_i.value = thr
        k = 0
        while k < len(px):
            v, rd = int(rng.random() < 0.8), int(rng.random() < 0.8)
            p = px[k]
            sof = int(k == 0)
            if v and rd and sof and open_frame is not None:       # this pixel closes the open frame
                frames += 1
                st = sm.stats(open_frame[0], open_frame[1])
                pending.append((st["r"], st["g"], st["b"], st["pix"], st["clip"], frames))
                COV["closed_by_sof"] += 1
            await tick(tdata=int(p[0]) | int(p[1]) << CW | int(p[2]) << (2 * CW), tuser=sof, tvalid=v,
                              tready=rd, flush_i=0)
            if v and rd:
                k += 1
        open_frame = (rgb, thr)
        await tick(tvalid=0, tuser=0)
        x = rng.random()
        if x < 0.25:                                              # flush: the frame is reported now
            frames += 1
            st = sm.stats(rgb, thr)
            pending.append((st["r"], st["g"], st["b"], st["pix"], st["clip"], frames))
            await tick(flush_i=1)
            await tick(flush_i=0)
            open_frame = None
            COV["closed_by_flush"] += 1
            if rng.random() < 0.3:                                # a flush with nothing open: no report
                await tick(flush_i=1)
                await tick(flush_i=0)
                COV["idle_flush"] += 1
        for _ in range(rng.randrange(0, 3)):
            await tick()
        dut.sat_thr_i.value = open_frame[1] if open_frame else thr  # the open frame's clip test keeps its value
    for _ in range(3):
        await tick()
    assert not pending, f"{len(pending)} reports missing"
    dut._log.info("%s: %d frames, coverage %s", CASE, FRAMES, dict(COV))
    for k in ("reports", "closed_by_sof", "closed_by_flush", "idle_flush"):
        assert COV[k], f"not covered: {k}"
