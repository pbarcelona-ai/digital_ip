"""cocotb test of isp_dpc against its model (ip/video/isp_dpc/model/isp_dpc_model.py, dpc_frame).

test_frames_exact: RAW frames (smooth noise with injected hot and dead pixels, also at the borders and corners, and
flat frames) back to back with random input gaps and output back-pressure; bypass changes at every frame (taken when
the frame's first output pixel leaves: a frame starts once the earlier frames' output has begun, as a frame of few
lines gives its first output pixel after its last input beat); the frame size (3 x 3 up to MAX_W wide) and the
threshold change between groups of frames with the block empty. Every output beat equals the model's frames, in
order, and corrected_o pulses once per corrected pixel. Environment: DPC_CASE, DPC_FRAMES (default 80), DPC_SEED."""
from __future__ import annotations

import collections
import os
import random
import sys
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge

IP = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(IP.parents[1] / "shared" / "tb" / "python"))
from cocotb_lib import frame_beats, model_path, run_frames      # noqa: E402

model_path(IP / "model")
import isp_dpc_model as dm                                       # noqa: E402

CASES = {"pw10": dict(PW=10, MAX_W=64), "pw8": dict(PW=8, MAX_W=32)}
CASE = os.environ.get("DPC_CASE", "pw10")
P = CASES[CASE]
PW = P["PW"]
FRAMES = int(os.environ.get("DPC_FRAMES", "80"))
SEED = int(os.environ.get("DPC_SEED", "20261021"))
COV = collections.Counter()


@cocotb.test()
async def test_frames_exact(dut):
    """Frames back to back: every output beat and the corrected-pixel pulses equal the model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    nrng = np.random.default_rng(SEED)
    top = (1 << PW) - 1
    dut.rst_n.value = 0
    for s in ("s_tvalid", "s_tdata", "s_tlast", "s_tuser", "m_tready", "bypass_i", "thr_i", "width_i", "height_i"):
        getattr(dut, s).value = 0
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    done = 0
    while done < FRAMES:
        w = rng.choice([3, P["MAX_W"], rng.randrange(3, P["MAX_W"] + 1), rng.randrange(3, 12)])
        h = rng.choice([3, rng.randrange(3, 12)])
        thr = rng.choice([0, rng.randrange(1, 64), top])
        dut.width_i.value, dut.height_i.value, dut.thr_i.value = w, h, thr
        group = []
        for _ in range(rng.randrange(1, 5)):
            if rng.random() < 0.15:
                raw = np.full((h, w), rng.randrange(top + 1))
            else:
                base = rng.randrange(top // 4, 3 * top // 4)
                raw = (base + nrng.integers(-top // 16, top // 16 + 1, (h, w))).clip(0, top)
            for _ in range(rng.randrange(0, 6)):                # hot / dead pixels, borders included
                y, x = rng.choice([0, h - 1, rng.randrange(h)]), rng.choice([0, w - 1, rng.randrange(w)])
                raw[y, x] = rng.choice([0, top])
            group.append((raw, rng.random() < 0.2))
        exp, n_corr = [], 0
        for raw, by in group:
            out, nc = dm.dpc_frame(raw, thr, by)
            exp += frame_beats(out, int)
            n_corr += nc
            COV["bypass"] += by
            COV["hot"] += int((out < raw).sum())
            COV["dead"] += int((out > raw).sum())
        pulses = [0]

        def count(d):
            pulses[0] += int(d.corrected_o.value)
        got = await run_frames(dut, rng, [frame_beats(raw, int) for raw, _ in group],
                               on_frame=lambda f: setattr(dut.bypass_i, "value", group[f][1]), each_clock=count,
                               gap=rng.choice([0.0, 0.3]), bp=rng.choice([0.0, 0.3, 0.6]), after_out_sof=True)
        for _ in range(4):
            await FallingEdge(dut.clk)
            count(dut)
        for k, (g, e) in enumerate(zip(got, exp)):
            assert g == e, f"group at frame {done} ({w} x {h}, thr {thr}), beat {k}: rtl {g} model {e}"
        assert pulses[0] == n_corr, f"group at frame {done}: corrected_o {pulses[0]} pulses, model {n_corr}"
        COV["min_size"] += int(w == 3 and h == 3)
        COV["max_w"] += int(w == P["MAX_W"])
        done += len(group)
    dut._log.info("%s: %d frames compared, coverage %s", CASE, done, dict(COV))
    for k in ("bypass", "hot", "dead", "min_size", "max_w"):
        assert COV[k], f"not covered: {k}"
