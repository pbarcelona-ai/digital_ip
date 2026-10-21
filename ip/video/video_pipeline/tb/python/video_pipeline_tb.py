"""cocotb test of video_pipeline's ISP against its model (ip/video/video_pipeline/model/video_pipeline_model.py).

test_isp_exact: RAW10 frames sent as MIPI CSI-2 on two D-PHY lanes (frame start / end short packets, one RAW10
long packet per line, header ECC and payload CRC-16 as csi2_bfm.sv), through csi2_rx, the clock-domain bridge,
csi2_raw_unpack and the ISP; the output taken at the insert point (CTRL[7]) with random back-pressure. The
configuration is written through AXI4-Lite to the RTL and the model between groups of frames (frames of a group
back to back): CFA pattern, BT.709, every BYPASS bit, black levels, white-balance gains, DPC threshold, CCM
coefficients and offsets, the statistics threshold and parts of the gamma table (GAMMA_ADDR / GAMMA_DATA). Every
ISP output beat equals the model's frames, in order; after each group STAT_SUM_R / G / B, STAT_PIX, STAT_CLIP,
STAT_FRAMES (a frame's totals reported when the next frame starts), DPC_CORR, CSI_FRAMES, the error counters and
eof_in_o's count equal the model's; the ID block and the register read-back too.
Environment: VP_CASE, VP_GROUPS (default 14), VP_SEED."""
from __future__ import annotations

import collections
import os
import random
import sys
from pathlib import Path

import cocotb
import numpy as np
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

IP = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(IP.parents[1] / "shared" / "tb" / "python"))
from cocotb_lib import AxilMaster, model_path                    # noqa: E402

model_path(IP / "model", *(IP.parent / n / "model" for n in ("isp_blc_wb", "isp_dpc", "isp_demosaic", "isp_ccm",
                                                              "isp_gamma", "isp_csc", "isp_stats")))
import video_pipeline_model as vm                                # noqa: E402

CASES = {"l2": dict(NLANES=2, MAX_W=64)}
CASE = os.environ.get("VP_CASE", "l2")
P = CASES[CASE]
NL = P["NLANES"]
GROUPS = int(os.environ.get("VP_GROUPS", "14"))
SEED = int(os.environ.get("VP_SEED", "20261021"))
COV = collections.Counter()


# ---------------- CSI-2 packets (as ip/shared/tb/lib/csi2_bfm.sv)
def ecc(h):
    d = [(h >> i) & 1 for i in range(24)]
    sets = ([0, 1, 2, 4, 5, 7, 10, 11, 13, 16, 20, 21, 22, 23], [0, 1, 3, 4, 6, 8, 10, 12, 14, 17, 20, 21, 22, 23],
            [0, 2, 3, 5, 6, 9, 11, 12, 15, 18, 20, 21, 22], [1, 2, 3, 7, 8, 9, 13, 14, 15, 19, 20, 21, 23],
            [4, 5, 6, 7, 8, 9, 16, 17, 18, 19, 20, 22, 23], [10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 21, 22, 23])
    p = 0
    for k, s in enumerate(sets):
        b = 0
        for i in s:
            b ^= d[i]
        p |= b << k
    return p


def crc(pay):
    c = 0xFFFF
    for v in pay:
        for b in range(8):
            c = (c >> 1) ^ (0x8408 if (c ^ (v >> b)) & 1 else 0)
    return c


def packet(dt, wc, pay=(), vc=0):
    h = (wc << 8) | (vc << 6) | dt
    pkt = [h & 0xFF, (h >> 8) & 0xFF, (h >> 16) & 0xFF, ecc(h)]
    if dt >= 0x10:
        c = crc(pay)
        pkt += list(pay) + [c & 0xFF, c >> 8]
    return pkt


def raw10(px):
    pay = []
    for i in range(0, len(px) - 3, 4):
        p = [int(v) for v in px[i:i + 4]]
        pay += [v >> 2 for v in p] + [(p[3] & 3) << 6 | (p[2] & 3) << 4 | (p[1] & 3) << 2 | (p[0] & 3)]
    return pay


class Lanes:
    """The D-PHY lanes on byte_clk: bursts (byte i on lane i mod NL), gap idle clocks after each."""

    def __init__(self, dut):
        self.dut, self.q = dut, collections.deque()
        dut.lane_valid_i.value = 0
        dut.lane_data_i.value = 0
        cocotb.start_soon(self.run())

    def send(self, pkt, gap):
        self.q.append((pkt, gap))

    def idle(self):
        return not self.q and getattr(self, "_busy", False) is False

    async def run(self):
        d = self.dut
        while True:
            await FallingEdge(d.byte_clk)
            if not self.q:
                continue
            self._busy = True
            pkt, gap = self.q.popleft()
            lanes = [pkt[l::NL] for l in range(NL)]
            for t in range(max(len(x) for x in lanes)):
                data = valid = 0
                for l in range(NL):
                    if t < len(lanes[l]):
                        data |= lanes[l][t] << (8 * l)
                        valid |= 1 << l
                d.lane_data_i.value, d.lane_valid_i.value = data, valid
                await FallingEdge(d.byte_clk)
            d.lane_valid_i.value = 0
            for _ in range(gap):
                await FallingEdge(d.byte_clk)
            self._busy = False


def json_offsets():
    import json
    with open(IP / "src" / "include" / "video_pipeline_regs.json", encoding="utf-8") as fh:
        return {r["name"]: int(r["offset"], 16) for r in json.load(fh)["registers"]}


@cocotb.test()
async def test_isp_exact(dut):
    """CSI-2 frames through the ISP: every output beat and the statistics equal the model."""
    cocotb.start_soon(Clock(dut.pix_clk, 10, unit="ns").start())
    cocotb.start_soon(Clock(dut.byte_clk, 16, unit="ns").start())
    rng = random.Random(SEED)
    nrng = np.random.default_rng(SEED)
    off = json_offsets()
    dut.byte_rst_n.value = dut.pix_rst_n.value = 0
    dut.ins_tready.value = 0
    for _ in range(4):
        await RisingEdge(dut.pix_clk)
        await RisingEdge(dut.byte_clk)
    dut.byte_rst_n.value = dut.pix_rst_n.value = 1
    m = vm.VideoPipeline(build_cfg=0x41)                          # CSI-2 RX and the insert point (the config)
    axi = AxilMaster(dut, dut.pix_clk)
    lanes = Lanes(dut)

    async def w(name, d, i=0):
        assert await axi.write(off[name] + 4 * i, d) == m.r.write(off[name] + 4 * i, d), f"write {name}"
    # ID block and read-back of the reset values
    for o in sorted(set(m.r.regs) | {0x0, 0x4, 0x8, 0xC, 0x10, 0x110, 0x214, 0x1FFC, 0x3FFC}):   # past the map: DECERR
        name = m.r.regs[o][0] if o in m.r.regs else ""
        if name in ("STATUS",):                                   # the display side (not modelled)
            continue
        d, resp = await axi.read(o)
        assert (d, resp) == m.r.read(o), f"reset 0x{o:03X} {name}: rtl {d:#x}/{resp} model {m.r.read(o)}"
    state = dict(out=[], bp=0.2)

    async def monitor():
        while True:
            await FallingEdge(dut.pix_clk)
            dut.ins_tready.value = int(rng.random() >= state["bp"])
            await Timer(1, unit="ns")
            if dut.ins_tvalid.value and dut.ins_tready.value:
                state["out"].append((int(dut.ins_tdata.value), int(dut.ins_tlast.value), int(dut.ins_tuser.value)))
    eofs = [0]

    async def count_eof():
        while True:
            await RisingEdge(dut.pix_clk)
            eofs[0] += int(dut.eof_in_o.value)
    cocotb.start_soon(monitor())
    cocotb.start_soon(count_eof())
    frames = 0
    exp = []
    for g in range(GROUPS):
        w_, h_ = rng.choice([(64, 3), (8, 4), rng.choice([(16, 6), (32, 8), (48, 5), (64, 10)])])
        await w("FRAME_SIZE", h_ << 16 | w_)
        cfa, b709 = (g if g < 4 else rng.randrange(4)), rng.random() < 0.5   # every pattern first
        await w("CTRL", 0x80 | cfa << 4 | int(b709) << 6)
        byp = 0x80 | (rng.getrandbits(7) if g % 3 else 0)
        await w("BYPASS", byp)
        for n in ("BLC_R", "BLC_GR", "BLC_GB", "BLC_B"):
            await w(n, rng.choice([0, 64, rng.randrange(300)]))
        for n in ("WB_R", "WB_G", "WB_B"):
            await w(n, rng.choice([0x100, rng.randrange(0x80, 0x300)]))
        await w("DPC_THR", rng.choice([0, 32, 64, 1023]))
        if rng.random() < 0.6:
            for i in range(3):
                for j in range(3):
                    await w(f"CCM_C{i}{j}", (rng.randrange(-600, 600) + (1024 if i == j else 0)) & 0xFFFF)
            for c in "RGB":
                await w(f"CCM_OFF_{c}", rng.randrange(-40, 40) & 0xFFFF)
        await w("STAT_THR", rng.choice([1000, 512, 1023, rng.randrange(1024)]))
        if rng.random() < 0.4:                                    # part of the gamma table
            a0 = rng.randrange(1024)
            await w("GAMMA_ADDR", a0)
            for _ in range(rng.randrange(8, 64)):
                await w("GAMMA_DATA", rng.getrandbits(8))
            COV["gamma"] += 1
        COV[f"cfa{cfa}"] += 1
        COV["bt709"] += b709
        COV["bypass"] += int(bool(byp & 0x7F))
        for _ in range(rng.randrange(1, 4)):                      # frames of this group, back to back
            raw = nrng.integers(0, 1024, (h_, w_))
            raw[nrng.random((h_, w_)) < 0.03] = rng.choice([0, 1023])   # defects
            frames += 1
            lanes.send(packet(0x00, frames & 0xFFFF), 40)
            for y in range(h_):
                pay = raw10(raw[y])
                lanes.send(packet(0x2B, len(pay), pay), rng.choice([20, 60]))
            lanes.send(packet(0x01, frames & 0xFFFF), 80)
            m.csi_frames += 1
            out = m.run(raw)
            exp += [((int(out[y, x, 0]) | int(out[y, x, 1]) << 8 | int(out[y, x, 2]) << 16), int(x == w_ - 1),
                     int(x == 0 and y == 0)) for y in range(h_) for x in range(w_)]
        for _ in range(200000):                                   # the group has left the ISP
            await RisingEdge(dut.pix_clk)
            if len(state["out"]) >= len(exp) and not lanes.q:
                break
        for _ in range(50):
            await RisingEdge(dut.pix_clk)
        got = state["out"]
        assert len(got) == len(exp), f"group {g}: {len(got)} output beats, model {len(exp)}"
        for k, (gt, e) in enumerate(zip(got, exp)):
            assert gt == e, f"group {g} beat {k}: rtl {gt} model {e} (bypass {byp:#x} cfa {cfa} bt709 {b709})"
        for n in ("STAT_SUM_R", "STAT_SUM_G", "STAT_SUM_B", "STAT_PIX", "STAT_CLIP", "STAT_FRAMES", "DPC_CORR",
                  "CSI_FRAMES", "ECC_CORR", "ECC_ERR", "CRC_ERR", "CSI_OVERFLOW"):
            d, _ = await axi.read(off[n])
            md, _ = m.r.read(off[n])
            assert d == md, f"group {g}: {n} rtl {d} model {md}"
        assert eofs[0] == frames, f"eof_in_o {eofs[0]} pulses, {frames} frames"
        COV["dpc"] += int(m.dpc_corr > 0)
    dut._log.info("%s: %d frames compared, coverage %s", CASE, frames, dict(COV))
    for k in ("cfa0", "cfa1", "cfa2", "cfa3", "bt709", "bypass", "gamma", "dpc"):
        assert COV[k], f"not covered: {k}"
