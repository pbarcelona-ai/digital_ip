"""cocotb test of fallthrough_fifo against its model (ip/fifo/fallthrough_fifo/model/fallthrough_fifo_model.py).

test_fifo_exact: random pushes and pops in phases (fill: push often, pop rarely; drain; balanced; both every
clock), random data, a reset in the middle of a run (the FIFO empties; the run goes on); in every clock
s_ready_o, m_valid_o, level_o and (while valid) m_data_o equal the model's. Coverage: full with a push refused,
full with a pop, empty with a push, simultaneous push and pop, the reset.
Environment: FTF_CASE (the parameter set the runner built), FTF_N (clocks, default 6000), FTF_SEED."""
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
import fallthrough_fifo_model as fm                              # noqa: E402

CASES = {"w32d16": dict(WIDTH=32, DEPTH=16), "w8d2": dict(WIDTH=8, DEPTH=2), "w5d64": dict(WIDTH=5, DEPTH=64)}
CASE = os.environ.get("FTF_CASE", "w32d16")
P = CASES[CASE]
N = int(os.environ.get("FTF_N", "6000"))
SEED = int(os.environ.get("FTF_SEED", "20261021"))


@cocotb.test()
async def test_fifo_exact(dut):
    """Every clock: the flags, the level and the head word equal the model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    m = fm.FallthroughFifo(P["WIDTH"], P["DEPTH"])
    cov = collections.Counter()
    dut.rst_n.value = 0
    dut.s_valid_i.value = dut.m_ready_i.value = dut.s_data_i.value = 0
    await FallingEdge(dut.clk)
    m.cycle(rst_n=0)
    phases = [(0.9, 0.1), (0.1, 0.9), (0.5, 0.5), (1.0, 1.0)]
    pv, pr = phases[0]
    for i in range(N):
        await FallingEdge(dut.clk)
        if i % 200 == 0:
            pv, pr = rng.choice(phases)
        rst = int(i == N // 2)
        sv, mr, sd = int(rng.random() < pv), int(rng.random() < pr), rng.getrandbits(P["WIDTH"])
        dut.rst_n.value, dut.s_valid_i.value, dut.m_ready_i.value, dut.s_data_i.value = 1 - rst, sv, mr, sd
        await Timer(1, unit="ns")
        o = m.cycle(sd, sv, mr, rst_n=1 - rst)
        for k in ("s_ready_o", "m_valid_o", "level_o"):
            assert int(getattr(dut, k).value) == o[k], f"clock {i}: {k} rtl {getattr(dut, k).value} model {o[k]}"
        if o["m_valid_o"]:
            assert int(dut.m_data_o.value) == o["m_data_o"], \
                f"clock {i}: m_data_o rtl {int(dut.m_data_o.value):#x} model {o['m_data_o']:#x}"
        full, empty = o["level_o"] == P["DEPTH"], o["level_o"] == 0
        cov["reset"] += rst
        if not rst:
            cov["full_push_refused"] += int(full and sv)
            cov["full_pop"] += int(full and mr)
            cov["empty_push"] += int(empty and sv)
            cov["push_and_pop"] += int(sv and o["s_ready_o"] and mr and o["m_valid_o"])
    dut._log.info("%s: %d clocks compared, coverage %s", CASE, N, dict(cov))
    for k in ("full_push_refused", "full_pop", "empty_push", "push_and_pop", "reset"):
        assert cov[k], f"not covered: {k}"
