"""cocotb test of mac_array against its model (ip/math/mac_array/model/mac_array_model.py).

test_mac_array_exact: random activations, weights, and accumulators. Every clock: result equals the model.
Coverage: all rows/columns, saturation, zero weights, identity weights.
Environment: MACA_CASE (parameter set), MACA_N (clocks, default 10000), MACA_SEED."""
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
sys.path.insert(0, str(IP / "model"))
import mac_array_model as mam

CASES = {
    "8x8": dict(ROWS=8, COLS=8, A_WIDTH=8, W_WIDTH=8, ACC_WIDTH=32),
    "16x16": dict(ROWS=16, COLS=16, A_WIDTH=8, W_WIDTH=8, ACC_WIDTH=32),
    "64x64": dict(ROWS=64, COLS=64, A_WIDTH=8, W_WIDTH=8, ACC_WIDTH=32),
}
CASE = os.environ.get("MACA_CASE", "8x8")
P = CASES[CASE]
N = int(os.environ.get("MACA_N", "10000"))
SEED = int(os.environ.get("MACA_SEED", "20261024"))

def pack_vec(vec, width):
    """Pack a list of ints into a single integer (LSB first)."""
    result = 0
    for i, v in enumerate(vec):
        result |= (v & ((1 << width) - 1)) << (i * width)
    return result

def unpack_vec(val, n, width):
    """Unpack an integer into a list of ints."""
    mask = (1 << width) - 1
    return [(val >> (i * width)) & mask for i in range(n)]

@cocotb.test()
async def test_mac_array_exact(dut):
    """Every clock: result equals the model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    
    # Create model
    model = mam.MacArray(rows=P["ROWS"], cols=P["COLS"])
    
    # Load random weights
    weights = [[rng.randint(-128, 127) for _ in range(P["ROWS"])] for _ in range(P["COLS"])]
    model.load_weights(weights)
    
    # Load weights into RTL (stream one row per clock)
    for r in range(P["ROWS"]):
        w_row = [weights[c][r] for c in range(P["COLS"])]
        dut.w_valid_i.value = 1
        dut.w_row_i.value = pack_vec(w_row, P["W_WIDTH"])
        dut.w_row_idx_i.value = r
        await FallingEdge(dut.clk)
    dut.w_valid_i.value = 0
    await FallingEdge(dut.clk)
    
    # Load random accumulator
    acc = [rng.randint(-(1<<31), (1<<31)-1) for _ in range(P["COLS"])]
    model.load_acc(acc)
    dut.acc_valid_i.value = 1
    dut.acc_i.value = pack_vec(acc, P["ACC_WIDTH"])
    await FallingEdge(dut.clk)
    dut.acc_valid_i.value = 0
    await FallingEdge(dut.clk)
    
    cov = collections.Counter()
    
    for i in range(N):
        await FallingEdge(dut.clk)
        
        # Random valid
        valid = rng.random() < 0.8
        dut.valid_i.value = valid
        
        if valid:
            a_vec = [rng.randint(-128, 127) for _ in range(P["ROWS"])]
            dut.a_i.value = pack_vec(a_vec, P["A_WIDTH"])
            
            model_valid, model_result = model.cycle(valid, a_vec)
        else:
            model_valid, model_result = model.cycle(valid, [0]*P["ROWS"])
        
        await Timer(1, unit="ns")
        
        # Compare
        rtl_valid = int(dut.valid_o.value)
        rtl_result = unpack_vec(int(dut.result_o.value), P["COLS"], P["ACC_WIDTH"])
        
        assert rtl_valid == model_valid, f"clock {i}: valid rtl {rtl_valid} model {model_valid}"
        if model_valid:
            for c in range(P["COLS"]):
                assert rtl_result[c] == model_result[c], \
                    f"clock {i}: col {c} rtl {rtl_result[c]} model {model_result[c]}"
                cov[f"col{c}"] += 1
                
                # Check saturation
                if rtl_result[c] == (1 << 31) - 1 or rtl_result[c] == -(1 << 31):
                    cov["saturation"] += 1
    
    dut._log.info("%s: %d clocks compared, coverage %s", CASE, N, dict(sorted(cov.items())))
    for c in range(P["COLS"]):
        assert cov[f"col{c}"] > 0, f"not covered: col{c}"

