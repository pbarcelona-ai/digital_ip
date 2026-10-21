"""cocotb test of isp_csc against its model (ip/video/isp_csc/model/isp_csc_model.py, csc_frame).

test_frames_exact: RGB frames (noise, grey ramps, the corners of the RGB cube) back to back with random input gaps
and output back-pressure; bypass and the BT.601 / BT.709 select change at every frame start (taken with the first
pixel). Every output beat equals the model's frames, in order. Environment: CSC_FRAMES (default 120), CSC_SEED."""
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
import isp_csc_model as cm                                       # noqa: E402

CASES = {"default": {}}
FRAMES = int(os.environ.get("CSC_FRAMES", "120"))
SEED = int(os.environ.get("CSC_SEED", "20261021"))
COV = collections.Counter()
CORNERS = np.array([[r, g, b] for r in (0, 255) for g in (0, 255) for b in (0, 255)])


def pack(p):
    return int(p[0]) | int(p[1]) << 8 | int(p[2]) << 16


@cocotb.test()
async def test_frames_exact(dut):
    """Frames back to back with per-frame bypass / matrix: every output beat equals the model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    nrng = np.random.default_rng(SEED)
    dut.rst_n.value = 0
    for s in ("s_tvalid", "s_tdata", "s_tlast", "s_tuser", "m_tready", "bypass_i", "bt709_i"):
        getattr(dut, s).value = 0
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    done = 0
    while done < FRAMES:
        group = []
        for _ in range(rng.randrange(1, 8)):
            h, w = rng.choice([(1, 1), (1, 8), (rng.randrange(1, 10), rng.randrange(1, 40))])
            kind = rng.choice(["noise", "ramp", "corners"])
            if kind == "noise":
                rgb = nrng.integers(0, 256, (h, w, 3))
            elif kind == "ramp":
                rgb = np.repeat((np.arange(h * w) % 256).reshape(h, w, 1), 3, -1)
            else:
                rgb = CORNERS[nrng.integers(0, 8, (h, w))]
            cfg = (rng.random() < 0.5, rng.random() < 0.2)
            group.append((rgb, cfg))
            COV[f"{kind}_{'709' if cfg[0] else '601'}"] += 1
            COV["bypass"] += cfg[1]

        def on_frame(f):
            dut.bt709_i.value, dut.bypass_i.value = group[f][1]
        exp = []
        for rgb, (m709, by) in group:
            exp += frame_beats(cm.csc_frame(rgb, m709, by), pack)
        got = await run_frames(dut, rng, [frame_beats(rgb, pack) for rgb, _ in group], on_frame=on_frame,
                               gap=rng.choice([0.0, 0.3]), bp=rng.choice([0.0, 0.3, 0.6]))
        for k, (g, e) in enumerate(zip(got, exp)):
            assert g == e, f"group at frame {done}, beat {k}: rtl {g:} model {e}"
        done += len(group)
    dut._log.info("csc: %d frames compared, coverage %s", done, dict(COV))
    for k in ("noise_601", "noise_709", "corners_601", "corners_709", "bypass"):
        assert COV[k], f"not covered: {k}"
