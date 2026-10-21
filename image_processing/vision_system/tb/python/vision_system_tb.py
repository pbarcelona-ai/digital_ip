"""cocotb test of vision_system against its model (image_processing/vision_system/model/vision_system_model.py).

test_frames_exact: groups of RGB frames (noise, gradients, edges; 1 x 1 up to 40 x 24, and the sizes of
out-of-range IMG_WIDTH / IMG_HEIGHT values: 0 counts as 1, past MAX clamps to MAX) streamed back to back with
random input gaps and output back-pressure; between groups (the core idle) a configuration written through
AXI4-Lite to the RTL and the model, then the reciprocal unit awaited (STATUS[2]): BYPASS on / off, every
MODEL_SEL (radial with barrel / pincushion and tangential terms and with full-range coefficients that saturate,
fisheye, panoramic, perspective, the affine / scaling codes), CALIB_MODE 0 (CENTER / SCALE) and 1
(FX / FY / CX / CY), bilinear and bicubic. Every output beat (data, tlast, tuser) equals the model's frames, in
order, and as many beats come out as go in; STATUS frame done is set after a corrected frame and cleared by
writing 1.
test_soft_reset: CTRL[0] in the middle of a frame (input part sent, output partly read), then beats outside a
frame (consumed, nothing out), then frames equal to the model; the registers keep their values.
test_register_map: the ID block and every register's reset value and read-back.
Cases: a12 (on-chip store, FB_DEPTH 4096), ext (SDRAM store with a behavioural SDRAM responder).
Environment: VS_CASE (the case the runner built), VS_GROUPS (default 16), VS_SEED, VS_TRACE (log the store's
ports and the sequencing every clock)."""
from __future__ import annotations

import collections
import json
import os
import random
import sys
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

VS = Path(__file__).resolve().parents[2]
LIB = VS.parents[1] / "ip" / "shared" / "tb" / "python"
sys.path.insert(0, str(LIB))
from cocotb_lib import AxilMaster, frame_beats, model_path, run_frames    # noqa: E402

model_path(VS / "model", *sorted((VS / "ip").glob("*/model")))
import vision_system_model as vm                                          # noqa: E402

CASES = {"a12": dict(ADDR_W=12, FB_DEPTH=4096, USE_EXT_FB=0), "ext": dict(ADDR_W=12, FB_DEPTH=4096, USE_EXT_FB=1)}
CASE = os.environ.get("VS_CASE", "a12")
EXT = CASES[CASE]["USE_EXT_FB"]
LIMIT = 3000 if EXT else 400                                    # clocks per beat before a stall is reported
GROUPS = int(os.environ.get("VS_GROUPS", "16"))
SEED = int(os.environ.get("VS_SEED", "20261021"))
Q = 1 << 16
COV = collections.Counter()


def offsets():
    """Register offsets by name, from the register map's JSON."""
    with open(VS / "src" / "include" / "vision_system_regs.json", encoding="utf-8") as fh:
        return {r["name"]: int(r["offset"], 16) for r in json.load(fh)["registers"]}


def pack(p):
    """An RGB pixel as tdata: {B, G, R}, R in the LSBs."""
    return int(p[0]) | int(p[1]) << 8 | int(p[2]) << 16


async def recip_idle(axi, off, what):
    """Wait for STATUS[2] (the reciprocal unit) to clear."""
    for _ in range(2000):
        if not (await axi.read(off["STATUS"]))[0] & 4:
            return
    raise AssertionError(f"{what}: STATUS reciprocal busy stuck")


def image(rng, nrng, w, h):
    """A test frame (h x w x 3): noise, gradients or a checker of edges."""
    kind = rng.choice(["noise", "grad", "edges"])
    COV[f"img_{kind}"] += 1
    if kind == "noise":
        return nrng.integers(0, 256, (h, w, 3)).astype(np.uint8)
    yy, xx = np.mgrid[0:h, 0:w]
    if kind == "grad":
        return np.stack([xx * 255 // max(w - 1, 1), yy * 255 // max(h - 1, 1), (xx + yy) * 7 % 256], -1).astype(np.uint8)
    return (np.where(((xx // 3 + yy // 2) & 1)[..., None], 230, 20) + np.zeros((h, w, 3), int)).astype(np.uint8)


def config(rng, g, w, h):
    """Register writes [(name, value)] of group g."""
    model = [0, 0, 1, 5, 3, 2, 4][g % 7] if g >= 2 else 0
    regs = [("IMG_WIDTH", w), ("IMG_HEIGHT", h), ("BYPASS", int(g == 0 or rng.random() < 0.15)),
            ("INTERP_MODE", rng.randrange(2) if g >= 2 else g & 1), ("MODEL_SEL", model)]
    extreme = rng.random() < 0.2
    for n in ("K1", "K2", "K3", "P1", "P2"):
        v = rng.randrange(-(1 << 31), 1 << 31) if extreme else int(rng.uniform(-0.3, 0.3) * Q * (0.2 if n[0] == "P" else 1))
        regs.append((n, v & 0xFFFFFFFF))
    if rng.random() < 0.5:
        regs += [("CALIB_MODE", 0), ("CENTER_X", rng.choice([0x8000, rng.randrange(0x4000, 0xC000)])),
                 ("CENTER_Y", rng.choice([0x8000, rng.randrange(0x4000, 0xC000)])),
                 ("SCALE", rng.choice([Q, int(0.8 * Q), int(1.25 * Q)]))]
    else:
        fx, fy = rng.choice([w / 2, 8.0, w * 0.6]), rng.choice([h / 2, 4.0, h * 0.7])
        regs += [("CALIB_MODE", 1), ("FX", int(fx * Q)), ("FY", int(fy * Q)), ("CX", int(w / 2 * Q) + rng.randrange(-Q, Q)),
                 ("CY", int(h / 2 * Q) + rng.randrange(-Q, Q))]
    hom = dict(H11=int(rng.uniform(0.9, 1.1) * Q), H12=int(rng.uniform(-0.1, 0.1) * Q), H13=rng.randrange(-2 * Q, 2 * Q),
               H21=int(rng.uniform(-0.1, 0.1) * Q), H22=int(rng.uniform(0.9, 1.1) * Q), H23=rng.randrange(-2 * Q, 2 * Q),
               H31=int(rng.uniform(-2e-3, 2e-3) * Q), H32=int(rng.uniform(-2e-3, 2e-3) * Q))
    regs += [(n, v & 0xFFFFFFFF) for n, v in hom.items()]
    COV[f"model{model}"] += 1
    return regs


async def sdram(dut):
    """USE_EXT_FB: the SDRAM, as ext_frame_buffer_tb's responder - the command sampled every clock, a READ's word
    on tb_dq from the next clock on (the controller samples it CAS_LATENCY later), a WRITE's word taken from the
    bus."""
    mem, row = {}, 0
    while True:
        await FallingEdge(dut.clk)
        await Timer(2, unit="ns")
        if int(dut.sdram_cs_n.value):
            continue
        cmd = (int(dut.sdram_ras_n.value), int(dut.sdram_cas_n.value), int(dut.sdram_we_n.value))
        a = int(dut.sdram_a.value)
        if cmd == (0, 1, 1):
            row = a
        elif cmd == (1, 0, 0):
            mem[(row, a & 0x3FF)] = int(dut.dq_seen.value)
        elif cmd == (1, 0, 1):
            dut.tb_dq.value = mem.get((row, a & 0x3FF), 0)


async def setup(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.tb_dq.value = 0
    if EXT:
        cocotb.start_soon(sdram(dut))
    dut.rst_n.value = 0
    for s in ("s_tvalid", "s_tdata", "s_tlast", "s_tuser", "m_tready"):
        getattr(dut, s).value = 0
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1


def trace(dut):
    """VS_TRACE: the store's ports and the sequencing, every clock with activity."""
    u = dut.u_dut
    ev = []
    if u.fb_wr_en.value:
        ev.append(f"wr {int(u.fb_wr_addr.value)}={int(u.fb_wr_data.value):#x}")
    if u.fb_rd_en.value:
        ev.append(f"rd {int(u.fb_rd_addr0.value)},{int(u.fb_rd_addr1.value)},{int(u.fb_rd_addr2.value)},"
                  f"{int(u.fb_rd_addr3.value)}")
    if u.start_output.value or u.frame_out_done.value or u.frame_done_in.value:
        ev.append(f"start {int(u.start_output.value)} in_done {int(u.frame_done_in.value)} out_done "
                  f"{int(u.frame_out_done.value)}")
    if dut.m_tvalid.value and dut.m_tready.value:
        ev.append(f"out {int(dut.m_tdata.value):#x}")
    if ev:
        dut._log.info("tstate %d: %s", int(u.tstate.value), "; ".join(ev))


@cocotb.test()
async def test_frames_exact(dut):
    """Groups of frames under random configurations: every output beat equals the model."""
    await setup(dut)
    rng = random.Random(SEED)
    nrng = np.random.default_rng(SEED)
    off = offsets()
    m = vm.VisionSystem()
    axi = AxilMaster(dut, dut.clk)

    async def w(name, d):
        assert await axi.write(off[name], d) == m.r.write(off[name], d), f"write {name}"
    frames = 0
    for g in range(GROUPS):
        w_, h_ = rng.choice([(1, 1), (2, 1), (1, 3), (5, 4), (rng.randrange(1, 41), rng.randrange(1, 25)),
                             (40, 24), (rng.randrange(8, 33), rng.randrange(6, 20)),
                             (rng.randrange(16, 41), rng.randrange(12, 25))])
        regs = config(rng, g, w_, h_)
        if g % 9 == 4:                                            # sizes outside 1..MAX: clamped (0 -> 1)
            regs[0:2] = rng.choice([[("IMG_WIDTH", 0), ("IMG_HEIGHT", rng.randrange(1, 6))],
                                    [("IMG_WIDTH", rng.randrange(1, 9)), ("IMG_HEIGHT", 0)],
                                    [("IMG_WIDTH", rng.choice([721, 0x10000, 0xFFFFFFFF])), ("IMG_HEIGHT", 1)],
                                    [("IMG_WIDTH", 3), ("IMG_HEIGHT", 0x80000005)]])
            COV["size_clamped"] += 1
        for n, v in regs:
            await w(n, v)
        w_, h_ = vm.frame_size(m.r)
        if w_ * h_ > CASES[CASE]["FB_DEPTH"]:                     # the store holds the frame (header contract)
            h_ = CASES[CASE]["FB_DEPTH"] // w_
            await w("IMG_HEIGHT", h_)
        await recip_idle(axi, off, f"group {g}")                 # the reciprocals of the new geometry
        group = [image(rng, nrng, w_, h_) for _ in range(rng.randrange(1, 4))]
        exp = []
        for img in group:
            exp += frame_beats(m.run(img), pack)
        byp, interp, model = m.r.get("BYPASS"), m.r.get("INTERP_MODE"), m.r.get("MODEL_SEL")
        dut._log.info("group %d: %d frame(s) %d x %d, bypass %d, interp %d, model %d, calib %d", g, len(group), w_,
                      h_, byp, interp, model, m.r.get("CALIB_MODE"))
        got = await run_frames(dut, rng, [frame_beats(img, pack) for img in group], gap=rng.choice([0.0, 0.3]),
                               bp=rng.choice([0.0, 0.3, 0.6]), limit=LIMIT,
                               each_clock=trace if os.environ.get("VS_TRACE") else None)
        assert len(got) == len(exp), f"group {g}: {len(got)} beats out, {len(exp)} expected"
        for k, (gt, e) in enumerate(zip(got, exp)):
            if gt != e:
                c = vm.calibration(m.r)
                dut._log.warning("inputs %s", [[hex(v) for v in r] for img in group for r in vm.pack(img)])
                dut._log.warning("expected %s", [hex(b[0]) for b in exp])
                dut._log.warning("got %s", [hex(b[0]) for b in got])
                dut._log.warning("coords %s, calib %s", [vm.coord_gen(c, x, y) for y in range(h_) for x in range(w_)],
                                 vars(c))
            assert gt == e, (f"group {g} ({w_} x {h_}, bypass {byp}, interp {interp}, model {model}) beat {k}: "
                             f"rtl {gt} model {e}")
        frames += len(group)
        COV["bypass" if byp else ("bicubic" if interp else "bilinear")] += len(group)
        d, _ = await axi.read(off["STATUS"])
        if not byp:
            assert d & 2, f"group {g}: STATUS frame done not set ({d:#x})"
            await w("STATUS", 2)
            d, _ = await axi.read(off["STATUS"])
            assert not d & 2, "STATUS frame done not cleared"
    dut._log.info("vision_system: %d frames compared, coverage %s", frames, dict(COV))
    for k in ("bypass", "bilinear", "bicubic", "model0", "model1", "model3", "model5", "size_clamped") \
            if GROUPS >= 16 else ():
        assert COV[k], f"not covered: {k}"


@cocotb.test()
async def test_register_map(dut):
    """The ID block and every register's reset value and read-back against the model."""
    await setup(dut)
    rng = random.Random(SEED + 1)
    m = vm.VisionSystem()
    axi = AxilMaster(dut, dut.clk)
    off = offsets()
    skip = {off["STATUS"], off["CTRL"]}                          # live status; CTRL acts (soft reset)
    offs = sorted((set(m.r.regs) | {0x0, 0x4, 0x8, 0xC, 0x80, 0xFC}) - skip)
    for o in offs:
        d, resp = await axi.read(o)
        assert (d, resp) == m.r.read(o), f"reset 0x{o:02X}: rtl {d:#x}/{resp} model {m.r.read(o)}"
    for _ in range(300):
        o = rng.choice(offs)
        if rng.random() < 0.5:
            d = rng.getrandbits(32)
            assert await axi.write(o, d) == m.r.write(o, d), f"write 0x{o:02X}"
        else:
            d, resp = await axi.read(o)
            assert (d, resp) == m.r.read(o), f"read 0x{o:02X}: rtl {d:#x}/{resp} model {m.r.read(o)}"


@cocotb.test()
async def test_soft_reset(dut):
    """CTRL[0] in the middle of a corrected frame (input part sent, output part read): the datapath restarts, the
    registers keep their values, and the frames after it equal the model."""
    await setup(dut)
    rng = random.Random(SEED + 2)
    nrng = np.random.default_rng(SEED + 2)
    off = offsets()
    m = vm.VisionSystem()
    axi = AxilMaster(dut, dut.clk)
    for t in range(6):
        w_, h_ = rng.randrange(2, 20), rng.randrange(2, 12)
        for n, v in config(rng, 3 + t, w_, h_) + [("BYPASS", 0)]:
            assert await axi.write(off[n], v) == m.r.write(off[n], v)
        await recip_idle(axi, off, f"soft reset {t}")
        beats = frame_beats(image(rng, nrng, w_, h_), pack)
        cut = rng.randrange(1, len(beats) + 1)                   # the abandoned frame: cut beats sent, then reset
        dut.m_tready.value = int(rng.random() < 0.5)
        k = 0
        for _ in range(cut * 50 + 2000):
            await FallingEdge(dut.clk)
            dut.s_tdata.value, dut.s_tlast.value, dut.s_tuser.value = beats[k]
            dut.s_tvalid.value = 1
            await Timer(1, unit="ns")
            k += int(bool(dut.s_tready.value))
            if k == cut:
                break
        await FallingEdge(dut.clk)
        dut.s_tvalid.value = 0
        for _ in range(rng.randrange(0, 200)):
            await FallingEdge(dut.clk)
        assert await axi.write(off["CTRL"], 1) == m.r.write(off["CTRL"], 1)
        dut.m_tready.value = 1
        for _ in range(4):
            await FallingEdge(dut.clk)
        d, _ = await axi.read(off["STATUS"])
        assert not d & 1, f"soft reset {t}: STATUS busy {d:#x} after the reset"
        for n in ("IMG_WIDTH", "K1", "MODEL_SEL"):
            assert (await axi.read(off[n])) == m.r.read(off[n]), f"soft reset {t}: {n} lost"
        stray = rng.randrange(0, 2 * w_ + 1)                     # beats outside a frame: consumed, dropped
        taken = 0
        for _ in range(stray * 50 + 200):
            if taken == stray:
                break
            await FallingEdge(dut.clk)
            dut.s_tdata.value, dut.s_tlast.value, dut.s_tuser.value = rng.getrandbits(24), int(rng.random() < 0.3), 0
            dut.s_tvalid.value = 1
            await Timer(1, unit="ns")
            assert not dut.m_tvalid.value, f"soft reset {t}: a beat outside a frame reached m_axis"
            taken += int(bool(dut.s_tready.value))
        assert taken == stray, f"soft reset {t}: beats outside a frame not consumed ({taken} of {stray})"
        await FallingEdge(dut.clk)
        dut.s_tvalid.value = 0
        group = [image(rng, nrng, w_, h_) for _ in range(2)]
        exp = [b for img in group for b in frame_beats(m.run(img), pack)]
        got = await run_frames(dut, rng, [frame_beats(img, pack) for img in group], gap=0.2, bp=0.3, limit=LIMIT)
        assert got == exp, f"soft reset {t} ({w_} x {h_}, cut {cut} of {len(beats)}): frames after it differ"
