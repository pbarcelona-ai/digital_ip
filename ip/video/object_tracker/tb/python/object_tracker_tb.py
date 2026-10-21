"""cocotb tests of object_tracker against its model (ip/video/object_tracker/model/object_tracker_model.py).

test_frames_exact: frames of coloured shapes (skin-like, saturated, dark and bright patches, thin lines) on a
noisy scene, with random edge / motion bits on feat_i, streamed with random gaps (the tap sees tvalid & tready);
random configurations written between frames: luma mode (both polarities), colour ranges, the SKIN_LUT table,
FEAT_A 0-3, TERM_B with RUN_B, RUN / MIN_RUN widths, search windows (whole frame, partial, outside), BLOB_CFG,
frames not processed (CTRL.EN 0: no done_o, nothing changes), pairs of frames back to back (the second frame
starts while the first one's last pixels are still in the pipeline). After every frame or pair (done_o) every
result register equals the model's: FRAMES, COUNT, BOX_X / BOX_Y, SUM_X / SUM_Y, STATUS, BLOB_X / BLOB_Y / BLOB_N.
test_register_map: the ID block and every register's read-back against the model.
Environment: OTRK_CASE (the parameter set the runner built), OTRK_FRAMES (default 60), OTRK_SEED."""
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
import object_tracker_model as om                                # noqa: E402

CASES = {"b8": dict(NBLOB=8)}
CASE = os.environ.get("OTRK_CASE", "b8")
FRAMES = int(os.environ.get("OTRK_FRAMES", "60"))
SEED = int(os.environ.get("OTRK_SEED", "20261021"))
A = dict(CTRL=0x18, FRAME_SIZE=0x1C, THRESH=0x20, WIN_X=0x24, WIN_Y=0x28, FRAMES=0x2C, COUNT=0x30, BOX_X=0x34,
         BOX_Y=0x38, SUM_X=0x3C, SUM_Y=0x40, STATUS=0x44, RUN=0x48, Y_RANGE=0x4C, CB_RANGE=0x50, CR_RANGE=0x54,
         SAT_MIN=0x58, BLOB_CFG=0x5C, RUN_B=0xD0, BLOB_X=0x100, BLOB_Y=0x120, BLOB_N=0x140, SKIN_LUT=0x160)
RESULTS = ("FRAMES", "COUNT", "BOX_X", "BOX_Y", "SUM_X", "SUM_Y", "STATUS")
COV = collections.Counter()


async def reset(dut):
    dut.rst_n.value = 0
    for n in ("s_tvalid", "s_tready", "s_tdata", "s_tlast", "s_tuser", "feat_i"):
        getattr(dut, n).value = 0
    for _ in range(4):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1


def scene(rng, nrng, w, h):
    f = nrng.integers(60, 140, (h, w, 3), dtype=np.uint8)
    for _ in range(rng.randrange(3, 9)):
        x0, y0 = rng.randrange(w), rng.randrange(h)
        bw, bh = rng.choice([1, 2, 3, 6, 10, 16, 30]), rng.choice([1, 2, 4, 8, 12, 20])
        col = rng.choice([(200, 150, 120), (220, 40, 40), (30, 30, 30), (240, 240, 240), (60, 200, 60),
                          (rng.randrange(256), rng.randrange(256), rng.randrange(256))])
        noise = nrng.integers(-12, 13, (min(bh, h - y0), min(bw, w - x0), 3))
        f[y0:y0 + bh, x0:x0 + bw] = (np.array(col) + noise).clip(0, 255).astype(np.uint8)
    edge = nrng.random((h, w)) < rng.choice([0.0, 0.05, 0.3])
    mot = nrng.random((h, w)) < rng.choice([0.0, 0.05, 0.3])
    if rng.random() < 0.5:                                        # motion / edges in runs
        edge |= np.roll(edge, 1, 1) | np.roll(edge, 2, 1)
        mot |= np.roll(mot, 1, 1)
    return f, edge, mot


async def stream(dut, rng, frames, gap, en=True):
    """Frames [(rgb, edge, motion)] back to back on the tap (random gaps); counts done_o, one per frame when the
    frames are processed (CTRL.EN), none otherwise."""
    beats = []
    for frame, edge, mot in frames:
        h, w = frame.shape[:2]
        beats += [(int(frame[y, x, 0]) | int(frame[y, x, 1]) << 8 | int(frame[y, x, 2]) << 16, int(x == w - 1),
                   int(x == 0 and y == 0), int(edge[y, x]) | int(mot[y, x]) << 1) for y in range(h) for x in range(w)]
    want = len(frames) if en else 0
    k = dones = 0
    for _ in range(20 * len(beats) + 2000):
        await FallingEdge(dut.clk)
        if k < len(beats):
            d, last, user, ft = beats[k]
            dut.s_tdata.value, dut.s_tlast.value, dut.s_tuser.value, dut.feat_i.value = d, last, user, ft
            dut.s_tvalid.value = int(rng.random() >= gap)
            dut.s_tready.value = int(rng.random() >= gap / 2)
        else:
            dut.s_tvalid.value = 0
        await Timer(1, unit="ns")
        if dut.s_tvalid.value and dut.s_tready.value:
            k += 1
        dones += int(dut.done_o.value)
        if k == len(beats) and dones == want:
            break
    dut.s_tvalid.value = 0
    for _ in range(8):                                            # no further done_o
        await FallingEdge(dut.clk)
        await Timer(1, unit="ns")
        dones += int(dut.done_o.value)
    assert k == len(beats) and dones == want, \
        f"frames not finished: {k} of {len(beats)} beats, done_o {dones} of {want}"


@cocotb.test()
async def test_frames_exact(dut):
    """Random scenes and configurations: every result register equals the model's after every frame."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED)
    nrng = np.random.default_rng(SEED)
    m = om.ObjectTracker()
    axi = AxilMaster(dut, dut.clk)

    async def w(name, d, i=0):
        assert await axi.write(A[name] + 4 * i, d) == m.r.write(A[name] + 4 * i, d), f"write {name}"

    wd, ht = 80, 48
    await w("FRAME_SIZE", ht << 16 | wd)
    for i in range(32):
        await w("SKIN_LUT", rng.getrandbits(32), i)
    for f in range(FRAMES):
        if f % 2 == 0:
            ctrl = 1 | rng.choice([0, 2]) | rng.choice([0, 4]) | rng.randrange(0, 4) << 8 | rng.randrange(4) << 12
            ctrl |= (1 << 14) if rng.random() < 0.4 else 0
            ctrl |= (1 << 15) if ctrl & 4 and rng.random() < 0.4 else 0
            if rng.random() < 0.05 or f == 10:
                ctrl &= ~1
            await w("CTRL", ctrl)
            await w("THRESH", rng.randrange(256))
            await w("RUN", rng.choice([0, 1, 2, 3, 5]) | rng.choice([0, 0, 4, 12, 40]) << 16)
            await w("RUN_B", rng.choice([0, 2, 3]) | rng.choice([0, 6, 20]) << 16)
            await w("Y_RANGE", rng.randrange(0, 100) | rng.randrange(150, 256) << 8)
            await w("CB_RANGE", rng.randrange(60, 128) | rng.randrange(128, 200) << 8)
            await w("CR_RANGE", rng.randrange(60, 128) | rng.randrange(128, 220) << 8)
            await w("SAT_MIN", rng.randrange(0, 60))
            await w("BLOB_CFG", rng.randrange(0, 6) | rng.randrange(0, 4) << 8 | rng.choice([0, 1, 5, 20]) << 16)
        win = rng.choice(["full", "part", "part", "out"])
        if win == "full":
            wx, wy = (wd - 1 + rng.randrange(3)) << 16, (ht - 1 + rng.randrange(3)) << 16
        elif win == "part":
            x0, y0 = rng.randrange(wd), rng.randrange(ht)
            wx, wy = (x0 + rng.randrange(40)) << 16 | x0, (y0 + rng.randrange(30)) << 16 | y0
        else:
            wx, wy = 20 << 16 | 30, 5 << 16 | 2                   # empty: x0 > x1
        await w("WIN_X", wx)
        await w("WIN_Y", wy)
        frames = [scene(rng, nrng, wd, ht) for _ in range(2 if f % 7 == 6 else 1)]   # sometimes back to back
        for frame, edge, mot in frames:
            m.measure(frame, edge, mot)
        await stream(dut, rng, frames, gap=0.0 if f % 3 == 2 else 0.3, en=bool(ctrl & 1))
        COV["back_to_back"] += int(len(frames) == 2 and bool(ctrl & 1))
        COV["disabled"] += int(not ctrl & 1)
        for _ in range(3):
            await FallingEdge(dut.clk)
        for name in RESULTS:
            d, _ = await axi.read(A[name])
            md, _ = m.r.read(A[name])
            assert d == md, f"frame {f}: {name} rtl {d:#x} model {md:#x}"
        for i in range(om.NBLOB):
            for name in ("BLOB_X", "BLOB_Y", "BLOB_N"):
                d, _ = await axi.read(A[name] + 4 * i)
                md, _ = m.r.read(A[name] + 4 * i)
                assert d == md, f"frame {f}: {name}[{i}] rtl {d:#x} model {md:#x}"
        COV["found"] += int(m.res["n"] > 0)
        COV["blobs"] += sum(1 for b in m.blobs if b[4])
        COV["lost"] += int(m.res["lost"] > 0)
        COV[f"ctrl_{'skin' if ctrl & 0x8004 == 0x8004 else 'col' if ctrl & 4 else 'luma'}"] += 1
        COV["term_b"] += int(bool(ctrl & 0x4000))
    dut._log.info("frames: %d compared, coverage %s", FRAMES, dict(COV))
    if FRAMES >= 40:
        for k in ("found", "blobs", "lost", "ctrl_skin", "ctrl_col", "ctrl_luma", "term_b", "disabled", "back_to_back"):
            assert COV[k], f"not covered: {k}"


@cocotb.test()
async def test_register_map(dut):
    """The ID block and every register's read-back against the model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED + 1)
    m = om.ObjectTracker()
    axi = AxilMaster(dut, dut.clk)
    offs = sorted(set(m.r.regs) | {0x0, 0x4, 0x8, 0xC, 0x10, 0xD4, 0x1FC})
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
