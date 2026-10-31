"""cocotb test of ddr_frame_store (on a one-port ddr_ctrl with ddr_mem, ddr_frame_store_cocotb_top.sv) against the
models (model/ddr_frame_store_model.py, ip/memory/ddr_ctrl/model, ip/memory/ddr_mem/model).

test_ddr_frame_store_exact: frames written and read as vision_system does with the DDR store, double-buffered:
a writer fills one buffer in raster order (random gaps, now and then a jump to another address) while a reader
issues random four-address requests on the other buffer (bilinear / bicubic-like neighbourhoods along a
wandering path, sometimes anywhere in the frame); at each frame end the writer waits for wr_idle, the buffers
swap and the reader flushes the cache; requests are issued whenever rd_ready is high (several in flight, returned
in order); now and then a clear pulse (soft reset) drops every request not yet returned.
In every clock the store's outputs, its AXI4 port, the controller's
ready / valid flags and the DFI command equal the models'; the memory's timing checker never fires; every
rd_valid returns the pixels of an independent scoreboard of the frames written.
Coverage: hits, four reads in one clock, requests taken back to back, misses, evictions, partial-word flushes, full-word pushes, queue full, OUT_MAX reached,
flushes, clears during lookups and during line fills, both buffers read and written.
Environment: DFS_CASE (the parameter set the runner built), DFS_N (clocks, default 40000), DFS_SEED."""
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
LIB = IP.parents[3] / "ip"
sys.path.insert(0, str(LIB / "shared" / "tb" / "python"))
from cocotb_lib import model_path                                 # noqa: E402

model_path(IP / "model", LIB / "memory" / "ddr_ctrl" / "model", LIB / "memory" / "ddr_mem" / "model",
           LIB / "fifo" / "fallthrough_fifo" / "model")
import ddr_ctrl_model as cm                                       # noqa: E402
import ddr_frame_store_model as fm                                # noqa: E402
import ddr_mem_model as dm                                        # noqa: E402

# the controller and memory sources (the store's own come from its scripts/build.f)
LIB_SOURCES = [str(LIB / p) for p in (
    "shared/src/interfaces/regbus_if.sv", "memory/ddr_ctrl/src/include/ddr_ctrl_regs_if.sv",
    "memory/ddr_ctrl/src/ddr_ctrl.sv", "memory/ddr_mem/src/ddr_mem.sv")]
TIM = dict(T_RCD=3, T_RP=3, T_RAS=6, T_CL=4, T_WR=3, T_RTP=2, T_WTR=2, T_RRD=2, T_RFC=12)
MEM = dict(BANK_W=2, ROW_W=4, COL_W=6, MEM_WORDS=1 << 12, T_REFI=300, RQ_DEPTH=8, BQ_DEPTH=2)
CASES = {
    "d256": dict(PIX_W=24, ADDR_W=10, DATA_W=256, LINE_PIX=32, CACHE_LINES=8, WQ_DEPTH=4, FLUSH_IDLE=4,
                 OUT_MAX=8, **MEM, **TIM),
    "d64": dict(PIX_W=24, ADDR_W=10, DATA_W=64, LINE_PIX=4, CACHE_LINES=4, WQ_DEPTH=2, FLUSH_IDLE=1, OUT_MAX=1,
                BANK_W=2, ROW_W=5, COL_W=7, MEM_WORDS=1 << 14, T_REFI=200, RQ_DEPTH=4, BQ_DEPTH=2, **TIM),
    "d128": dict(PIX_W=16, ADDR_W=9, DATA_W=128, LINE_PIX=16, CACHE_LINES=16, WQ_DEPTH=8, FLUSH_IDLE=8,
                 OUT_MAX=2, BANK_W=2, ROW_W=4, COL_W=6, MEM_WORDS=1 << 12, T_REFI=400, RQ_DEPTH=16, BQ_DEPTH=4,
                 **TIM),
}
CASE = os.environ.get("DFS_CASE", "d256")
P = CASES[CASE]
N = int(os.environ.get("DFS_N", "40000"))
SEED = int(os.environ.get("DFS_SEED", "20261025"))


def models():
    f = fm.DdrFrameStore(pix_w=P["PIX_W"], addr_w=P["ADDR_W"], data_w=P["DATA_W"], line_pix=P["LINE_PIX"],
                         cache_lines=P["CACHE_LINES"], wq_depth=P["WQ_DEPTH"], flush_idle=P["FLUSH_IDLE"],
                         out_max=P["OUT_MAX"])
    tim = {k.lower(): P[k] for k in TIM}
    c = cm.DdrCtrl(nports=1, data_w=P["DATA_W"], addr_w=32, id_w=4, bank_w=P["BANK_W"], row_w=P["ROW_W"],
                   col_w=P["COL_W"], t_refi=P["T_REFI"], priority=0, rq_depth=P["RQ_DEPTH"], bq_depth=P["BQ_DEPTH"],
                   **tim)
    m = dm.DdrMem(data_w=P["DATA_W"], bank_w=P["BANK_W"], row_w=P["ROW_W"], col_w=P["COL_W"],
                  mem_words=P["MEM_WORDS"], ref_max=9 * P["T_REFI"], **tim)
    return f, c, m


AXI_IN = ("arvalid", "araddr", "arlen", "arsize", "arburst", "arid", "awvalid", "awaddr", "awlen", "awsize",
          "awburst", "awid", "wvalid", "wdata", "wstrb", "rready", "bready")


@cocotb.test()
async def test_ddr_frame_store_exact(dut):
    """Every clock: the store, its AXI port and the DFI commands equal the models; reads equal the scoreboard."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    f, c, m = models()
    fw = rng.choice([7, 13, 16, 24])                              # frame width
    fh = (1 << P["ADDR_W"]) // fw - rng.randrange(2)
    npix = fw * fh
    frame = {0: [0] * npix, 1: [0] * npix}                        # the scoreboard: the complete frames
    cur = [rng.getrandbits(P["PIX_W"]) for _ in range(npix)]      # the frame being written
    wbuf, rbuf, readable = 0, 1, False                            # rbuf holds a complete frame once readable
    wpix, wait_idle, flush_next = 0, False, False
    gap, rgap = 0.3, 0.3
    pend = collections.deque()                                    # requests taken, not yet returned (in order)
    px, py = 0, 0
    cov = collections.Counter()
    for s in ("wr_en", "wr_addr", "wr_data", "wr_buf", "rd_en", "rd_addr0", "rd_addr1", "rd_addr2", "rd_addr3",
              "rd_buf", "rd_flush", "clear"):
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    await FallingEdge(dut.clk)
    f.cycle({}, rst_n=0)
    c.cycle({k: [0] for k in ("arvalid", "awvalid", "wvalid", "rready", "bready")}, rst_n=0)
    m.cycle(rst_n=0)
    rddata = 0
    for i in range(N):
        await FallingEdge(dut.clk)
        dut.rst_n.value = 1
        so = f.outputs()
        fi = dict(wr_en=0, wr_addr=0, wr_data=0, wr_buf=wbuf, rd_en=0, rd_addr=[0] * 4, rd_buf=rbuf, rd_flush=0,
                  clear=int(rng.random() < 0.002))
        if i % 1000 == 0:
            gap, rgap = rng.choice([0.0, 0.3, 0.8]), rng.choice([0.0, 0.3, 0.8])
        # the writer: raster order into wbuf, then wait for wr_idle and swap
        if wait_idle:
            if so["wr_idle"] and not pend:
                frame[wbuf] = cur
                wbuf, rbuf, readable, wait_idle, flush_next = rbuf, wbuf, True, False, True
                cur = [rng.getrandbits(P["PIX_W"]) for _ in range(npix)]
                wpix = 0
                cov["swap"] += 1
        elif rng.random() >= gap:
            a = wpix if rng.random() > 0.02 else rng.randrange(npix)  # now and then another address
            fi.update(wr_en=1, wr_addr=a, wr_data=cur[a])
            if so["wr_ready"]:
                if a == wpix:
                    wpix += 1
                    if wpix == npix:
                        wait_idle = True
            else:
                cov["wr_stall"] += 1
        fi["wr_buf"] = wbuf
        # the reader: requests on rbuf (a complete frame), a flush after each swap
        if so["rd_valid"]:
            req = pend.popleft()
            exp = [frame[rbuf][a] for a in req]
            assert so["rd_data"] == exp, f"clock {i}: rd_data {so['rd_data']} scoreboard {exp} at {req}"
            cov["read"] += 1
        if fi["clear"]:                                           # every request not delivered is dropped
            cov["clear_fill" if f.fill else ("clear_look" if f.lv else "clear_idle")] += 1
            cov["clear_done"] += int(f.fin)
            pend.clear()
        elif so["rd_ready"] and readable and not wait_idle and rng.random() >= rgap:
            if rng.random() < 0.1:
                px, py = rng.randrange(fw), rng.randrange(fh)
            else:
                px = (px + rng.choice([0, 1, 1, 2])) % fw
                py = min(fh - 1, max(0, py + rng.choice([-1, 0, 0, 0, 1]) * (px == 0)))
            cl = lambda x, y: min(fh - 1, max(0, y)) * fw + min(fw - 1, max(0, x))   # noqa: E731
            if rng.random() < 0.5:
                req = [cl(px, py), cl(px + 1, py), cl(px, py + 1), cl(px + 1, py + 1)]
            else:
                r = py + rng.randrange(-1, 3)
                req = [cl(px + d, r) for d in (-1, 0, 1, 2)]
            cov["pipelined"] += int(len(pend) > 0)                # taken while an earlier one is in flight
            pend.append(req)
            fi.update(rd_en=1, rd_addr=req, rd_flush=int(flush_next))
            cov["flush"] += flush_next
            flush_next = False
        elif so["rd_ready"] and rng.random() < 0.005:
            fi["rd_flush"] = 1                                    # a flush with nothing to read
            cov["flush"] += 1
        fi["rd_buf"] = rbuf
        for k in ("wr_en", "wr_addr", "wr_data", "wr_buf", "rd_en", "rd_buf", "rd_flush", "clear"):
            getattr(dut, k).value = fi[k]
        for k in range(4):
            getattr(dut, f"rd_addr{k}").value = fi["rd_addr"][k]
        await Timer(1, unit="ns")
        # the models: the store's AXI outputs into the controller, the controller's flags back
        ci = {k: [so.get(k, 0)] for k in AXI_IN}
        co = c.cycle(ci, rddata)
        mo = m.cycle(co["cmd"], co["bank"], co["row"], co["col"], co["wrdata"], co["wrstrb"])
        rddata = m.outputs()["rddata"]
        fi.update(awready=co["awready"][0], wready=co["wready"][0], bvalid=co["bvalid"][0],
                  arready=co["arready"][0], rvalid=co["rvalid"][0], rdata=co["rdata"][0])
        hit_before = f.lv and not f.fill
        f.cycle(fi)
        # compare the RTL with the models
        for k in ("wr_ready", "wr_idle", "rd_ready", "rd_valid", "awvalid", "wvalid", "arvalid", "rready"):
            assert int(getattr(dut, k).value) == so[k], f"clock {i}: {k} rtl {int(getattr(dut, k).value)} model {so[k]}"
        if so["rd_valid"]:
            got = [int(getattr(dut, f"rd_data{k}").value) for k in range(4)]
            assert got == so["rd_data"], f"clock {i}: rd_data rtl {got} model {so['rd_data']}"
        if so["awvalid"]:
            assert int(dut.awaddr.value) == so["awaddr"], f"clock {i}: awaddr"
        if so["wvalid"]:
            assert (int(dut.wdata.value), int(dut.wstrb.value)) == (so["wdata"], so["wstrb"]), f"clock {i}: W"
        if so["arvalid"]:
            assert (int(dut.araddr.value), int(dut.arlen.value)) == (so["araddr"], so["arlen"]), f"clock {i}: AR"
        for k in ("awready", "wready", "bvalid", "arready", "rvalid"):
            assert int(getattr(dut, k).value) == co[k][0], f"clock {i}: {k} rtl {int(getattr(dut, k).value)} model {co[k][0]}"
        assert int(dut.dfi_cmd.value) == co["cmd"], f"clock {i}: dfi_cmd rtl {int(dut.dfi_cmd.value)} model {co['cmd']}"
        assert int(dut.mem_err.value) == 0 and mo["err"] == 0, f"clock {i}: memory timing violation"
        # coverage
        cov["miss"] += int(f.fill and hit_before)
        cov["hit"] += int(any(f.rp))
        cov["hit4"] += int(all(f.rp))                             # four reads in one clock
        cov["full_push"] += int(so["awvalid"] and so["wstrb"] == (1 << P["DATA_W"] // 8) - 1 and not f.aw_v)
        cov["partial"] += int(so["awvalid"] and so["wstrb"] != (1 << P["DATA_W"] // 8) - 1 and not f.aw_v)
        cov["queue_full"] += int(not so["wr_ready"])
        cov["out_max"] += int(f.outst == P["OUT_MAX"])
        cov[f"read_buf{rbuf}"] += int(so["rd_valid"])
    dut._log.info("%s: %d clocks, frame %dx%d, controller %s, coverage %s", CASE, N, fw, fh, c.stats,
                  dict(sorted(cov.items())))
    for k in ["read", "swap", "flush", "miss", "hit", "hit4", "pipelined", "full_push", "partial", "queue_full", "wr_stall", "read_buf0",
              "read_buf1", "clear_look", "clear_fill"] + (["out_max"] if P["OUT_MAX"] == 1 else []):      # OUT_MAX 1 is reached (B returns fast)
        assert cov[k], f"not covered: {k}"
