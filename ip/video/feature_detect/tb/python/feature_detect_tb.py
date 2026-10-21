"""cocotb tests of feature_detect against its model (ip/video/feature_detect/model/feature_detect_model.py).

test_frames_exact: frames of textured shapes that move and of whole-frame shifts by whole cells (motion, the
camera shift search, AUTO_SHIFT and manual SHIFT), streamed with random gaps (the tap sees tvalid & tready);
random configurations taken at frame starts (EN, EDGE / MOTION thresholds and spans, RATE, SKY_CFG), restarts
(CTRL.RESTART, FRAME_SIZE writes with a new size). Every forwarded beat equals the input beat in order, with the
model's edge / motion bits of that pixel; after every frame (done_o) FRAMES, EDGE_COUNT, MOTION_COUNT,
SHIFT_EST, SHIFT_USED, STATUS and SKY[0..31] equal the model's.
test_register_map: the ID block and every register's read-back against the model.
Environment: FEAT_CASE (the parameter set the runner built), FEAT_FRAMES (default 40), FEAT_SEED."""
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

model_path(IP / "model")
import feature_detect_model as fm                                # noqa: E402

CASES = {"c4": dict(MAXW=256, MAXH=128, CELL_LOG2=2, SHIFT_MAX=4),
         "c8": dict(MAXW=256, MAXH=128, CELL_LOG2=3, SHIFT_MAX=2)}
CASE = os.environ.get("FEAT_CASE", "c4")
P = CASES[CASE]
FRAMES = int(os.environ.get("FEAT_FRAMES", "40"))
SEED = int(os.environ.get("FEAT_SEED", "20261021"))
A = dict(CTRL=0x18, FRAME_SIZE=0x1C, EDGE=0x20, MOTION=0x24, SHIFT=0x28, SHIFT_EST=0x2C, STATUS=0x30,
         FRAMES=0x34, EDGE_COUNT=0x38, MOTION_COUNT=0x3C, SHIFT_USED=0x40, SKY_CFG=0x44, SKY=0x80)
COV = collections.Counter()


async def reset(dut):
    dut.rst_n.value = 0
    for n in ("s_tvalid", "s_tready", "s_tdata", "s_tlast", "s_tuser"):
        getattr(dut, n).value = 0
    for _ in range(4):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1


class Scene:
    """Frames: a textured background shifted by whole cells (the camera) with textured blobs moving on it."""

    def __init__(self, rng, nrng, w, h, cell):
        self.rng, self.nrng, self.w, self.h, self.cell = rng, nrng, w, h, cell
        self.bg = nrng.integers(0, 256, (h + 64, w + 64, 3), dtype=np.uint8)
        self.bg = ((self.bg.astype(np.int32) + np.roll(self.bg, 1, 0) + np.roll(self.bg, 1, 1)) // 3).astype(np.uint8)
        self.ox = self.oy = 32
        self.blobs = [[rng.randrange(w), rng.randrange(h), rng.randrange(4, 14), rng.randrange(-3, 4),
                       rng.randrange(-2, 3), rng.getrandbits(24)] for _ in range(3)]
        self.sky_rows = rng.randrange(0, h // 2)

    def frame(self):
        if self.rng.random() < 0.4:                              # the camera moves by whole cells
            self.ox += self.cell * self.rng.randrange(-2, 3)
            self.oy += self.cell * self.rng.randrange(-1, 2)
            self.ox, self.oy = min(max(self.ox, 0), 64), min(max(self.oy, 0), 64)
        f = self.bg[self.oy:self.oy + self.h, self.ox:self.ox + self.w].copy()
        f[:self.sky_rows] = 200 + (self.nrng.integers(0, 8, (self.sky_rows, self.w, 1)) if self.sky_rows else 0)
        for b in self.blobs:
            b[0] = (b[0] + b[3]) % self.w
            b[1] = (b[1] + b[4]) % self.h
            x0, y0, s = b[0], b[1], b[2]
            col = np.array([b[5] & 255, (b[5] >> 8) & 255, (b[5] >> 16) & 255], np.int32)
            patch = (self.nrng.integers(-40, 40, (s, s, 3)) + col).clip(0, 255).astype(np.uint8)
            f[y0:y0 + s, x0:x0 + s] = patch[:min(s, self.h - y0), :min(s, self.w - x0)]
        return f


async def stream(dut, rng, frame, gap):
    """One frame on the tap (random gaps); returns the forwarded beats [(data, last, user, feat)]."""
    h, w = frame.shape[:2]
    beats = [(int(frame[y, x, 0]) | int(frame[y, x, 1]) << 8 | int(frame[y, x, 2]) << 16, int(x == w - 1),
              int(x == 0 and y == 0)) for y in range(h) for x in range(w)]
    out = []
    k = 0
    for _ in range(20 * len(beats) + 2000):
        await FallingEdge(dut.clk)
        if k < len(beats):
            d, last, user = beats[k]
            dut.s_tdata.value, dut.s_tlast.value, dut.s_tuser.value = d, last, user
            dut.s_tvalid.value = int(rng.random() >= gap)
            dut.s_tready.value = int(rng.random() >= gap / 2)
        else:
            dut.s_tvalid.value = 0
        await Timer(1, unit="ns")
        if dut.s_tvalid.value and dut.s_tready.value:
            k += 1
        if dut.m_tvalid.value:
            out.append((int(dut.m_tdata.value), int(dut.m_tlast.value), int(dut.m_tuser.value),
                        int(dut.feat_o.value)))
        if len(out) == len(beats):
            break
    dut.s_tvalid.value = 0
    assert len(out) == len(beats), f"forwarded {len(out)} of {len(beats)} beats"
    return beats, out


async def wait_done(dut, n=20000):
    for _ in range(n):
        await FallingEdge(dut.clk)
        if dut.done_o.value:
            break
    for _ in range(4):
        await FallingEdge(dut.clk)


@cocotb.test()
async def test_frames_exact(dut):
    """Frames with motion and camera shifts: every pixel's bits and every register equal the model's."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED)
    nrng = np.random.default_rng(SEED)
    cell = 1 << P["CELL_LOG2"]
    m = fm.FeatureDetect(P["CELL_LOG2"], P["SHIFT_MAX"])
    axi = AxilMaster(dut, dut.clk)

    async def w(name, d):
        assert await axi.write(A[name], d) == m.r.write(A[name], d), f"write {name}"

    sizes = [(96, 64), (128, 72), (80, 96)]
    wd, ht = sizes[0]
    await w("FRAME_SIZE", ht << 16 | wd)
    scene = Scene(rng, nrng, wd, ht, cell)
    ctrl = 0x0F
    for f in range(FRAMES):
        if f and f % 13 == 0:                                     # a new size: FRAME_SIZE (a restart)
            wd, ht = rng.choice(sizes)
            await w("FRAME_SIZE", ht << 16 | wd)
            scene = Scene(rng, nrng, wd, ht, cell)
        if f % 4 == 0 or f < 2:
            ctrl = 1 | rng.choice([2, 0, 2]) | rng.choice([4, 4, 0]) | rng.choice([8, 8, 0])
            if rng.random() < 0.08:
                ctrl &= ~1                                        # a frame not processed
            await w("EDGE", rng.randrange(20, 400) | rng.randrange(0, 6) << 16)
            await w("MOTION", rng.randrange(0, 40) | rng.randrange(0, 5) << 8 | rng.randrange(0, 4) << 12)
            await w("SKY_CFG", rng.randrange(1, 6) | rng.randrange(0, 200) << 8)
            await w("SHIFT", (rng.randrange(-3, 4) & 0xFF) | (rng.randrange(-2, 3) & 0xFF) << 8)
            await w("CTRL", ctrl | (16 if rng.random() < 0.1 else 0))
        frame = scene.frame()
        e, mo = m.step(frame)
        beats, out = await stream(dut, rng, frame, gap=0.0 if f % 3 == 2 else 0.3)
        for k, (b, o) in enumerate(zip(beats, out)):
            exp = int(e.flat[k]) | int(mo.flat[k]) << 1
            if o[:3] != b or o[3] != exp:
                raise AssertionError(f"frame {f} beat {k} (x {k % wd} y {k // wd}): rtl {o} expected "
                                     f"{b} feat {exp}")
        COV["edge_px"] += int(e.sum())
        COV["motion_px"] += int(mo.sum())
        await wait_done(dut)
        for name in ("FRAMES", "EDGE_COUNT", "MOTION_COUNT", "SHIFT_EST", "SHIFT_USED", "STATUS"):
            d, _ = await axi.read(A[name])
            md, _ = m.r.read(A[name])
            assert d == md, f"frame {f}: {name} rtl {d:#x} model {md:#x}"
        for i in range(32):
            d, _ = await axi.read(A["SKY"] + 4 * i)
            assert d == m.r.read(A["SKY"] + 4 * i)[0], f"frame {f}: SKY[{i}] rtl {d} model {m.sky[i]}"
        COV[f"shift_est_{m.shift_est != (0, 0)}"] += 1
        COV[f"shift_used_{m.shift_used != (0, 0)}"] += 1
        COV["sky_partial"] += int(any(0 < s < ht for s in m.sky))
    dut._log.info("frames: %d compared (%s), coverage %s", FRAMES, CASE, dict(COV))
    if FRAMES >= 30:
        for k in ("edge_px", "motion_px", "shift_est_True", "shift_used_True", "sky_partial"):
            assert COV[k], f"not covered: {k}"


@cocotb.test()
async def test_register_map(dut):
    """The ID block and every register's read-back against the model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED + 1)
    m = fm.FeatureDetect(P["CELL_LOG2"], P["SHIFT_MAX"])
    axi = AxilMaster(dut, dut.clk)
    offs = sorted(set(m.r.regs) | {0x0, 0x4, 0x8, 0xC, 0x10, 0x48, 0xFC})
    for off in offs:
        d, resp = await axi.read(off)
        assert (d, resp) == m.r.read(off), f"reset 0x{off:02X}: rtl {d:x}/{resp} model {m.r.read(off)}"
    for _ in range(300):
        off = rng.choice(offs)
        if rng.random() < 0.5:
            d = rng.getrandbits(32)
            assert await axi.write(off, d) == m.r.write(off, d), f"write 0x{off:02X}"
        else:
            d, resp = await axi.read(off)
            assert (d, resp) == m.r.read(off), f"read 0x{off:02X}: rtl {d:x}/{resp} model {m.r.read(off)}"
    for _ in range(2):
        await FallingEdge(dut.clk)
