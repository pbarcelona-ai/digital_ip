"""cocotb tests of blur_sharpen against its model (ip/video/blur_sharpen/model/blur_sharpen_model.py).

test_frames_exact: frames (noise, gradients, edges; random sizes from the 14-pixel minimum up to MAX_W wide)
streamed back to back with random input gaps, beats without tuser before some frame starts (dropped) and random
output back-pressure. Before each frame the next configuration is written while the previous frame is still
leaving the filter (the per-frame copies): MODE 0-7 (every mode in the first frames), FRAME_SIZE, both kernels
(the reset kernels, normalised random kernels, full-range random kernels, single coefficients) and both shifts.
Every output beat (data, tlast, tuser) equals the model's frame, in order; at sync points (filter empty)
STATUS and every register read back equal the model's.
test_register_map: the ID block and every register's read-back against the model (reset values included).
Environment: BLSH_CASE (the parameter set the runner built), BLSH_FRAMES (default 30), BLSH_SEED."""
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
from cocotb_lib import AxilMaster, model_path                    # noqa: E402

model_path(IP / "model", IP.parent / "conv2d_core" / "model", IP.parent / "isp_window" / "model")
import blur_sharpen_model as bm                                  # noqa: E402

CASES = {"d5": dict(N=5, C=3, CW=8, COEF_W=12, MAX_W=64, BORDER=0, AMOUNT=1),
         "d3": dict(N=3, C=1, CW=10, COEF_W=10, MAX_W=48, BORDER=1, AMOUNT=2)}
CASE = os.environ.get("BLSH_CASE", "d5")
P = CASES[CASE]
FRAMES = int(os.environ.get("BLSH_FRAMES", "30"))
SEED = int(os.environ.get("BLSH_SEED", "20261021"))
A = dict(MODE=0x14, FRAME_SIZE=0x18, BLUR_SHIFT=0x1C, SHARP_SHIFT=0x20, STATUS=0x24, INFO=0x28, BLUR_K=0x50,
         SHARP_K=0xD0)
COV = collections.Counter()


def model():
    """The model with the wrapper's parameters (RESET_W 16, RESET_H 8)."""
    return bm.BlurSharpen(P["N"], P["C"], P["CW"], P["COEF_W"], P["BORDER"], P["AMOUNT"], 16, 8)


def image(rng, nrng, w, h):
    top = (1 << P["CW"]) - 1
    kind = rng.choice(["noise", "grad", "edges"])
    COV[f"img_{kind}"] += 1
    if kind == "noise":
        return nrng.integers(0, top + 1, (h, w, P["C"]))
    yy, xx = np.mgrid[0:h, 0:w]
    if kind == "grad":
        f = (xx * top // max(w - 1, 1) + yy * 3)[..., None] + nrng.integers(-4, 5, (h, w, P["C"]))
    else:
        f = np.where(((xx // 3 + yy // 2) & 1)[..., None], top, 0) + np.zeros((h, w, P["C"]), np.int64)
    return f.clip(0, top)


def beats_of(frame):
    h, w = frame.shape[:2]
    cw = P["CW"]
    return [(sum(int(frame[y, x, j]) << (j * cw) for j in range(P["C"])), int(x == w - 1), int(x == 0 and y == 0))
            for y in range(h) for x in range(w)]


def kernel(rng, kind):
    """(coefficients, shift) of one kernel."""
    n, cw, lim = P["N"], P["CW"], 1 << (P["COEF_W"] - 1)
    nn = n * n
    if kind == "blur":
        return bm.blur_kernel(n), 2 * (n - 1)
    if kind == "sharp":
        return bm.sharpen_kernel(n, rng.randrange(1, 3)), 2 * (n - 1)
    if kind == "norm":                                            # sums to about 2**shift
        s = rng.randrange(2, min(P["COEF_W"] - 1, 9))
        k = [rng.randrange(-(1 << (s - 3)) if s > 3 else -1, (1 << (s - 2)) + 1) for _ in range(nn)]
        k[nn // 2] += (1 << s) - sum(k)
        k[nn // 2] = max(-lim, min(lim - 1, k[nn // 2]))
        return k, s
    return [rng.randrange(-lim, lim) for _ in range(nn)], rng.randrange(0, cw + P["COEF_W"] + 6)


@cocotb.test()
async def test_frames_exact(dut):
    """Frames back to back, configurations written between them: every output beat equals the model's."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    for s in ("s_tvalid", "s_tdata", "s_tuser", "s_tlast", "m_tready"):
        getattr(dut, s).value = 0
    for _ in range(4):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    rng = random.Random(SEED)
    nrng = np.random.default_rng(SEED)
    m = model()
    axi = AxilMaster(dut, dut.clk)
    n, r = P["N"], P["N"] // 2
    exp = collections.deque()                                     # (frame, index, beat)
    state = dict(got=0, bp=0.3, stop=False)

    async def monitor():
        while not state["stop"]:
            await FallingEdge(dut.clk)
            dut.m_tready.value = int(rng.random() >= state["bp"])
            await Timer(1, unit="ns")
            if dut.m_tvalid.value and dut.m_tready.value:
                assert exp, "output beat with no frame expected"
                f, i, w, e = exp.popleft()
                rtl = (int(dut.m_tdata.value), int(dut.m_tlast.value), int(dut.m_tuser.value))
                if rtl != e:
                    raise AssertionError(f"frame {f} pixel x {i % w} y {i // w}: rtl {rtl[0]:#x} last {rtl[1]} "
                                         f"user {rtl[2]}; model {e[0]:#x} last {e[1]} user {e[2]}")
                state["got"] += 1

    async def drain():
        for _ in range(200000):
            if not exp:
                return
            await FallingEdge(dut.clk)
        raise AssertionError(f"{len(exp)} output beats missing")

    async def w(name, d, i=0):
        assert await axi.write(A[name] + 4 * i, d) == m.r.write(A[name] + 4 * i, d), f"write {name}[{i}]"

    async def check_regs(f):
        offs = [A[k] for k in ("MODE", "FRAME_SIZE", "BLUR_SHIFT", "SHARP_SHIFT", "STATUS", "INFO")]
        offs += [A[b] + 4 * i for b in ("BLUR_K", "SHARP_K") for i in range(n * n)]
        for off in offs:
            d, _ = await axi.read(off)
            assert d == m.r.read(off)[0], f"after frame {f}: 0x{off:03X} rtl {d:#x} model {m.r.read(off)[0]:#x}"

    mon = cocotb.start_soon(monitor())
    wd, ht = 16, 8                                                # RESET_W / RESET_H of the wrapper
    for f in range(FRAMES):
        if rng.random() < 0.05:
            state["bp"] = rng.choice([0.0, 0.3, 0.7])
        mode = f if f < 8 else rng.randrange(8)
        await w("MODE", mode)
        COV[f"mode{mode}"] += 1
        if f and rng.random() < 0.5:
            wd = rng.choice([r + 1, P["MAX_W"], rng.randrange(r + 1, P["MAX_W"] + 1), rng.randrange(r + 1, 13)])
            ht = max(rng.choice([r + 1, rng.randrange(r + 1, 10)]), -(-14 // wd))
            await w("FRAME_SIZE", ht << 16 | wd)
        COV["size_min"] += int(wd == r + 1 or ht == r + 1)
        COV["size_max"] += int(wd == P["MAX_W"])
        for bank, sh in (("BLUR_K", "BLUR_SHIFT"), ("SHARP_K", "SHARP_SHIFT")):
            kind = rng.choice(["keep", "keep", "one", "blur", "sharp", "norm", "norm", "rand"])
            COV[f"k_{kind}"] += 1
            if kind == "one":
                await w(bank, rng.getrandbits(32), rng.randrange(n * n))
            elif kind != "keep":
                k, s = kernel(rng, kind)
                for i, c in enumerate(k):
                    await w(bank, c, i)
                await w(sh, s)
        frame = image(rng, nrng, wd, ht)
        out = m.run(frame)
        exp.extend((f, i, wd, b) for i, b in enumerate(beats_of(out)))
        beats = [(rng.getrandbits(P["C"] * P["CW"]), 0, 0) for _ in range(rng.choice([0, 0, 0, 2]))]
        COV["dropped"] += len(beats)
        beats += beats_of(frame)
        gap = rng.choice([0.0, 0.3, 0.6])
        k = 0
        for _ in range(50 * len(beats) + 5000):
            await FallingEdge(dut.clk)
            d, last, user = beats[k]
            dut.s_tdata.value, dut.s_tlast.value, dut.s_tuser.value = d, last, user
            dut.s_tvalid.value = int(rng.random() >= gap)
            await Timer(1, unit="ns")
            if dut.s_tvalid.value and dut.s_tready.value:
                k += 1
                if k == len(beats):
                    break
        await FallingEdge(dut.clk)
        dut.s_tvalid.value = 0
        assert k == len(beats), f"frame {f}: {k} of {len(beats)} input beats taken"
        if f % 6 == 5 or f == FRAMES - 1:                         # sync point: the filter empty
            await drain()
            for _ in range(10):
                await FallingEdge(dut.clk)
            await check_regs(f)
    await drain()
    state["stop"] = True
    await mon
    dut._log.info("%s: %d frames, %d beats compared, coverage %s", CASE, FRAMES, state["got"], dict(COV))
    if FRAMES >= 20:
        for c in [f"mode{i}" for i in range(8)] + ["size_min", "size_max", "k_rand", "k_norm", "k_one", "dropped"]:
            assert COV[c], f"not covered: {c}"


@cocotb.test()
async def test_register_map(dut):
    """The ID block and every register's read-back against the model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    for _ in range(4):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    rng = random.Random(SEED + 1)
    m = model()
    axi = AxilMaster(dut, dut.clk)
    offs = sorted(set(m.r.regs) | {0x0, 0x4, 0x8, 0xC, 0x10, 0x2C, 0x150, 0x1FC})
    for off in offs:
        d, resp = await axi.read(off)
        assert (d, resp) == m.r.read(off), f"reset 0x{off:03X}: rtl {d:x}/{resp} model {m.r.read(off)}"
    for _ in range(400):
        off = rng.choice(offs)
        if rng.random() < 0.5:
            d = rng.getrandbits(32)
            assert await axi.write(off, d) == m.r.write(off, d), f"write 0x{off:03X}"
        else:
            d, resp = await axi.read(off)
            assert (d, resp) == m.r.read(off), f"read 0x{off:03X}: rtl {d:x}/{resp} model {m.r.read(off)}"
    for _ in range(2):
        await FallingEdge(dut.clk)
