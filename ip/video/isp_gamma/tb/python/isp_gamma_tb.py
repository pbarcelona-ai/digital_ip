"""cocotb test of isp_gamma against its model (ip/video/isp_gamma/model/isp_gamma_model.py, gamma_frame).

test_frames_exact: the power-up table (the linear curve) first, then tables written through the LUT port with
the block empty (random curves, gamma curves, inverted), RGB frames back to back with random input gaps and output
back-pressure; bypass changes at every frame start. Every output beat equals the model's frames, in order.
Environment: GAM_CASE, GAM_FRAMES (default 100), GAM_SEED."""
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
import isp_gamma_model as gm                                     # noqa: E402

CASES = {"i10o8": dict(IN_W=10, OUT_W=8), "i8o8": dict(IN_W=8, OUT_W=8)}
CASE = os.environ.get("GAM_CASE", "i10o8")
IW, OW = CASES[CASE]["IN_W"], CASES[CASE]["OUT_W"]
FRAMES = int(os.environ.get("GAM_FRAMES", "100"))
SEED = int(os.environ.get("GAM_SEED", "20261021"))
COV = collections.Counter()


@cocotb.test()
async def test_frames_exact(dut):
    """Frames back to back, per-frame bypass and tables between groups: every output beat equals the model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    nrng = np.random.default_rng(SEED)
    n = 1 << IW
    dut.rst_n.value = 0
    for s in ("s_tvalid", "s_tdata", "s_tlast", "s_tuser", "m_tready", "bypass_i", "lut_we_i", "lut_addr_i",
              "lut_data_i"):
        getattr(dut, s).value = 0
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    table = [a >> (IW - OW) for a in range(n)]                    # the power-up contents

    def pack(p):
        return int(p[0]) | int(p[1]) << IW | int(p[2]) << (2 * IW)

    def pack_o(p):
        return int(p[0]) | int(p[1]) << OW | int(p[2]) << (2 * OW)
    done = g = 0
    while done < FRAMES:
        if g:                                                     # a new table, written with the block empty
            kind = rng.choice(["rand", "gamma", "invert"])
            COV[f"t_{kind}"] += 1
            if kind == "rand":
                table = [rng.getrandbits(OW) for _ in range(n)]
            elif kind == "gamma":
                gm_ = rng.uniform(0.3, 2.5)
                table = [min((1 << OW) - 1, int(((a / (n - 1)) ** gm_) * ((1 << OW) - 1) + 0.5)) for a in range(n)]
            else:
                table = [((1 << OW) - 1) - (a >> (IW - OW)) for a in range(n)]
            for a, v in enumerate(table):
                await FallingEdge(dut.clk)
                dut.lut_we_i.value, dut.lut_addr_i.value, dut.lut_data_i.value = 1, a, v
            await FallingEdge(dut.clk)
            dut.lut_we_i.value = 0
        else:
            COV["t_powerup"] += 1
        g += 1
        group = []
        for _ in range(rng.randrange(1, 6)):
            h, w = rng.choice([(1, 1), (rng.randrange(1, 10), rng.randrange(1, 40))])
            group.append((nrng.integers(0, n, (h, w, 3)), rng.random() < 0.2))
        exp = []
        for rgb, by in group:
            exp += frame_beats(gm.gamma_frame(rgb, table, by, IW, OW), pack_o)
            COV["bypass"] += by
        got = await run_frames(dut, rng, [frame_beats(rgb, pack) for rgb, _ in group],
                               on_frame=lambda f: setattr(dut.bypass_i, "value", group[f][1]),
                               gap=rng.choice([0.0, 0.3]), bp=rng.choice([0.0, 0.3, 0.6]))
        for k, (gt, e) in enumerate(zip(got, exp)):
            assert gt == e, f"group {g} (frame {done}), beat {k}: rtl {gt} model {e}"
        done += len(group)
    dut._log.info("%s: %d frames compared, coverage %s", CASE, done, dict(COV))
    for k in ("t_powerup", "t_rand", "bypass"):
        assert COV[k], f"not covered: {k}"
