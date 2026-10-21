"""cocotb tests of symbol_overlay against its model (ip/video/symbol_overlay/model/symbol_overlay_model.py).

test_frames_exact: random register sets written over AXI4-Lite (objects of every shape and style, boxes
partly outside the frame or empty, labels, texts with the frame number, every scale, the 3 x 5 and the smooth
font, BLEND, ENABLE, FRAME_NUM), committed before random frames that stream with random input gaps and output
back-pressure; every output frame equals the model's pixel for pixel (and tuser / tlast). Some sets are
written without COMMIT (they must not apply) and frame sizes change (labels use the previous frame's size).
test_register_map: the ID block, every register's read-back, STATUS / FRAME_NUM against the model.
Environment: OVL_CASE (the parameter set the runner built), OVL_FRAMES (default 24), OVL_SEED."""
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
import symbol_overlay_model as sm                                # noqa: E402

FONT_DIR = str(IP / "src" / "include") + "/"
CASES = {"n4": dict(NOBJ=4, NTXT=4, CW=13), "n20": dict(NOBJ=20, NTXT=2, CW=12)}
CASE = os.environ.get("OVL_CASE", "n4")
P = CASES[CASE]
NOBJ, NTXT, CW = P["NOBJ"], P["NTXT"], P["CW"]
FRAMES = int(os.environ.get("OVL_FRAMES", "24"))
SEED = int(os.environ.get("OVL_SEED", "20261020"))
A_CTRL, A_COMMIT, A_STATUS, A_FNUM = 0x18, 0x1C, 0x20, 0x24
COV = collections.Counter()


def coverage(m, frame):
    """Pixels each feature of the model's active set draws in this frame (the comparison's coverage)."""
    a = m.active
    if not m.enabled or a is None:
        COV["frames_off"] += 1
        return
    h, w = frame.shape[:2]
    cm = (1 << CW) - 1
    for i in range(NOBJ):
        oc = sm.obj_key(a, "OBJ_CTRL", i)
        if not oc & 1:
            continue
        xv, yv = sm.obj_key(a, "OBJ_X", i), sm.obj_key(a, "OBJ_Y", i)
        box = (xv & cm, (xv >> 16) & cm, yv & cm, (yv >> 16) & cm)
        n = int(sm.symbol_mask(oc, box, w, h).sum())
        kind = "triangle" if oc & 128 else ["rect", "filled", "cross", "oval" if oc & 32 else "circle"][(oc >> 1) & 3]
        COV[f"{kind}{'_dashed' if oc & 8 else ''}"] += n
        COV["corners"] += n if (oc & (1 << 15)) and kind == "rect" else 0
        COV["ticks"] += n if (oc & 64) and kind == "rect" else 0
        COV["blend"] += n if oc & 16 else 0
        COV["labels"] += int(sm.obj_key(a, "OBJ_LABEL", i) != 0)
    ctrl = a["CTRL"]
    COV[f"label_scale{(ctrl >> 1) & 3}{'_aa' if ctrl & 8 else ''}"] += 1
    for j in range(NTXT):
        tc = a.get(("TXT_CTRL", j), 0)
        if tc & 1:
            COV[f"text_scale{(tc >> 1) & 3}{'_aa' if ctrl & 8 else ''}{'_fnum' if tc & 16 else ''}"] += 1


def obj_base(i):
    return 0x50 + 16 * i if i < 16 else 0x2A0 + 16 * (i - 16)


def lab_addr(i):
    return 0x260 + 4 * i if i < 16 else 0x3A0 + 4 * (i - 16)


async def reset(dut):
    dut.rst_n.value = 0
    dut.s_tvalid.value = 0
    dut.s_tdata.value = 0
    dut.s_tlast.value = 0
    dut.s_tuser.value = 0
    dut.m_tready.value = 0
    for _ in range(4):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1


class Bus:
    """Register writes to the RTL (AXI4-Lite) and the model together."""

    def __init__(self, dut, model):
        self.axi, self.m = AxilMaster(dut, dut.clk), model

    async def w(self, off, d):
        resp = await self.axi.write(off, d)
        assert resp == self.m.r.write(off, d), f"write 0x{off:03X}"


def rnd_obj(rng, w, h):
    """(OBJ_CTRL, OBJ_X, OBJ_Y, OBJ_COLOR, OBJ_LABEL) of a random object."""
    x0 = rng.randrange(-20, w + 10)
    y0 = rng.randrange(-10, h + 5)
    bw, bh = rng.choice([1, 2, 3, 5, 8, 13, 17, 24, 40]), rng.choice([1, 2, 3, 5, 8, 13, 17, 30])
    x0, y0 = max(0, x0), max(0, y0)
    x1, y1 = x0 + bw - 1, y0 + bh - 1
    if rng.random() < 0.05:
        x0, x1 = x1 + 3, x0                                  # an empty box
    shape = rng.randrange(4)
    ctrl = 1 | shape << 1 | rng.choice([0, 8]) | (16 if rng.random() < 0.15 else 0)
    ctrl |= (32 if rng.random() < 0.5 else 0) | (64 if rng.random() < 0.3 else 0)
    ctrl |= (128 if rng.random() < 0.2 else 0) | rng.randrange(5) << 8 | rng.randrange(8) << 12
    ctrl |= (1 << 15) if rng.random() < 0.4 else 0
    if rng.random() < 0.1:
        ctrl &= ~1                                           # disabled
    lab = 0
    if rng.random() < 0.6:
        chars = [rng.choice(b"PGAO") ] + [rng.randrange(0x30, 0x3A) for _ in range(rng.randrange(4))]
        if rng.random() < 0.1:
            chars = [rng.randrange(1, 256) for _ in range(4)]
        lab = int.from_bytes(bytes(chars).ljust(4, b"\0"), "little")
    col = rng.getrandbits(24)
    mask = (1 << CW) - 1
    return ctrl, (x1 & mask) << 16 | (x0 & mask), (y1 & mask) << 16 | (y0 & mask), col, lab


async def write_set(bus, rng, w, h, commit=True):
    sc = rng.randrange(4)
    await bus.w(A_CTRL, 1 | sc << 1 | (8 if rng.random() < 0.6 else 0))
    for i in range(NOBJ):
        ctrl, xv, yv, col, lab = rnd_obj(rng, w, h)
        b = obj_base(i)
        await bus.w(b, ctrl)
        await bus.w(b + 4, xv)
        await bus.w(b + 8, yv)
        await bus.w(b + 12, col)
        await bus.w(lab_addr(i), lab)
    for j in range(NTXT):
        tc = (1 if rng.random() < 0.8 else 0) | rng.randrange(4) << 1 | rng.choice([0, 8]) | rng.choice([0, 16])
        tc |= rng.randrange(18) << 8
        await bus.w(0x150 + 16 * j, tc)
        await bus.w(0x154 + 16 * j, rng.randrange(h) << 16 | (rng.randrange(-20, w) & 0xFFFF))
        await bus.w(0x158 + 16 * j, rng.getrandbits(24))
        for q in range(4):
            await bus.w(0x210 + 16 * j + 4 * q, int.from_bytes(bytes(rng.randrange(32, 127) for _ in range(4)), "little"))
    if rng.random() < 0.2:
        await bus.w(A_FNUM, rng.choice([0x00009, 0x00099, 0x99999, 0x01234]))
    if commit:
        await bus.w(A_COMMIT, 1)


async def stream(dut, rng, frame, gaps=True):
    """Send one frame [h, w, 3] and collect the output frame (with gaps / back-pressure)."""
    h, w = frame.shape[:2]
    beats = [(int(frame[y, x, 0]) | int(frame[y, x, 1]) << 8 | int(frame[y, x, 2]) << 16, x == w - 1,
              x == 0 and y == 0) for y in range(h) for x in range(w)]
    out, flags = [], []
    k = 0
    pin = 0.6 if gaps else 1.0
    pout = 0.7 if gaps else 1.0
    held = False                                              # tvalid stays high until the beat moves
    trace = []
    for cyc in range(50 * len(beats) + 20000):
        await FallingEdge(dut.clk)
        if k < len(beats) and (held or rng.random() < pin):
            d, last, user = beats[k]
            dut.s_tdata.value, dut.s_tlast.value, dut.s_tuser.value = d, int(last), int(user)
            dut.s_tvalid.value = 1
            held = True
        else:
            dut.s_tvalid.value = 0
        dut.m_tready.value = int(rng.random() < pout)
        await Timer(1, unit="ns")
        if dut.s_tvalid.value and dut.s_tready.value:
            if k < 3 or os.environ.get("OVL_TRACE"):
                trace.append(("in", k, cyc))
            k += 1
            held = False
        if dut.m_tvalid.value and dut.m_tready.value:
            if len(out) < 3:
                trace.append(("out", len(out), cyc, int(dut.m_tlast.value), int(dut.m_tuser.value)))
            out.append(int(dut.m_tdata.value))
            flags.append((int(dut.m_tlast.value), int(dut.m_tuser.value)))
            if len(out) == len(beats):
                break
    await FallingEdge(dut.clk)                               # the last handshake is at the edge before
    dut.s_tvalid.value = 0
    dut.m_tready.value = 0
    assert len(out) == len(beats), f"output: {len(out)} of {len(beats)} beats"
    exp_flags = [(int(b[1]), int(b[2])) for b in beats]
    if flags != exp_flags:
        i = next(i for i, (a, b) in enumerate(zip(flags, exp_flags)) if a != b)
        raise AssertionError(f"tlast / tuser differ at beat {i} (x {i % w} y {i // w}): rtl {flags[i]} "
                             f"expected {exp_flags[i]}; trace {trace[:8]}")
    o = np.array(out, np.int64)
    return np.stack([o & 0xFF, (o >> 8) & 0xFF, (o >> 16) & 0xFF], axis=-1).astype(np.uint8).reshape(h, w, 3)


@cocotb.test()
async def test_frames_exact(dut):
    """Random sets and frames: every output frame equals the model's."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED)
    nrng = np.random.default_rng(SEED)
    m = sm.SymbolOverlay(NOBJ, NTXT, CW)
    bus = Bus(dut, m)
    sizes = [(96, 64), (128, 48), (72, 80)]
    w, h = sizes[0]
    for f in range(FRAMES):
        if f % 8 == 7:
            w, h = rng.choice(sizes)
        x = rng.random()
        if x < 0.75:
            await write_set(bus, rng, w, h, commit=rng.random() < 0.9)
        elif x < 0.8:
            await bus.w(A_CTRL, rng.randrange(16))           # ENABLE (and a LABEL_SCALE / FONT not committed)
        frame = nrng.integers(0, 256, (h, w, 3), dtype=np.uint8)
        m.frame_start()
        exp = m.draw(frame)
        coverage(m, frame)
        COV["changed_pixels"] += int((exp != frame).any(-1).sum())
        got = await stream(dut, rng, frame, gaps=f % 3 != 2)
        if not np.array_equal(got, exp):
            ys, xs = np.nonzero((got != exp).any(-1))
            k = 0
            px, py = xs[k], ys[k]
            for name, its in zip(("label", "text"), m.last_items):
                for idx, it in enumerate(its):
                    if it is not None:
                        chars, ix, iy, isc, col, bd = it
                        if ix <= px < ix + 4 * isc * len(chars) and iy <= py < iy + 6 * isc:
                            dut._log.error("model %s %d covers it: %s at %d,%d scale %d backdrop %s", name, idx,
                                           bytes(chars), ix, iy, isc, bd)
            dut._log.error("model CTRL %x", m.active["CTRL"])
            dut._log.error("differing rows %s columns %s..%s", sorted(set(ys.tolist()))[:20], xs.min(), xs.max())
            for q in range(min(6, len(ys))):
                dut._log.error("  x %d y %d rtl %s model %s in %s", xs[q], ys[q], got[ys[q], xs[q]].tolist(),
                               exp[ys[q], xs[q]].tolist(), frame[ys[q], xs[q]].tolist())
            core = dut.u_top.u_core
            for idx, it in enumerate(m.last_items[1]):
                rx, ry = int(core.t_x[idx].value), int(core.t_y[idx].value)
                dut._log.error("text %d model %s rtl x %d y %d ctrl %x n %d xe %d ye %d", idx,
                               None if it is None else (it[1], it[2], it[3], len(it[0])), rx, ry,
                               int(core.t_ctrl[idx].value), int(core.txt_n[idx].value),
                               core.txt_xe[idx].value.to_signed(), core.txt_ye[idx].value.to_signed())
            for idx, it in enumerate(m.last_items[0]):
                if it is not None:
                    dut._log.error("label %d model %s rtl x %d y %d n %d", idx, (it[1], it[2], it[3], len(it[0])),
                                   core.lab_x[idx].value.to_signed(), core.lab_y[idx].value.to_signed(),
                                   int(core.lab_n[idx].value))
            raise AssertionError(f"frame {f} ({w} x {h}): {len(ys)} pixels differ, first at x {xs[k]} y {ys[k]}: "
                                 f"rtl {got[ys[k], xs[k]].tolist()} model {exp[ys[k], xs[k]].tolist()} "
                                 f"input {frame[ys[k], xs[k]].tolist()}")
        st, _ = await bus.axi.read(A_STATUS)
        assert (st, 0) == m.r.read(A_STATUS), f"frame {f}: STATUS rtl {st:x} model {m.r.read(A_STATUS)[0]:x}"
        fn, _ = await bus.axi.read(A_FNUM)
        assert (fn, 0) == m.r.read(A_FNUM), f"frame {f}: FRAME_NUM rtl {fn:x}"
    dut._log.info("frames: %d compared (%s), coverage %s", FRAMES, CASE, dict(sorted(COV.items())))
    need = ["rect", "rect_dashed", "filled", "cross", "circle", "oval", "triangle", "triangle_dashed",
            "circle_dashed", "oval_dashed", "corners", "ticks", "blend", "labels", "changed_pixels"]
    if FRAMES >= 20:
        missing = [k for k in need if not COV[k]]
        assert not missing, f"not covered: {missing}"


@cocotb.test()
async def test_register_map(dut):
    """The ID block and every register's read-back against the model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED + 1)
    m = sm.SymbolOverlay(NOBJ, NTXT, CW)
    axi = AxilMaster(dut, dut.clk)
    offs = sorted(set(m.r.regs) | {0x0, 0x4, 0x8, 0xC, 0x10, 0x3FC})
    for off in offs:
        d, resp = await axi.read(off)
        assert (d, resp) == m.r.read(off), f"reset 0x{off:03X}: rtl {d:x}/{resp} model {m.r.read(off)}"
    for _ in range(300):
        off = rng.choice(offs)
        if rng.random() < 0.5:
            d = rng.getrandbits(32)
            if off == A_COMMIT:
                d &= ~1                                      # no commit (no frames run here)
            assert await axi.write(off, d) == m.r.write(off, d), f"write 0x{off:03X}"
        else:
            d, resp = await axi.read(off)
            assert (d, resp) == m.r.read(off), f"read 0x{off:03X}: rtl {d:x}/{resp} model {m.r.read(off)}"
    for _ in range(2):
        await FallingEdge(dut.clk)
    dut._log.info("register map: compared")
