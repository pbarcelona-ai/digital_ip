"""cocotb test of ddr_ctrl (with the generic memory ddr_mem) against their models
(ip/memory/ddr_ctrl/model/ddr_ctrl_model.py, ip/memory/ddr_mem/model/ddr_mem_model.py).

test_ddr_ctrl_exact: on every port a random AXI4 master - read and write bursts of 1 .. 256 beats (mostly short,
some long, some crossing rows and banks) over a few hot rows and the whole memory, now and then a wrong
size, a FIXED / WRAP burst or an address beyond the memory, W data that may run ahead of its AW, random gaps
on AW / W / AR and random RREADY / BREADY back-pressure. In every clock all AXI outputs (ready flags, R and B
channels), the DFI command lines and the statistics equal the model's; the memory's timing checker never
fires (mem_err 0); every R beat equals an independent scoreboard of the bytes written before its burst was
granted (0 for error bursts), with the right ID, RRESP and RLAST, and every B the right ID and BRESP.
Coverage: reads, writes, row hits and misses, refreshes (with a burst in progress), SLVERR, DECERR,
back-pressure stalls, every port granted.
Environment: DDRC_CASE (the parameter set the runner built), DDRC_N (clocks, default 30000), DDRC_SEED."""
from __future__ import annotations

import collections
import os
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

IP = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(IP.parents[1] / "shared" / "tb" / "python"))
from cocotb_lib import AxilMaster, model_path                    # noqa: E402

model_path(IP / "model", IP.parent / "ddr_mem" / "model", IP.parents[1] / "fifo" / "fallthrough_fifo" / "model")
import ddr_ctrl_model as cm                                      # noqa: E402
import ddr_mem_model as dm                                       # noqa: E402

TIM = dict(T_RCD=4, T_RP=4, T_RAS=10, T_CL=5, T_WR=4, T_RTP=2, T_WTR=2, T_RRD=2, T_RFC=30)
CASES = {
    "p2rr": dict(NPORTS=2, DATA_W=64, ID_W=4, BANK_W=2, ROW_W=6, COL_W=4, MEM_WORDS=1 << 12, T_REFI=300,
                 PRIORITY=0, RQ_DEPTH=16, BQ_DEPTH=2, **TIM),
    "p3fix": dict(NPORTS=3, DATA_W=32, ID_W=3, BANK_W=3, ROW_W=4, COL_W=3, MEM_WORDS=1 << 10, T_REFI=200,
                  PRIORITY=1, RQ_DEPTH=8, BQ_DEPTH=4, T_RCD=2, T_RP=3, T_RAS=6, T_CL=1, T_WR=2, T_RTP=1, T_WTR=3,
                  T_RRD=1, T_RFC=10),
    "p1w256": dict(NPORTS=1, DATA_W=256, ID_W=2, BANK_W=3, ROW_W=5, COL_W=5, MEM_WORDS=1 << 13, T_REFI=500,
                   PRIORITY=0, RQ_DEPTH=4, BQ_DEPTH=2, T_RCD=1, T_RP=1, T_RAS=1, T_CL=2, T_WR=1, T_RTP=1,
                   T_WTR=1, T_RRD=1, T_RFC=4),
}
CASE = os.environ.get("DDRC_CASE", "p2rr")
P = CASES[CASE]
N = int(os.environ.get("DDRC_N", "30000"))
SEED = int(os.environ.get("DDRC_SEED", "20261021"))
NP, DW, IW = P["NPORTS"], P["DATA_W"], P["ID_W"]
BYTES = DW // 8
OFF = BYTES.bit_length() - 1
MW = P["BANK_W"] + P["ROW_W"] + P["COL_W"]


def models():
    c = cm.DdrCtrl(**{k.lower(): v for k, v in P.items() if k != "MEM_WORDS"})
    mem = dm.DdrMem(data_w=DW, bank_w=P["BANK_W"], row_w=P["ROW_W"], col_w=P["COL_W"], mem_words=P["MEM_WORDS"],
                    ref_max=9 * P["T_REFI"], **{k.lower(): P[k] for k in TIM})
    return c, mem


class Master:
    """A random AXI4 master on one port."""

    def __init__(self, rng, port):
        self.rng, self.port = rng, port
        self.ar = None                                           # the AR presented (until ARREADY)
        self.aw = None
        self.wq = collections.deque()                            # W beats of accepted or queued AWs
        self.aw_queue = collections.deque()                      # AWs whose W beats are queued, not yet sent
        self.exp_r = collections.deque()                         # expected R beats
        self.exp_b = collections.deque()
        self.gap = rng.choice([0.0, 0.3, 0.7])
        self.bp = rng.choice([0.0, 0.3, 0.8])

    def burst(self, write):
        rng = self.rng
        k = rng.random()
        ln = rng.choice([0, 0, 1, 3, 7, 15]) if k < 0.8 else rng.randrange(256)
        if rng.random() < 0.6:                                   # a few hot rows: hits
            word = rng.randrange(4 << P["COL_W"]) + rng.choice([0, 1 << (P["COL_W"] + P["BANK_W"])])
        else:
            word = rng.randrange(1 << MW)
        size, burst = OFF, 1
        e = rng.random()
        if e < 0.03:
            size = rng.choice([s for s in range(8) if s != OFF])
        elif e < 0.06:
            burst = rng.choice([0, 2])
        elif e < 0.09:
            k = rng.randrange(1, 4)
            word = (1 << MW) - k                                 # reaches beyond the memory
            ln = max(ln, k)
        addr = (word << OFF) | rng.randrange(BYTES)              # low bits ignored
        return dict(id=rng.getrandbits(IW), addr=addr & 0xFFFFFFFF, len=ln, size=size, burst=burst)


def rint(v):
    """A signal's value as an integer, X / Z bits as 0 (a FIFO's unwritten storage under Icarus: it is only
    compared while its valid flag is set)."""
    return int(str(v).lower().replace("x", "0").replace("z", "0"), 2)


def resp_of(b):
    w = b["addr"] >> OFF
    if b["size"] != OFF or b["burst"] != 1:
        return cm.SLVERR
    if w + b["len"] >= 1 << MW:
        return cm.DECERR
    return cm.OKAY


@cocotb.test()
async def test_ddr_ctrl_exact(dut):
    """Every clock: AXI, DFI and statistics equal the model; reads equal the scoreboard."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    c, mem = models()
    ms = [Master(rng, p) for p in range(NP)]
    exp_mem = {}                                                 # word -> value (independent scoreboard)
    cov = collections.Counter()
    sigs = ("awid", "awaddr", "awlen", "awsize", "awburst", "awvalid", "wdata", "wstrb", "wlast", "wvalid",
            "bready", "arid", "araddr", "arlen", "arsize", "arburst", "arvalid", "rready")
    for s in sigs:
        getattr(dut, "s_axi_" + s).value = 0
    for s in ("awaddr", "awvalid", "wdata", "wvalid", "bready", "araddr", "arvalid", "rready"):
        getattr(dut, "axi_" + s).value = 0
    dut.axi_wstrb.value = 0xF
    axil = None                                                  # a CTRL write in progress: [aw_done, w_done]
    dut.rst_n.value = 0
    await FallingEdge(dut.clk)
    c.cycle({k: [0] * NP for k in ("arvalid", "awvalid", "wvalid", "rready", "bready")}, rst_n=0)
    mem.cycle(rst_n=0)
    rddata = 0
    for i in range(N):
        await FallingEdge(dut.clk)
        inp = {k: [0] * NP for k in ("arvalid", "araddr", "arlen", "arsize", "arburst", "arid", "awvalid", "awaddr",
                                     "awlen", "awsize", "awburst", "awid", "wvalid", "wdata", "wstrb", "rready",
                                     "bready")}
        for m in ms:
            p = m.port
            if i % 500 == 0:                                     # traffic phases: gaps and back-pressure vary
                m.gap, m.bp = rng.choice([0.0, 0.3, 0.7]), rng.choice([0.0, 0.3, 0.8])
            if m.ar is None and rng.random() < 0.05:
                m.ar = m.burst(False)
            if m.aw is None and rng.random() < 0.05 and len(m.aw_queue) < 3:
                m.aw = m.burst(True)
                m.aw_queue.append(m.aw)
                for k in range(m.aw["len"] + 1):                 # the W beats may run ahead of the AW
                    m.wq.append((rng.getrandbits(DW), rng.choice([(1 << BYTES) - 1, rng.getrandbits(BYTES)]),
                                 int(k == m.aw["len"])))
            if m.ar is not None and rng.random() >= m.gap:
                inp["arvalid"][p], inp["araddr"][p], inp["arlen"][p] = 1, m.ar["addr"], m.ar["len"]
                inp["arsize"][p], inp["arburst"][p], inp["arid"][p] = m.ar["size"], m.ar["burst"], m.ar["id"]
            if m.aw is not None and rng.random() >= m.gap:
                inp["awvalid"][p], inp["awaddr"][p], inp["awlen"][p] = 1, m.aw["addr"], m.aw["len"]
                inp["awsize"][p], inp["awburst"][p], inp["awid"][p] = m.aw["size"], m.aw["burst"], m.aw["id"]
            if m.wq and rng.random() >= m.gap:
                inp["wvalid"][p] = 1
                inp["wdata"][p], inp["wstrb"][p] = m.wq[0][0], m.wq[0][1]
            inp["rready"][p] = int(rng.random() >= m.bp)
            inp["bready"][p] = int(rng.random() >= m.bp)
        if axil is not None:
            if axil[0]:
                dut.axi_awvalid.value = 0
            if axil[1]:
                dut.axi_wvalid.value = 0
        pack = lambda vals, w: sum(v << (w * k) for k, v in enumerate(vals))   # noqa: E731
        for s, w in (("awid", IW), ("awaddr", 32), ("awlen", 8), ("awsize", 3), ("awburst", 2), ("awvalid", 1),
                     ("wdata", DW), ("wstrb", BYTES), ("wvalid", 1), ("bready", 1), ("arid", IW), ("araddr", 32),
                     ("arlen", 8), ("arsize", 3), ("arburst", 2), ("arvalid", 1), ("rready", 1)):
            getattr(dut, "s_axi_" + s).value = pack(inp[s], w)
        dut.s_axi_wlast.value = pack([ms[p].wq[0][2] if ms[p].wq else 0 for p in range(NP)], 1)
        dut.rst_n.value = 1                                      # released for the edge the models step next
        if axil is None and i > 20 and rng.random() < 0.002:     # now and then a CTRL write (bit 0: clear)
            axil = [False, False]
            cov["ctrl_write"] += 1
            dut.axi_awaddr.value, dut.axi_wdata.value = 0x10, rng.choice([1, 1, 0, 2])
            dut.axi_awvalid.value = dut.axi_wvalid.value = 1
            dut.axi_bready.value = 1
        await Timer(1, unit="ns")
        u = dut.u_ctrl
        ctrl_wr, ctrl = int(u.u_regs_if.cfg_ctrl_wr.value), int(u.u_regs_if.cfg_ctrl.value)   # the register map's
        cov["clear"] += int(ctrl_wr and ctrl & 1)
        cov["clear_busy"] += int(ctrl_wr and ctrl & 1 and c.busy)
        if axil is not None:
            if dut.axi_awvalid.value and dut.axi_awready.value:
                axil[0] = True
            if dut.axi_wvalid.value and dut.axi_wready.value:
                axil[1] = True
            if dut.axi_bvalid.value:
                assert int(dut.axi_bresp.value) == 0, "CTRL write answered an error"
                axil = None
        beat_act = c.beat_act                                    # before the edge: was this beat's row opened?
        o = c.cycle(inp, rddata, ctrl_wr=ctrl_wr, ctrl=ctrl)
        cov["acts"] += int(o["cmd"] == dm.ACT)                   # counted here: CTRL clears the statistics
        cov["hits"] += int(o["cmd"] in (dm.RD, dm.WR) and not beat_act)
        mo = mem.cycle(o["cmd"], o["bank"], o["row"], o["col"], o["wrdata"], o["wrstrb"])
        rddata = mem.outputs()["rddata"]                         # the word the memory presents next clock
        # compare the RTL with the models
        got = dict(cmd=int(dut.dfi_cmd.value), bank=int(dut.dfi_bank.value), row=int(dut.dfi_row.value),
                   col=int(dut.dfi_col.value))
        if any(v != o[k] for k, v in got.items()):
            u = dut.u_ctrl
            dut._log.warning("rtl: owed %s busy %s dir %s port %s word %s left %s resp %s cred %s g_wr %s g_ref %s",
                             u.owed.value, u.busy.value, u.dir_q.value, u.port_q.value, u.word_q.value,
                             u.left_q.value, u.resp_q.value, [int(u.cred[k].value) for k in range(NP)],
                             u.g_wr.value, u.g_ref.value)
            dut._log.warning("model: owed %s busy %s dir %s port %s word %s left %s resp %s cred %s g_wr %s g_ref %s",
                             c.owed, c.busy, c.dir, c.port, c.word, c.left, c.resp, c.cred, c.g_wr, c.g_ref)
        for k, v in got.items():
            assert v == o[k], f"clock {i}: dfi {k} rtl {v} model {o[k]}"
        unpack = lambda v, w: [(v >> (w * k)) & ((1 << w) - 1) for k in range(NP)]   # noqa: E731
        for s, w in (("arready", 1), ("awready", 1), ("wready", 1), ("rvalid", 1), ("bvalid", 1)):
            g = unpack(int(getattr(dut, "s_axi_" + s).value), w)
            assert g == o[s], f"clock {i}: {s} rtl {g} model {o[s]}"
        for s, w in (("rdata", DW), ("rid", IW), ("rresp", 2), ("rlast", 1)):
            g = unpack(rint(getattr(dut, "s_axi_" + s).value), w)
            for p in range(NP):
                if o["rvalid"][p]:
                    assert g[p] == o[s][p], f"clock {i}: port {p} {s} rtl {g[p]:#x} model {o[s][p]:#x}"
        for s, w in (("bid", IW), ("bresp", 2)):
            g = unpack(rint(getattr(dut, "s_axi_" + s).value), w)
            for p in range(NP):
                if o["bvalid"][p]:
                    assert g[p] == o[s][p], f"clock {i}: port {p} {s} rtl {g[p]} model {o[s][p]}"
        core = dut.u_ctrl.u_core
        for k in ("rd_beats", "wr_beats", "acts", "hits", "refs", "errs"):
            assert int(getattr(core, "stat_" + k).value) == o["stats"][k], f"clock {i}: stat_{k}"
        assert int(core.owed.value) << 1 | int(core.busy.value) == o["status"], f"clock {i}: STATUS"
        assert int(dut.mem_err.value) == 0 and mo["err"] == 0, \
            f"clock {i}: memory timing violation, code {int(dut.mem_err_code.value)}"
        # the independent scoreboard and the masters' bookkeeping
        cov["refresh_in_burst"] += int(o["cmd"] in (dm.PREA, dm.REF) and c.busy)
        cov["ref"] += int(o["cmd"] == dm.REF)
        for m in ms:
            p = m.port
            if inp["arvalid"][p] and o["arready"][p]:
                b, r = m.ar, resp_of(m.ar)
                w0 = b["addr"] >> OFF
                for k in range(b["len"] + 1):
                    m.exp_r.append((0 if r else exp_mem.get(w0 + k, 0), b["id"], r, int(k == b["len"])))
                cov[{0: "read", 2: "slverr", 3: "decerr"}[r]] += 1
                cov[f"grant_port{p}"] += 1
                m.ar = None
            if inp["awvalid"][p] and o["awready"][p]:
                m.exp_b.append((m.aw["id"], resp_of(m.aw)))
                cov[{0: "write", 2: "slverr", 3: "decerr"}[resp_of(m.aw)]] += 1
                cov[f"grant_port{p}"] += 1
                m.aw = None
            if inp["wvalid"][p] and o["wready"][p]:
                d, s, _ = m.wq.popleft()
                b = m.aw_queue[0]
                if resp_of(b) == cm.OKAY:
                    w = (b["addr"] >> OFF) + b.setdefault("beat", 0)
                    old = exp_mem.get(w, 0)
                    for k in range(BYTES):
                        if s >> k & 1:
                            old = (old & ~(0xFF << 8 * k)) | (d & (0xFF << 8 * k))
                    exp_mem[w] = old
                b["beat"] = b.get("beat", 0) + 1
                if b["beat"] == b["len"] + 1:
                    m.aw_queue.popleft()
            if o["rvalid"][p] and inp["rready"][p]:
                e = m.exp_r.popleft()
                gotb = (o["rdata"][p], o["rid"][p], o["rresp"][p], o["rlast"][p])
                assert gotb == e, f"clock {i}: port {p} R {gotb} scoreboard {e}"
            cov["r_stall"] += int(o["rvalid"][p] and not inp["rready"][p])
            if o["bvalid"][p] and inp["bready"][p]:
                e = m.exp_b.popleft()
                assert (o["bid"][p], o["bresp"][p]) == e, f"clock {i}: port {p} B {(o['bid'][p], o['bresp'][p])} {e}"
    st = c.stats
    dut._log.info("%s: %d clocks compared, stats %s, coverage %s", CASE, N, st, dict(sorted(cov.items())))
    for k in ["read", "write", "slverr", "decerr", "hits", "acts", "ref", "refresh_in_burst", "r_stall", "clear"] + \
            [f"grant_port{p}" for p in range(NP)]:
        assert cov[k], f"not covered: {k}"


@cocotb.test()
async def test_register_map(dut):
    """The ID block, every statistics register against the core after some traffic, CTRL clear, SLVERR for
    writes to read-only registers, DECERR past the map."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    for s in ("awid", "awaddr", "awlen", "awsize", "awburst", "awvalid", "wdata", "wstrb", "wlast", "wvalid",
              "bready", "arid", "araddr", "arlen", "arsize", "arburst", "arvalid", "rready"):
        getattr(dut, "s_axi_" + s).value = 0
    axi = AxilMaster(dut, dut.clk)
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    d, r = await axi.read(0x00)
    assert (d, r) == (int.from_bytes(b"DDRC", "big"), 0), f"ID {d:#x}"
    d, r = await axi.read(0x04)
    assert r == 0 and bytes.fromhex(f"{d:08x}")[1:2] == b".", f"VERSION {d:#x}"
    # traffic on port 0: a write burst, then a read burst (and a bad burst), all responses taken
    dut.s_axi_rready.value = (1 << NP) - 1
    dut.s_axi_bready.value = (1 << NP) - 1
    for addr, ln, size in ((0x40 << OFF, 7, OFF), (0, 0, 7 if OFF != 7 else 0)):
        dut.s_axi_awaddr.value, dut.s_axi_awlen.value, dut.s_axi_awsize.value = addr, ln, size
        dut.s_axi_awburst.value, dut.s_axi_awvalid.value = 1, 1
        dut.s_axi_wvalid.value, dut.s_axi_wstrb.value, dut.s_axi_wdata.value = 1, (1 << BYTES) - 1, 0x1234
        while True:
            await RisingEdge(dut.clk)
            if int(dut.s_axi_awready.value) & 1:
                break
        dut.s_axi_awvalid.value = 0
        while not int(dut.s_axi_bvalid.value) & 1:
            await RisingEdge(dut.clk)
        dut.s_axi_wvalid.value = 0
    dut.s_axi_araddr.value, dut.s_axi_arlen.value, dut.s_axi_arsize.value = 0x40 << OFF, 3, OFF
    dut.s_axi_arburst.value, dut.s_axi_arvalid.value = 1, 1
    while True:
        await RisingEdge(dut.clk)
        if int(dut.s_axi_arready.value) & 1:
            break
    dut.s_axi_arvalid.value = 0
    for _ in range(50):
        await RisingEdge(dut.clk)
    core = dut.u_ctrl.u_core
    names = ("rd_beats", "wr_beats", "acts", "hits", "refs", "errs")
    for k, name in enumerate(names):
        d, r = await axi.read(0x18 + 4 * k)
        assert r == 0 and d == int(getattr(core, "stat_" + name).value), f"{name}: {d} / {r}"
    assert int(core.stat_rd_beats.value) == 4 and int(core.stat_wr_beats.value) == 8 and int(core.stat_errs.value) == 1
    d, r = await axi.read(0x14)
    assert r == 0 and d & 1 == 0, f"STATUS {d:#x}"
    assert await axi.write(0x18, 5) == 2, "a write to a read-only register must answer SLVERR"
    assert await axi.write(0x10, 1) == 0
    for k, name in enumerate(names):
        d, r = await axi.read(0x18 + 4 * k)
        if name != "refs":                                       # a refresh may come in between
            assert (d, r) == (0, 0), f"{name} after the clear: {d} / {r}"
    d, r = await axi.read(0xFC)
    assert r == 3, f"past the map: resp {r}"
