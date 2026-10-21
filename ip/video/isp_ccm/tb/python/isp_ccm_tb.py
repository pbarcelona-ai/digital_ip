"""cocotb test of isp_ccm against its model (ip/video/isp_ccm/model/isp_ccm_model.py, ccm_frame).

test_frames_exact: RGB frames (noise with the extremes) back to back with random input gaps and output back-pressure;
bypass changes at every frame start (taken with the first pixel); coefficients (identity, typical colour matrices,
random full-range signed Q5.10) and offsets (signed, up to the full 16-bit range) change between groups of frames
with the block empty. Every output beat equals the model's frames, in order; clamping at 0 and at 2**PW - 1 covered.
Environment: CCM_CASE, CCM_FRAMES (default 100), CCM_SEED."""
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
import isp_ccm_model as cm                                       # noqa: E402

CASES = {"pw10": dict(PW=10), "pw8": dict(PW=8)}
CASE = os.environ.get("CCM_CASE", "pw10")
PW = CASES[CASE]["PW"]
FRAMES = int(os.environ.get("CCM_FRAMES", "100"))
SEED = int(os.environ.get("CCM_SEED", "20261021"))
COV = collections.Counter()


def matrix(rng):
    kind = rng.choice(["id", "typical", "rand", "rand"])
    COV[f"m_{kind}"] += 1
    if kind == "id":
        return [[1024 if i == j else 0 for j in range(3)] for i in range(3)], [0, 0, 0]
    if kind == "typical":
        m = [[rng.randrange(-400, 400) for _ in range(3)] for _ in range(3)]
        for i in range(3):
            m[i][i] = 1024 - sum(m[i][j] for j in range(3) if j != i)
        return m, [rng.randrange(-30, 30) for _ in range(3)]
    return ([[rng.randrange(-32768, 32768) for _ in range(3)] for _ in range(3)],
            [rng.choice([rng.randrange(-32768, 32768), rng.randrange(-100, 100)]) for _ in range(3)])


@cocotb.test()
async def test_frames_exact(dut):
    """Frames back to back, per-frame bypass and per-group matrices: every output beat equals the model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    nrng = np.random.default_rng(SEED)
    top = (1 << PW) - 1
    dut.rst_n.value = 0
    for s in ("s_tvalid", "s_tdata", "s_tlast", "s_tuser", "m_tready", "bypass_i", "coef_i", "off_i"):
        getattr(dut, s).value = 0
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1

    def pack(p):
        return int(p[0]) | int(p[1]) << PW | int(p[2]) << (2 * PW)
    done = 0
    while done < FRAMES:
        coef, off = matrix(rng)
        dut.coef_i.value = sum((coef[i][j] & 0xFFFF) << ((3 * i + j) * 16) for i in range(3) for j in range(3))
        dut.off_i.value = sum((off[i] & 0xFFFF) << (i * 16) for i in range(3))
        group = []
        for _ in range(rng.randrange(1, 6)):
            h, w = rng.choice([(1, 1), (rng.randrange(1, 10), rng.randrange(1, 40))])
            rgb = nrng.integers(0, top + 1, (h, w, 3))
            rgb[nrng.random((h, w)) < 0.1] = rng.choice([0, top])
            group.append((rgb, rng.random() < 0.2))
        dut.bypass_i.value = group[0][1]
        exp = []
        for rgb, by in group:
            out = cm.ccm_frame(rgb, coef, off, by, PW)
            exp += frame_beats(out, pack)
            COV["bypass"] += by
            if not by:
                COV["clamp_lo"] += int((out == 0).any())
                COV["clamp_hi"] += int((out == top).any())
        got = await run_frames(dut, rng, [frame_beats(rgb, pack) for rgb, _ in group],
                               on_frame=lambda f: setattr(dut.bypass_i, "value", group[f][1]),
                               gap=rng.choice([0.0, 0.3]), bp=rng.choice([0.0, 0.3, 0.6]))
        for k, (g, e) in enumerate(zip(got, exp)):
            assert g == e, f"group at frame {done}, beat {k}: rtl {g} model {e} (coef {coef} off {off})"
        done += len(group)
    dut._log.info("%s: %d frames compared, coverage %s", CASE, done, dict(COV))
    for k in ("m_id", "m_typical", "m_rand", "bypass", "clamp_lo", "clamp_hi"):
        assert COV[k], f"not covered: {k}"
