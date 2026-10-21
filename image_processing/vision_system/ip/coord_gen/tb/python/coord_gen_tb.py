"""cocotb test of coord_gen against its model (ip/coord_gen/model/coord_gen_model.py).

test_fast_exact: RADIAL (realistic barrel / pincushion calibrations with tangential terms, and random full-range
coefficients that saturate the multiplies), AFFINE, SCALING and the reserved codes 6 / 7: random requests every
clock (random valid), out_valid and (sx, sy) exactly 23 clocks later equal the model; busy stays 0.
test_slow_exact: FISHEYE, PANORAMIC and PERSPECTIVE (realistic and extreme coefficients, denominators that hit
<= 0): one request at a time; busy from the next clock until the result, out_valid exactly SLOW_LATENCY clocks
after the request, (sx, sy) equal the model. The calibration changes only while no request is in flight.
Environment: CG_N (fast requests per calibration, default 400), CG_SLOW (slow requests per calibration, default
12), CG_SEED."""
from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

import vs_cocotb

vs_cocotb.models()
import coord_gen_model as cm                                      # noqa: E402
from fixed_recip_model import recip                               # noqa: E402

CASES = {"default": {}}
N = int(os.environ.get("CG_N", "400"))
NSLOW = int(os.environ.get("CG_SLOW", "12"))
SEED = int(os.environ.get("CG_SEED", "20261021"))
FIELDS = [f for f in cm.CalibParams.__dataclass_fields__ if f != "model_sel"]
Q = 1 << 16


def calib(rng, model, extreme):
    """A calibration: a frame of up to 720 x 720 with its pinhole intrinsics, the model's coefficients."""
    w, h = rng.choice([(720, 480), (480, 720), (640, 480), (64, 48)])
    s = rng.choice([1.0, 0.8, 1.25])
    fx, fy = int(w / 2 * s * Q), int(h / 2 * s * Q)
    c = cm.CalibParams(cx_pix=int(w / 2 * Q) + rng.randrange(-Q, Q), cy_pix=int(h / 2 * Q) + rng.randrange(-Q, Q),
                       fx_pix=fx, fy_pix=fy, recip_fx=recip(fx), recip_fy=recip(fy), model_sel=model)
    if extreme:
        for f in FIELDS:
            if rng.random() < 0.6:
                setattr(c, f, rng.randrange(-(1 << 31), 1 << 31) if f not in ("recip_fx", "recip_fy")
                        else rng.getrandbits(32))
    else:
        c.k1, c.k2, c.k3 = (int(rng.uniform(-0.4, 0.4) * Q), int(rng.uniform(-0.2, 0.2) * Q),
                            int(rng.uniform(-0.05, 0.05) * Q))
        c.p1, c.p2 = int(rng.uniform(-0.02, 0.02) * Q), int(rng.uniform(-0.02, 0.02) * Q)
        c.h11, c.h22 = int(rng.uniform(0.8, 1.2) * Q), int(rng.uniform(0.8, 1.2) * Q)
        c.h12, c.h21 = int(rng.uniform(-0.1, 0.1) * Q), int(rng.uniform(-0.1, 0.1) * Q)
        c.h13, c.h23 = rng.randrange(-20 * Q, 20 * Q), rng.randrange(-20 * Q, 20 * Q)
        c.h31, c.h32 = int(rng.uniform(-3e-4, 3e-4) * Q), int(rng.uniform(-3e-4, 3e-4) * Q)
    return c, w, h


def apply(dut, c):
    for f in FIELDS:
        getattr(dut, f).value = getattr(c, f) & 0xFFFFFFFF
    dut.model_sel.value = c.model_sel


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    dut.in_valid.value = 0
    dut.in_x.value = dut.in_y.value = 0
    apply(dut, cm.CalibParams())
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1


def point(rng, w, h):
    return rng.choice([(rng.randrange(w), rng.randrange(h)), (0, 0), (w - 1, h - 1), (rng.randrange(2048),
                                                                                       rng.randrange(2048))])


@cocotb.test()
async def test_fast_exact(dut):
    """Fast-path models: every result equals the model, 23 clocks after its request."""
    await setup(dut)
    rng = random.Random(SEED)
    n = 0
    for k, model in enumerate([cm.RADIAL] * 6 + [cm.AFFINE, cm.SCALING, 6, 7]):
        c, w, h = calib(rng, model, extreme=(k % 3 == 2))
        apply(dut, c)
        hist = []
        for i in range(N + cm.LATENCY):
            await FallingEdge(dut.clk)
            v = int(i < N and rng.random() < 0.85)
            x, y = point(rng, w, h)
            dut.in_valid.value, dut.in_x.value, dut.in_y.value = v, x, y
            hist.append((v, x, y))
            await Timer(1, unit="ns")
            assert int(dut.busy.value) == 0, "busy on the fast path"
            if i >= cm.LATENCY:
                ev, ex, ey = hist[i - cm.LATENCY]
                assert int(dut.out_valid.value) == ev, f"model {model} request {i - cm.LATENCY}: out_valid"
                if ev:
                    exp = cm.coord_gen(c, ex, ey)
                    got = (dut.out_sx_q16.value.to_signed(), dut.out_sy_q16.value.to_signed())
                    assert got == exp, f"model {model} ({ex}, {ey}) {c}: rtl {got} model {exp}"
                    n += 1
        dut.in_valid.value = 0
    dut._log.info("coord_gen fast path: %d results compared", n)


@cocotb.test()
async def test_slow_exact(dut):
    """Slow-path models: every result, its latency and busy equal the model."""
    await setup(dut)
    rng = random.Random(SEED + 1)
    n = clamp = 0
    for k, model in enumerate([cm.FISHEYE, cm.PANORAMIC, cm.PERSPECTIVE] * 4):
        c, w, h = calib(rng, model, extreme=(k >= 9))
        if k in (6, 7):                                           # strong coefficients: denominators <= 0
            c.k1, c.h31 = -4 * Q, -Q // 8
        apply(dut, c)
        for _ in range(NSLOW):
            await FallingEdge(dut.clk)
            x, y = point(rng, w, h)
            dut.in_valid.value, dut.in_x.value, dut.in_y.value = 1, x, y
            await FallingEdge(dut.clk)
            dut.in_valid.value = 0
            for j in range(1, cm.SLOW_LATENCY + 2):
                await Timer(1, unit="ns")
                if j <= cm.SLOW_LATENCY:
                    assert int(dut.busy.value) == 1 and int(dut.out_valid.value) == 0, \
                        f"model {model}: busy {dut.busy.value} out_valid {dut.out_valid.value} {j} clocks in"
                else:
                    assert int(dut.out_valid.value) == 1 and int(dut.busy.value) == 0, \
                        f"model {model}: no result {cm.SLOW_LATENCY} clocks after the request"
                    exp = cm.coord_gen(c, x, y)
                    got = (dut.out_sx_q16.value.to_signed(), dut.out_sy_q16.value.to_signed())
                    assert got == exp, f"model {model} ({x}, {y}) {c}: rtl {got} model {exp}"
                    n += 1
                await FallingEdge(dut.clk)
            await Timer(1, unit="ns")
            assert int(dut.out_valid.value) == 0, "out_valid longer than one clock"
        clamp += int(k in (6, 7))
    dut._log.info("coord_gen slow path: %d results compared", n)
