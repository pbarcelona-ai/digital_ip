"""cocotb test of the NPU (npu_top through npu_cocotb_top.sv) against its model (ip/ai/npu/model/npu_model.py,
NpuTop) on a byte-array memory behind a random-latency AXI4 slave.

test_register_map: the ID block and every register's reset value and read-back against the model's map.
test_frame_writer: frames on the video tap (random sizes, strides, gaps; a stride too short or WRITE off:
not written; AUTO: an INPUT run on the frame): memory, STATUS, RUNS, IRQ_STATUS equal the model (frame()).
test_ops: random programs of one to four operations (ADD, UPSAMPLE, COPY, MAXPOOL with k 1 / 2 / 3 / 5, stride
1 / 2, padding up to k / 2; INPUT with a random frame, stride, letterbox and step, either bank, the picture
sometimes outside the input (error); CONV 1 x 1 / 3 x 3, stride 1 / 2, padding 0 / 1, up to 20 x 20 channels and
70-pixel rows (several strips and tiles of the 8 x 8 test array), random bias / M / S, sometimes a LUT, sometimes a
wrong output shape (error); DECODE with random tensors, LUTs (zero weights too), thresholds, letterbox,
INV and frame size, either bank, the candidates of several DECODEs appended; NMS after them (or
alone) with the usual or random limits, containment on / off, a random DET_MAX; random shapes, multipliers, shifts,
byte-aligned or not), sometimes ending in an unknown operation or an ADD with shift 0 (the error flag); the
RTL runs them through CMD and the model NpuTop on a copy of the same memory: afterwards the whole memory,
IRQ_STATUS, RUNS, DET_COUNT and STATUS.FRAME are equal.
test_conv_perf: representative CONV layers (3 x 3 stride 1 / 2, 1 x 1) on a slave without wait states: the result
equals the model's and CYCLES is logged against the array's ideal (MACs / (PE_P PE_O)); with the 8 x 8 array the
efficiency must reach a floor per layer (a guard against throughput regressions).
Cases (run_python.py): pe8 (an 8 x 8 array: many strips and tiles), pe64 (the 64 x 64 array, a quarter of the
programs). Environment: NPU_CASE, NPU_SEED, NPU_N (programs, default 60)."""
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
from cocotb.triggers import FallingEdge, RisingEdge

IP = Path(__file__).resolve().parents[2]
LIB = IP.parents[1]
sys.path.insert(0, str(LIB / "shared" / "tb" / "python"))
from cocotb_lib import AxilMaster, model_path                    # noqa: E402
from npu_tb_lib import Slave                                     # noqa: E402

model_path(IP / "model")
import npu_model as nm                                           # noqa: E402

SEED = int(os.environ.get("NPU_SEED", "20261025"))
CASE = os.environ.get("NPU_CASE", "pe8")
N = int(os.environ.get("NPU_N", "60")) // (4 if CASE == "pe64" else 1)   # the 64 x 64 array simulates slower
MEM = 1 << 19
DESC = 0x100
DECODE_CAND = 0x60000                                            # the candidate list of every DECODE of a run


with open(nm.ip_regs(nm.__file__, "npu"), encoding="utf-8") as _fh:
    OFFS = {r["name"]: int(r["offset"], 16) for r in json.load(_fh)["registers"]}


def off(name):
    return OFFS[name]


async def setup(dut, rng, mem):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    for s in ("m_axi_bid", "m_axi_bresp", "m_axi_rid", "m_axi_rresp", "m_axi_awready", "m_axi_wready",
              "m_axi_bvalid", "m_axi_arready", "m_axi_rvalid", "m_axi_rdata", "m_axi_rlast"):
        getattr(dut, s).value = 0
    axi = AxilMaster(dut, dut.clk)
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    sl = Slave(dut, rng, mem, busy=rng.choice([0.0, 0.3, 0.6]))
    cocotb.start_soon(sl.run())
    return axi, sl


@cocotb.test()
async def test_register_map(dut):
    """The ID block and every register's reset value and read-back."""
    rng = random.Random(SEED + 1)
    axi, _ = await setup(dut, rng, bytearray(MEM))
    top = nm.NpuTop(nm.Ddr(MEM))
    skip = {off("CMD"), off("IRQ_STATUS")}                        # CMD acts; IRQ_STATUS is W1C (checked by test_ops)
    offs = sorted((set(top.r.regs) | {0x0, 0x4, 0x8, 0xC, 0xFC}) - skip)
    for o in offs:
        d, resp = await axi.read(o)
        assert (d, resp) == top.r.read(o), f"reset 0x{o:02X}: rtl {d:#x}/{resp} model {top.r.read(o)}"
    for _ in range(200):
        o = rng.choice(offs)
        if rng.random() < 0.5:
            d = rng.getrandbits(32)
            if o == off("CTRL"):
                d &= ~1                                           # no run without a program
            assert await axi.write(o, d) == top.r.write(o, d), f"write 0x{o:02X}"
        else:
            d, resp = await axi.read(o)
            assert (d, resp) == top.r.read(o), f"read 0x{o:02X}: rtl {d:#x}/{resp} model {top.r.read(o)}"


def descriptor(op, **kw):
    """A 64-byte descriptor (16 little-endian words)."""
    d = [0] * 16
    d[0] = op
    for k, v in kw.items():
        d[int(k[1:])] = v & 0xFFFFFFFF
    return b"".join(int(v).to_bytes(4, "little") for v in d)


def program(rng, mem, cov, dense=False):
    """Random operations written into mem; returns the register writes the program needs (INPUT's frame and
    letterboxes). dense: one DECODE with threshold 0 then an NMS that suppresses nothing (IoU limits 1000 per
    mille), DET_MAX 400 - many detections kept and ranked, whatever the random sequence."""
    ops, regs = [], []
    base = 0x1000
    for _ in range(1 if dense else rng.randrange(1, 5)):
        kind = "decode" if dense else rng.choice(["add", "up", "copy", "pool", "pool", "input", "conv", "conv", "decode"])
        a1 = base + rng.randrange(64)
        a2 = a1 + 0x4000 + rng.randrange(64)
        o = a1 + 0x8000 + rng.randrange(64)
        base += 0xC000
        if kind == "add":
            c, h, w = rng.randrange(1, 4), rng.randrange(1, 7), rng.randrange(1, 90)
            n = c * h * w
            mem[a1:a1 + n] = bytes(rng.getrandbits(8) for _ in range(n))
            mem[a2:a2 + n] = bytes(rng.getrandbits(8) for _ in range(n))
            ma, mb = rng.choice([rng.randrange(1 << 16), rng.getrandbits(32)]), rng.randrange(1 << 16)
            s = rng.choice([1, rng.randrange(1, 24), rng.randrange(24, 63)])
            ops.append(descriptor(nm.OP_ADD, d1=a1, d2=a2, d3=o, d4=c, d5=h << 16 | w, d13=ma, d14=mb, d15=s))
        elif kind == "up":
            c, h, w = rng.randrange(1, 4), rng.randrange(1, 6), rng.randrange(1, 200)
            n = c * h * w
            mem[a1:a1 + n] = bytes(rng.getrandbits(8) for _ in range(n))
            ops.append(descriptor(nm.OP_UPSAMPLE, d1=a1, d3=o, d4=c, d5=h << 16 | w))
        elif kind == "conv":
            k = rng.choice([1, 3])
            st = rng.choice([1, 1, 2])
            pd = rng.choice([0, 1]) if k == 3 else 0
            cin, cout = rng.randrange(1, 21), rng.randrange(1, 21)
            h, w = rng.randrange(max(1, k - 2 * pd), 9), rng.randrange(max(1, k - 2 * pd), 70)
            ho, wo = (h + 2 * pd - k) // st + 1, (w + 2 * pd - k) // st + 1
            n = cin * h * w
            wt, bi, qt, lt = a1 + 0x2000, a1 + 0x5000, a1 + 0x5800, a1 + 0x5C00
            mem[a1:a1 + n] = bytes(rng.getrandbits(8) for _ in range(n))
            nw = cout * cin * k * k
            mem[wt:wt + nw] = bytes(rng.getrandbits(8) for _ in range(nw))
            for o_ in range(cout):
                mem[bi + 4 * o_:bi + 4 * o_ + 4] = rng.randrange(-200000, 200000).to_bytes(4, "little", signed=True)
                m = rng.choice([1, rng.randrange(1, 1 << 15), rng.randrange(1 << 15, 1 << 20)])
                sh = rng.choice([rng.randrange(1, 20), rng.randrange(20, 40)])
                mem[qt + 8 * o_:qt + 8 * o_ + 8] = m.to_bytes(4, "little", signed=True) + sh.to_bytes(4, "little", signed=True)
            use_lut = rng.random() < 0.3
            if use_lut:
                mem[lt:lt + 256] = bytes(rng.getrandbits(8) for _ in range(256))
            bad = rng.random() < 0.05                            # the model's shape assertion fails
            ops.append(descriptor(nm.OP_CONV, d1=a1, d3=o, d4=cin, d5=h << 16 | w, d6=cout,
                                  d7=(ho + int(bad)) << 16 | wo, d8=k | st << 8 | pd << 16, d9=wt, d10=bi, d11=qt,
                                  d12=lt if use_lut else 0))
            cov[f"conv_k{k}_s{st}"] += 1
            cov["conv_lut"] += use_lut
            cov["err_shape"] += bad
        elif kind == "decode":
            reg, nc = rng.randrange(1, 17), rng.randrange(1, 11)
            h, w = rng.randrange(1, 7), rng.randrange(1, 70)
            if dense:
                h, w = max(h, 2), max(w, 8)
            box, cls, lt, cand = a1, a1 + 0x2400, a1 + 0x3000, DECODE_CAND   # candidates after any earlier DECODE's
            nbox, ncls = 4 * reg * h * w, nc * h * w
            mem[box:box + nbox] = bytes(rng.getrandbits(8) for _ in range(nbox))
            mem[cls:cls + ncls] = bytes(rng.getrandbits(8) for _ in range(ncls))
            exp = [32768] + [rng.choice([0, rng.randrange(1 << 16)]) for _ in range(255)]
            if rng.random() < 0.1:
                exp[0] = 0                                       # zero weights: numpy's division by zero gives 0
            mem[lt:lt + 512] = b"".join(v.to_bytes(2, "little") for v in exp)
            mem[lt + 512:lt + 768] = bytes(rng.getrandbits(8) for _ in range(256))
            bank = rng.randrange(2)
            fw, fh = rng.randrange(1, 4000), rng.randrange(1, 3000)
            pre = "LB2_" if bank else "LB_"
            regs += [("FRAME_SIZE", fh << 16 | fw), (pre + "OFFSET", rng.randrange(200) << 16 | rng.randrange(200)),
                     (pre + "INV", rng.randrange(1, 1 << 19))]
            th = 0 if dense else rng.choice([rng.randrange(256), rng.randrange(0x60, 0x80), rng.randrange(0x80, 0x100), 300])
            ops.append(descriptor(nm.OP_DECODE | (nm.FLAG_BANK2 if bank else 0), d1=box, d2=cls, d3=cand,
                                  d4=reg << 16 | nc, d5=h << 16 | w, d8=rng.choice([8, 16, 32]) | rng.randrange(3) << 8,
                                  d12=lt, d13=th))
            cov["decode"] += 1
            cov["_dec"] = 1
            cov[f"decode_bank{bank}"] += 1
        elif kind == "input":
            fw, fh = rng.randrange(1, 120), rng.randrange(1, 40)
            stride = 3 * fw + rng.choice([0, 0, rng.randrange(1, 40)])
            fa = a1
            mem[fa:fa + stride * fh] = bytes(rng.getrandbits(8) for _ in range(stride * fh))
            nw, nh = rng.randrange(1, 160), rng.randrange(1, 50)
            bank = rng.randrange(2)
            sw, sh = rng.randrange(0, nw + 1), rng.randrange(0, nh + 1)
            ox, oy = rng.randrange(0, nw - sw + 1), rng.randrange(0, nh - sh + 1)
            if rng.random() < 0.05:                              # the picture does not fit: the model's error
                ox = nw - sw + 1
                cov["err_input"] += 1
            step = int(rng.choice([1 << 16, (fw << 16) // max(sw, 1), rng.randrange(1 << 14, 3 << 16)]))
            pre = "LB2_" if bank else "LB_"
            regs += [("FRAME_ADDR", fa), ("FRAME_STRIDE", stride), ("FRAME_SIZE", fh << 16 | fw),
                     (pre + "STEP", step), (pre + "OFFSET", oy << 16 | ox), (pre + "SIZE", sh << 16 | sw)]
            nh_w = 0 if (nh == nw and rng.random() < 0.3) else nh   # NH 0: square
            ops.append(descriptor(nm.OP_INPUT | (nm.FLAG_BANK2 if bank else 0), d3=o, d7=nh_w << 16 | nw,
                                  d8=rng.getrandbits(8) << 16))
            cov[f"input_bank{bank}"] += 1
            cov["input"] += 1
            break                                                # one INPUT per program (its registers)
        elif kind == "pool":
            k = rng.choice([1, 2, 3, 5])
            st = rng.choice([1, 2])
            pd = rng.randrange(0, k // 2 + 1)
            c, h, w = rng.randrange(1, 3), rng.randrange(max(1, k - 2 * pd), 8), rng.randrange(max(1, k - 2 * pd), 300)
            n = c * h * w
            mem[a1:a1 + n] = bytes(rng.getrandbits(8) for _ in range(n))
            ops.append(descriptor(nm.OP_MAXPOOL, d1=a1, d3=o, d4=c, d5=h << 16 | w, d8=k | st << 8 | pd << 16))
            cov[f"pool_k{k}_s{st}"] += 1
            cov[f"pool_k{k}"] += 1
        else:
            n = rng.randrange(1, 3000)
            mem[a1:a1 + n] = bytes(rng.getrandbits(8) for _ in range(n))
            ops.append(descriptor(nm.OP_COPY, d1=a1, d3=o, d4=n))
        cov[kind] += 1
    if dense or rng.random() < (0.7 if cov.get("_dec") else 0.1):     # NMS on the run's candidates
        lims = rng.choice([(450, 700, 800), (rng.randrange(1000), rng.randrange(1000), 0),
                           (rng.randrange(1000), rng.randrange(1000), rng.randrange(1000))])
        dmax = rng.choice([1, 5, rng.randrange(1, 400)])
        if dense:
            lims, dmax = (1000, 1000, 0), 400
        regs += [("DET_ADDR", 0x70000 + 16 * rng.randrange(4)), ("DET_MAX", dmax)]
        ops.append(descriptor(nm.OP_NMS, d1=DECODE_CAND, d13=lims[0], d14=lims[1], d15=lims[2]))
        cov["nms"] += 1
        cov["nms_after_decode"] += int(bool(cov.get("_dec")))
    cov["_dec"] = 0
    e = 1.0 if dense else rng.random()
    if e < 0.1:
        ops.append(descriptor(rng.choice([9, 33, 255])))                 # an unknown operation
        cov["err_op"] += 1
    elif e < 0.2:
        ops.append(descriptor(nm.OP_ADD, d1=0x1000, d2=0x2000, d3=0x3000, d4=1, d5=1 << 16 | 4, d15=0))   # S 0
        cov["err_shift"] += 1
    ops.append(descriptor(nm.OP_END))
    p = b"".join(ops)
    mem[DESC:DESC + len(p)] = p
    return regs


@cocotb.test()
async def test_ops(dut):
    """Random programs: memory and status equal the model's."""
    rng = random.Random(SEED)
    mem = bytearray(MEM)
    axi, sl = await setup(dut, rng, mem)
    top = nm.NpuTop(nm.Ddr(MEM))
    cov = collections.Counter()

    async def w(name, d):
        assert await axi.write(off(name), d) == top.r.write(off(name), d), f"write {name}"
    await w("CTRL", 1)
    await w("IRQ_EN", 3)
    await w("DESC_ADDR", DESC)
    for n in range(N):
        mem[:] = bytes(MEM)
        for name, v in program(rng, mem, cov, dense=n == N - 1):
            await w(name, v)
        top.ddr.mem[:] = np.frombuffer(bytes(mem), np.uint8)
        await w("CMD", 1)                                         # the model runs at once
        for t in range(2_000_000):
            await FallingEdge(dut.clk)
            if int(dut.irq_o.value):
                break
        assert int(dut.irq_o.value), f"program {n}: no interrupt"
        exp = top.ddr.mem.tobytes()
        if bytes(mem) != exp:
            bad = [i for i in range(MEM) if mem[i] != exp[i]]
            raise AssertionError(f"program {n}: {len(bad)} bytes differ, first at {bad[0]:#x}: rtl {mem[bad[0]]:#x} "
                                 f"model {exp[bad[0]]:#x}")
        for name in ("IRQ_STATUS", "RUNS", "DET_COUNT", "STATUS"):
            d, _ = await axi.read(off(name))
            assert (d, 0) == top.r.read(off(name)), f"program {n}: {name} rtl {d:#x} model {top.r.read(off(name))}"
        cov["error" if top.r.get("IRQ_STATUS") & 2 else "done"] += 1
        cov["det_some"] += int(top.core.ndet > 0)                    # NMS kept something
        cov["det_many"] += int(top.core.ndet > 5)
        await w("IRQ_STATUS", 3)
    dut._log.info("npu ops: %d programs, %d bursts, coverage %s", N, sl.bursts, dict(cov))
    full = ("nms", "nms_after_decode", "det_some", "det_many", "decode", "decode_bank0", "decode_bank1", "add", "up", "copy", "pool", "pool_k3_s2", "pool_k5", "input", "input_bank0", "input_bank1", "conv",
              "conv_k1_s1", "conv_k3_s1", "conv_k3_s2", "conv_lut",
              "err_op", "err_shift", "done", "error")
    for k in (full if CASE == "pe8" else ("conv", "done")):   # the 64 x 64 case runs fewer programs
        assert cov[k], f"not covered: {k}"


async def send_frame(dut, rng, rgb, gap):
    """One RGB888 frame on the video tap ({B, G, R}, R in the LSBs; tuser on the first pixel, tlast per line), with
    horizontal blanking after every line (the writer needs a line time longer than a line write)."""
    h, w = rgb.shape[:2]
    for y in range(h):
        for x in range(w):
            while rng.random() < gap:
                await FallingEdge(dut.clk)
                dut.v_tvalid.value = 0
            await FallingEdge(dut.clk)
            r, g, b = (int(v) for v in rgb[y, x])
            dut.v_tdata.value = r | g << 8 | b << 16
            dut.v_tuser.value = int(x == 0 and y == 0)
            dut.v_tlast.value = int(x == w - 1)
            dut.v_tvalid.value = 1
        await FallingEdge(dut.clk)
        dut.v_tvalid.value = 0
        for _ in range(rng.randrange(10, 30)):                  # horizontal blanking (as the video has)
            await FallingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.v_tvalid.value = 0
    for _ in range(rng.randrange(1, 40)):                       # blanking (line writes finish meanwhile)
        await FallingEdge(dut.clk)


@cocotb.test()
async def test_frame_writer(dut):
    """Frames on the video tap: written as the model's write_frame (stride, skip rules), STATUS.FRAME, AUTO runs."""
    rng = random.Random(SEED + 3)
    mem = bytearray(MEM)
    for s in ("v_tdata", "v_tvalid", "v_tlast", "v_tuser"):
        getattr(dut, s).value = 0
    dut.v_tready.value = 1
    axi, _ = await setup(dut, rng, mem)
    top = nm.NpuTop(nm.Ddr(MEM))
    cov = collections.Counter()

    async def w(name, d):
        assert await axi.write(off(name), d) == top.r.write(off(name), d), f"write {name}"
    nrng = np.random.default_rng(SEED)
    await w("IRQ_EN", 3)
    for n in range(12 if CASE == "pe8" else 3):
        fw_, fh_ = rng.choice([1, rng.randrange(8, 90)]), rng.randrange(1, 12)
        stride = 3 * fw_ + rng.choice([0, rng.randrange(1, 50)])
        if rng.random() < 0.15:
            stride = 3 * fw_ - rng.randrange(1, 3 * fw_ + 1)        # too short: the frame is not written
            cov["short_stride"] += 1
        auto = rng.random() < 0.4
        ctrl = 1 | 4 | (2 if auto else 0)
        if rng.random() < 0.1:
            ctrl = 1                                                # WRITE off: nothing written
            cov["write_off"] += 1
        await w("FRAME_ADDR", 0x10000 + rng.randrange(64))
        await w("FRAME_STRIDE", stride & 0xFFFF)
        await w("FRAME_SIZE", fh_ << 16 | fw_)
        await w("CTRL", ctrl)
        if auto:                                                    # an INPUT of the frame, then END
            mem[DESC:DESC + 128] = descriptor(nm.OP_INPUT, d3=0x40000, d7=fh_ << 16 | fw_) + descriptor(nm.OP_END)
            await w("DESC_ADDR", DESC)
            await w("LB_STEP", 1 << 16)
            await w("LB_OFFSET", 0)
            await w("LB_SIZE", fh_ << 16 | fw_)
            cov["auto"] += 1
        top.ddr.mem[:] = np.frombuffer(bytes(mem), np.uint8)
        rgb = nrng.integers(0, 256, (fh_, fw_, 3)).astype(np.uint8)
        await send_frame(dut, rng, rgb, rng.choice([0.0, 0.3]))
        top.frame(rgb)
        run = auto and ctrl & 4 and stride >= 3 * fw_
        quiet = 0
        for _ in range(200000):                                     # the AUTO run (its interrupt), or idle
            await FallingEdge(dut.clk)
            if run:
                if int(dut.irq_o.value):
                    break
            else:
                core = dut.u_npu.u_core
                idle = not int(core.cst.value) and not int(core.fw_active.value) and not int(core.auto_pend.value)
                quiet = quiet + 1 if idle else 0
                if quiet == 8:
                    break
        exp = top.ddr.mem.tobytes()
        if bytes(mem) != exp:
            bad = [i for i in range(MEM) if mem[i] != exp[i]]
            fwu = dut.u_npu.u_core.u_fw
            st = {k: int(getattr(fwu, k).value) for k in ("cap", "bad", "ylines", "w3", "qn", "wact", "fin")}
            raise AssertionError(f"frame {n} ({fw_} x {fh_}, stride {stride}, ctrl {ctrl}): {len(bad)} bytes differ, "
                                 f"first at {bad[0]:#x}; writer {st}; prev ctrl {cov.get('_prev')}")
        for name in ("STATUS", "RUNS", "IRQ_STATUS"):
            d, _ = await axi.read(off(name))
            assert (d, 0) == top.r.read(off(name)), f"frame {n}: {name} rtl {d:#x} model {top.r.read(off(name))}"
        cov["written" if ctrl & 4 and stride >= 3 * fw_ else "skipped"] += 1
        cov["_prev"] = ctrl
        await w("IRQ_STATUS", 3)
    dut._log.info("frame writer: coverage %s", dict(cov))
    for k in ("written", "skipped", "auto") if CASE == "pe8" else ():
        assert cov[k], f"not covered: {k}"


# (C, O, H, W, k, s, p, the efficiency floor with the 8 x 8 array)
PERF_LAYERS = [(16, 16, 12, 70, 3, 1, 1, 0.6), (8, 16, 12, 96, 3, 2, 1, 0.3), (32, 16, 8, 60, 1, 1, 0, 0.4)]


@cocotb.test()
async def test_conv_perf(dut):
    """Representative CONV layers: bit exact, CYCLES against the ideal."""
    rng = random.Random(SEED + 5)
    mem = bytearray(MEM)
    axi, sl = await setup(dut, rng, mem)
    sl.busy = 0.0                                                # no wait states: the engine's own throughput
    top = nm.NpuTop(nm.Ddr(MEM))
    pe = 8 if CASE == "pe8" else 64

    async def w(name, d):
        assert await axi.write(off(name), d) == top.r.write(off(name), d), f"write {name}"
    await w("CTRL", 1)
    await w("IRQ_EN", 3)
    await w("DESC_ADDR", DESC)
    for c, o_, h, w_, k, st, pd, floor in PERF_LAYERS:
        mem[:] = bytes(MEM)
        ho, wo = (h + 2 * pd - k) // st + 1, (w_ + 2 * pd - k) // st + 1
        a1, out, wt, bi, qt = 0x1000, 0x20000, 0x40000, 0x50000, 0x51000
        mem[a1:a1 + c * h * w_] = bytes(rng.getrandbits(8) for _ in range(c * h * w_))
        mem[wt:wt + o_ * c * k * k] = bytes(rng.getrandbits(8) for _ in range(o_ * c * k * k))
        for i in range(o_):
            mem[bi + 4 * i:bi + 4 * i + 4] = rng.randrange(-5000, 5000).to_bytes(4, "little", signed=True)
            mem[qt + 8 * i:qt + 8 * i + 8] = (rng.randrange(1, 1 << 12)).to_bytes(4, "little") + (16).to_bytes(4, "little")
        prog = descriptor(nm.OP_CONV, d1=a1, d3=out, d4=c, d5=h << 16 | w_, d6=o_, d7=ho << 16 | wo,
                          d8=k | st << 8 | pd << 16, d9=wt, d10=bi, d11=qt) + descriptor(nm.OP_END)
        mem[DESC:DESC + len(prog)] = prog
        top.ddr.mem[:] = np.frombuffer(bytes(mem), np.uint8)
        await w("CMD", 1)
        for _ in range(5_000_000):
            await FallingEdge(dut.clk)
            if int(dut.irq_o.value):
                break
        assert int(dut.irq_o.value), "no interrupt"
        exp = top.ddr.mem.tobytes()
        if bytes(mem) != exp:
            bad = [i for i in range(MEM) if mem[i] != exp[i]]
            raise AssertionError(f"layer {c}x{o_} {h}x{w_} k{k} s{st}: {len(bad)} bytes differ from the model, first "
                                 + ", ".join(f"{i - out:#x}: rtl {mem[i]:#x} model {exp[i]:#x}" for i in bad[:6]))
        cyc, _ = await axi.read(off("CYCLES"))
        ideal = c * o_ * k * k * ho * wo / (pe * pe)
        eff = ideal / cyc
        dut._log.info("conv C %d O %d %d x %d k %d s %d: %d clocks, ideal %.0f, efficiency %.2f", c, o_, h, w_, k, st,
                      cyc, ideal, eff)
        if CASE == "pe8":
            assert eff >= floor, f"layer {c}x{o_} {h}x{w_} k{k} s{st}: efficiency {eff:.2f} below {floor}"
        await w("IRQ_STATUS", 3)

