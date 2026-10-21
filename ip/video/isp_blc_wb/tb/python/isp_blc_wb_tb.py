"""cocotb test of isp_blc_wb against its model (ip/video/isp_blc_wb/model/isp_blc_wb_model.py, blc_wb).

test_frames_exact: RAW frames (noise with the extremes 0 and 2**PW - 1, random sizes down to 1 x 1) back to back
with random input gaps and output back-pressure. The CFA pattern and both bypass bits change at every frame start
(they are taken with the first pixel); the black levels and gains change between groups of frames, with the
block empty (they are read with every pixel), gains up to 15.996 so that the output clamps. Every output beat
(data, tlast, tuser) equals the model's frames, in order.
Environment: BLC_CASE (the parameter set the runner built), BLC_FRAMES (default 120), BLC_SEED."""
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
import isp_blc_wb_model as bm                                    # noqa: E402

CASES = {"pw10": dict(PW=10), "pw12": dict(PW=12)}
CASE = os.environ.get("BLC_CASE", "pw10")
PW = CASES[CASE]["PW"]
FRAMES = int(os.environ.get("BLC_FRAMES", "120"))
SEED = int(os.environ.get("BLC_SEED", "20261021"))
COV = collections.Counter()


@cocotb.test()
async def test_frames_exact(dut):
    """Frames back to back, per-frame and per-group settings: every output beat equals the model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    nrng = np.random.default_rng(SEED)
    top = (1 << PW) - 1
    dut.rst_n.value = 0
    for s in ("s_tvalid", "s_tdata", "s_tlast", "s_tuser", "m_tready", "cfa_i", "blc_bypass_i", "wb_bypass_i",
              "blc_i", "gain_r_i", "gain_g_i", "gain_b_i"):
        getattr(dut, s).value = 0
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    done = 0
    while done < FRAMES:
        levels = [rng.choice([0, rng.randrange(1 << (PW - 2)), top]) for _ in range(4)]
        gains = [rng.choice([256, 0, 4095, rng.randrange(4096)]) for _ in range(3)]
        dut.blc_i.value = sum(v << (i * PW) for i, v in enumerate(levels))
        dut.gain_r_i.value, dut.gain_g_i.value, dut.gain_b_i.value = gains
        group = []
        for _ in range(rng.randrange(1, 6)):
            h, w = rng.choice([(1, 1), (1, 7), (2, 2), (rng.randrange(1, 12), rng.randrange(1, 40))])
            raw = nrng.integers(0, top + 1, (h, w))
            raw[nrng.random((h, w)) < 0.1] = rng.choice([0, top])
            cfg = dict(cfa=rng.randrange(4), blc_bypass=rng.random() < 0.25, wb_bypass=rng.random() < 0.25)
            group.append((raw, cfg))
            COV[f"cfa{cfg['cfa']}"] += 1
            COV["bypass_blc"] += cfg["blc_bypass"]
            COV["bypass_wb"] += cfg["wb_bypass"]

        def on_frame(f):
            c = group[f][1]
            dut.cfa_i.value, dut.blc_bypass_i.value, dut.wb_bypass_i.value = c["cfa"], c["blc_bypass"], c["wb_bypass"]
        exp = []
        for raw, cfg in group:
            out = bm.blc_wb(raw, levels=levels, gains=gains, pw=PW, **cfg)
            exp += frame_beats(out, int)
            COV["clamped"] += int((out == top).sum())
        got = await run_frames(dut, rng, [frame_beats(raw, int) for raw, _ in group], on_frame=on_frame,
                               gap=rng.choice([0.0, 0.3]), bp=rng.choice([0.0, 0.3, 0.6]))
        for k, (g, e) in enumerate(zip(got, exp)):
            assert g == e, f"group at frame {done}, beat {k}: rtl {g} model {e} (levels {levels} gains {gains})"
        done += len(group)
    dut._log.info("%s: %d frames compared, coverage %s", CASE, done, dict(COV))
    for k in ("cfa0", "cfa1", "cfa2", "cfa3", "bypass_blc", "bypass_wb", "clamped"):
        assert COV[k], f"not covered: {k}"
