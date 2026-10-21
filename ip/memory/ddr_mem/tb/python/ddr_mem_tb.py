"""cocotb test of ddr_mem against its model (ip/memory/ddr_mem/model/ddr_mem_model.py).

test_ddr_mem_exact: command streams from a generator that keeps a shadow of the bank states and the timing ages:
mostly legal traffic (ACT / RD / WR with random data and byte strobes, PRE, PREA, REF in time, idle clocks,
row hits and misses over every bank), and with a set probability one deliberate violation of a chosen rule
(each of codes 1 .. 13, the refresh deadline by withholding REF); a reset after a violation (and now and then
without one) so every code is seen as the first. In every clock rddata_valid, rddata (while valid), err,
err_code and err_cnt equal the model's. Coverage: every violation code as err_code, reads of written and
unwritten words, writes with partial strobes, every bank, reads back to back.
Environment: DDRM_CASE (the parameter set the runner built), DDRM_N (clocks, default 20000), DDRM_SEED."""
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
sys.path.insert(0, str(IP.parents[1] / "shared" / "tb" / "python"))
from cocotb_lib import model_path                                # noqa: E402

model_path(IP / "model")
import ddr_mem_model as dm                                       # noqa: E402

CASES = {
    "d256": dict(DATA_W=256, BANK_W=3, ROW_W=14, COL_W=8, MEM_WORDS=1 << 12, T_RCD=4, T_RP=4, T_RAS=10, T_CL=5,
                 T_WR=4, T_RTP=2, T_WTR=2, T_RRD=2, T_RFC=30, REF_MAX=1200),
    "d32": dict(DATA_W=32, BANK_W=2, ROW_W=4, COL_W=3, MEM_WORDS=1 << 9, T_RCD=2, T_RP=3, T_RAS=5, T_CL=1, T_WR=3,
                T_RTP=1, T_WTR=3, T_RRD=1, T_RFC=8, REF_MAX=150),
    "d64": dict(DATA_W=64, BANK_W=1, ROW_W=6, COL_W=4, MEM_WORDS=1 << 10, T_RCD=1, T_RP=1, T_RAS=1, T_CL=2, T_WR=1,
                T_RTP=1, T_WTR=1, T_RRD=1, T_RFC=2, REF_MAX=60),
}
CASE = os.environ.get("DDRM_CASE", "d256")
P = CASES[CASE]
N = int(os.environ.get("DDRM_N", "20000"))
SEED = int(os.environ.get("DDRM_SEED", "20261021"))


def model():
    return dm.DdrMem(**{k.lower(): v for k, v in P.items()})


class Gen:
    """Command generator over a shadow of the bank state (the model's own state, read only)."""

    def __init__(self, rng, m):
        self.rng, self.m = rng, m
        self.violate = None                                     # the code to provoke next, or None
        self.hold_ref = False

    def legal(self):
        m, p, rng = self.m, self.m.p, self.rng
        nb = m.nb
        if m.g_ref < p["t_rfc"]:
            return (dm.NOP,)
        margin = p["t_ras"] + max(p["t_wr"], p["t_rtp"]) + p["t_rp"] + 12   # one PREA once every bank allows it
        if not self.hold_ref and m.ref_cnt > p["ref_max"] - margin:
            if any(m.open):                                     # close everything, then refresh
                ok = all(not m.open[b] or (m.age_act[b] >= p["t_ras"] and m.age_wr[b] >= p["t_wr"]
                                           and m.age_rd[b] >= p["t_rtp"]) for b in range(nb))
                return (dm.PREA,) if ok else (dm.NOP,)
            return (dm.REF,) if min(m.age_pre) >= p["t_rp"] else (dm.NOP,)
        b = rng.randrange(nb)
        r = rng.random()
        if m.open[b]:
            if r < 0.15:
                ok = m.age_act[b] >= p["t_ras"] and m.age_wr[b] >= p["t_wr"] and m.age_rd[b] >= p["t_rtp"]
                return (dm.PRE, b) if ok else (dm.NOP,)
            if m.age_act[b] < p["t_rcd"]:
                return (dm.NOP,)
            col = rng.randrange(1 << p["col_w"])
            if r < 0.55:
                return (dm.RD, b, col) if m.g_wr >= p["t_wtr"] else (dm.NOP,)
            strb = rng.choice([(1 << p["data_w"] // 8) - 1, rng.getrandbits(p["data_w"] // 8)])
            return (dm.WR, b, col, rng.getrandbits(p["data_w"]), strb)
        if r < 0.7 and m.age_pre[b] >= p["t_rp"] and m.g_act >= p["t_rrd"]:
            # a row inside MEM_WORDS (mostly), a few rows to reuse
            rows_in = max(1, p["mem_words"] >> (p["bank_w"] + p["col_w"]))
            row = rng.choice([0, 1, rng.randrange(rows_in)])
            return (dm.ACT, b, row)
        return (dm.NOP,)

    def bad(self, code):
        """A command breaking rule code, or None if the state does not allow it now."""
        m, p, rng = self.m, self.m.p, self.rng
        nb = m.nb
        opened = [b for b in range(nb) if m.open[b]]
        closed = [b for b in range(nb) if not m.open[b]]
        col = rng.randrange(1 << p["col_w"])
        if code == 1 and opened:
            return (dm.ACT, rng.choice(opened), 0)
        if code == 2 and closed:
            return (rng.choice([dm.RD, dm.WR]), rng.choice(closed), col, rng.getrandbits(p["data_w"]), 1)
        if code == 3:
            c = [b for b in opened if m.age_act[b] < p["t_rcd"]]
            return (dm.RD, c[0], col) if c else None
        if code == 4:
            c = [b for b in closed if m.age_pre[b] < p["t_rp"]]
            return (dm.ACT, c[0], 0) if c else None
        if code == 5:
            c = [b for b in opened if m.age_act[b] < p["t_ras"]]
            return (dm.PRE, c[0]) if c else None
        if code == 6:                                           # past T_RAS, so code 5 does not mask it
            ras = [b for b in opened if m.age_act[b] >= p["t_ras"]]
            c = [b for b in ras if m.age_wr[b] < p["t_wr"] or m.age_rd[b] < p["t_rtp"]]
            if c:
                return (dm.PRE, c[0])
            c = [b for b in ras if m.age_act[b] >= p["t_rcd"]]
            if c and m.g_ref >= p["t_rfc"]:
                return ("setup", (dm.WR, c[0], col, rng.getrandbits(p["data_w"]), 1))
            return None
        if code == 7:
            ready = [b for b in closed if m.age_pre[b] >= p["t_rp"]]
            if ready and m.g_act < p["t_rrd"]:
                return (dm.ACT, ready[0], 0)
            if len(ready) >= 2 and m.g_ref >= p["t_rfc"] and m.g_act >= p["t_rrd"]:
                return ("setup", (dm.ACT, ready[1], 0))            # the next clock's ACT comes too early
            return None
        if code == 8 and opened and m.g_wr < p["t_wtr"]:
            return (dm.RD, opened[0], col)
        if code == 9 and opened:
            return (dm.REF,)
        if code == 10:
            if m.g_ref < p["t_rfc"]:
                return (dm.PREA,)
            if not opened and min(m.age_pre) >= p["t_rp"]:
                return ("setup", (dm.REF,))                     # refresh, then a command inside T_RFC
            if all(m.age_act[b] >= p["t_ras"] and m.age_wr[b] >= p["t_wr"] and m.age_rd[b] >= p["t_rtp"]
                   for b in opened):
                return ("setup", (dm.PREA,))
            return None
        if code == 11:
            self.hold_ref = True                                # stop refreshing: the deadline passes
            return None
        if code == 12:
            rows_in = p["mem_words"] >> (p["bank_w"] + p["col_w"])
            if rows_in >= 1 << p["row_w"]:
                return None                                     # MEM_WORDS fills the address space
            c = [b for b in opened if m.row[b] >= rows_in and m.age_act[b] >= p["t_rcd"]]
            if c:
                return (dm.WR, c[0], col, 1, 1)
            c = [b for b in closed if m.age_pre[b] >= p["t_rp"]]
            if c and m.g_act >= p["t_rrd"] and m.g_ref >= p["t_rfc"]:
                return ("setup", (dm.ACT, c[0], rows_in + rng.randrange(2)))   # a legal ACT beyond MEM_WORDS
            return None
        if code == 13:
            return (7,)
        return None


@cocotb.test()
async def test_ddr_mem_exact(dut):
    """Every clock: read data and the checks equal the model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    m = model()
    g = Gen(rng, m)
    cov = collections.Counter()
    for s in ("cmd_i", "bank_i", "row_i", "col_i", "wrdata_i", "wrstrb_i"):
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    await FallingEdge(dut.clk)
    m.cycle(rst_n=0)
    written = set()
    for i in range(N):
        await FallingEdge(dut.clk)
        rst = 0
        if m.err and rng.random() < 0.2 or rng.random() < 0.0005:
            rst = 1
            cov[f"code{m.err_code}"] += int(bool(m.err))
            g.hold_ref, g.violate = False, None
        c = (dm.NOP,)
        if not rst:
            if g.violate is None and not m.err and rng.random() < 0.01:
                todo = [k for k in range(1, 14) if not cov[f"code{k}"]]  # uncovered codes first
                g.violate = rng.choice(todo) if todo and rng.random() < 0.7 else rng.randrange(1, 14)
            bc = g.bad(g.violate) if g.violate is not None else None
            if bc is not None and bc[0] == "setup":
                c = bc[1]                                       # the legal step towards the violation
            elif bc is not None:
                c, g.violate = bc, None
            elif g.violate is not None and g.violate != 11 and rng.random() < 0.02:
                g.violate = None                                # not reachable now: give up this one
            else:
                c = g.legal() if rng.random() < 0.85 else (dm.NOP,)
        cmd = c[0]
        bank = c[1] if len(c) > 1 else 0
        row = c[2] if cmd == dm.ACT else 0
        col = c[2] if cmd in (dm.RD, dm.WR) else 0
        wd = c[3] if cmd == dm.WR else 0
        ws = c[4] if cmd == dm.WR else 0
        dut.rst_n.value = 1 - rst
        dut.cmd_i.value, dut.bank_i.value, dut.row_i.value, dut.col_i.value = cmd, bank, row, col
        dut.wrdata_i.value, dut.wrstrb_i.value = wd, ws
        await Timer(1, unit="ns")
        if cmd in (dm.RD, dm.WR) and m.open[bank]:
            a = (m.row[bank] << (P["BANK_W"] + P["COL_W"])) | (bank << P["COL_W"]) | col
            if cmd == dm.RD:
                cov["read_written" if a in written else "read_unwritten"] += 1
            else:
                written.add(a)
                cov["write_partial" if ws != (1 << P["DATA_W"] // 8) - 1 else "write_full"] += 1
            cov[f"bank{bank}"] += 1
        o = m.cycle(cmd, bank, row, col, wd, ws, rst_n=1 - rst)
        got = dict(rddata_valid=int(dut.rddata_valid_o.value), err=int(dut.err_o.value),
                   err_code=int(dut.err_code_o.value), err_cnt=int(dut.err_cnt_o.value))
        for k, v in got.items():
            assert v == o[k], f"clock {i}: {k} rtl {v} model {o[k]} (cmd {c})"
        if o["rddata_valid"]:
            rd = int(dut.rddata_o.value)
            assert rd == o["rddata"], f"clock {i}: rddata rtl {rd:#x} model {o['rddata']:#x}"
            cov["reads_back_to_back"] += int(cov.get("_last_valid", -2) == i - 1)
            cov["_last_valid"] = i
    cov.pop("_last_valid", None)
    dut._log.info("%s: %d clocks compared, coverage %s", CASE, N, dict(sorted(cov.items())))
    codes = [k for k in range(1, 14) if not (k == 12 and P["MEM_WORDS"] >= 1 << (P["BANK_W"] + P["ROW_W"] + P["COL_W"]))]
    for k in [f"code{c}" for c in codes] + ["read_written", "read_unwritten", "write_partial", "reads_back_to_back"] \
            + [f"bank{b}" for b in range(1 << P["BANK_W"])]:
        assert cov[k], f"not covered: {k}"
