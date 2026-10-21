"""cocotb test of isp_demosaic against its model (ip/video/isp_demosaic/model/isp_demosaic_model.py,
demosaic_frame).

test_frames_exact: RAW frames (noise with the extremes, colour patches) back to back with random input gaps and
output back-pressure; the CFA pattern and bypass change at every frame (taken when the frame's first output pixel
leaves: a frame starts once the earlier frames' output has begun, as a frame of few lines gives its first output
pixel after its last input beat); the frame size (2 x 2 up to MAX_W wide) changes between groups of frames with the
block empty. Every output beat equals the model's frames, in order. Environment: DEM_CASE, DEM_FRAMES (default 80),
DEM_SEED."""
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
import isp_demosaic_model as dm                                  # noqa: E402

CASES = {"pw10": dict(PW=10, MAX_W=64), "pw8": dict(PW=8, MAX_W=32)}
CASE = os.environ.get("DEM_CASE", "pw10")
P = CASES[CASE]
PW = P["PW"]
FRAMES = int(os.environ.get("DEM_FRAMES", "80"))
SEED = int(os.environ.get("DEM_SEED", "20261021"))
COV = collections.Counter()


@cocotb.test()
async def test_frames_exact(dut):
    """Frames back to back with per-frame CFA / bypass: every output beat equals the model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    nrng = np.random.default_rng(SEED)
    top = (1 << PW) - 1
    dut.rst_n.value = 0
    for s in ("s_tvalid", "s_tdata", "s_tlast", "s_tuser", "m_tready", "bypass_i", "cfa_i", "width_i", "height_i"):
        getattr(dut, s).value = 0
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1

    def pack(p):
        return int(p[0]) | int(p[1]) << PW | int(p[2]) << (2 * PW)
    done = 0
    while done < FRAMES:
        w = rng.choice([2, P["MAX_W"], rng.randrange(2, P["MAX_W"] + 1), rng.randrange(2, 12)])
        h = rng.choice([2, rng.randrange(2, 12)])
        dut.width_i.value, dut.height_i.value = w, h
        group = []
        for _ in range(rng.randrange(1, 5)):
            raw = nrng.integers(0, top + 1, (h, w))
            raw[nrng.random((h, w)) < 0.1] = rng.choice([0, top])
            group.append((raw, rng.randrange(4), rng.random() < 0.2))
        exp = []
        for raw, cfa, by in group:
            exp += frame_beats(dm.demosaic_frame(raw, cfa, by), pack)
            COV[f"cfa{cfa}"] += 1
            COV["bypass"] += by

        def on_frame(f):
            dut.cfa_i.value, dut.bypass_i.value = group[f][1], group[f][2]
        got = await run_frames(dut, rng, [frame_beats(raw, int) for raw, _, _ in group], on_frame=on_frame,
                               gap=rng.choice([0.0, 0.3]), bp=rng.choice([0.0, 0.3, 0.6]), after_out_sof=True)
        for k, (g, e) in enumerate(zip(got, exp)):
            assert g == e, f"group at frame {done} ({w} x {h}), beat {k}: rtl {g} model {e}"
        COV["min_size"] += int(w == 2 and h == 2)
        COV["max_w"] += int(w == P["MAX_W"])
        done += len(group)
    dut._log.info("%s: %d frames compared, coverage %s", CASE, done, dict(COV))
    for k in ("cfa0", "cfa1", "cfa2", "cfa3", "bypass", "min_size", "max_w"):
        assert COV[k], f"not covered: {k}"
