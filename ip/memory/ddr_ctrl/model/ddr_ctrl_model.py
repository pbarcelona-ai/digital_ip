"""ddr_ctrl model (Python model of ip/memory/ddr_ctrl/src/ddr_ctrl.sv), clock exact: a generic DDR controller with
NPORTS AXI4 slave ports in front of a DFI-style command interface (ddr_mem's), one command per clock.

AXI4 ports: full-width transfers only (AxSIZE = log2(DATA_W / 8)), INCR bursts (AxBURST 1) of AxLEN + 1 <= 256
beats, IDs passed through, the address's low log2(DATA_W / 8) bits ignored, WLAST not checked (AxLEN counts the
beats). A burst with another size or burst type answers SLVERR, one reaching beyond the memory (2 ** (BANK_W +
ROW_W + COL_W) words) DECERR; an error burst touches no memory (reads return 0 with the error, writes take
their W beats). Word address w = addr >> log2(DATA_W / 8): col = w[COL_W-1:0], bank = the next BANK_W bits,
row = the next ROW_W bits.

One burst at a time, beats in order. Each clock, in this order:
  1 refresh owed (owed > 0): PREA when a bank is open and every open bank is past T_RAS, T_WR, T_RTP; REF when
    every bank is closed and past T_RP; NOP otherwise (both also wait T_RFC after a REF). Nothing else happens.
  2 a burst active: an error burst takes one beat per clock (a read when its port's read FIFO has credit, a
    write when WVALID); else the beat's bank / row: nothing within T_RFC of a REF; a hit (bank open on the row)
    past T_RCD: RD (also past T_WTR after any WR, with read credit) or WR (WVALID: WREADY, wdata / wstrb to
    the memory); a bank open on another row: PRE once past T_RAS, T_WR, T_RTP; a closed bank: ACT once past T_RP
    and T_RRD after any ACT.
  3 no burst: the arbiter grants one request (ARREADY or AWREADY, combinational on the valid); requests are
    indexed 2 * port + (0 read, 1 write), a write eligible only while its port's B FIFO has room; PRIORITY 1:
    the lowest index wins, 0: round robin from the index after the last grant. The burst starts the next clock.
Refresh schedule: a timer counts T_REFI clocks; each period adds one owed REF (at most 15), each REF takes one.
Reads: every read beat (memory or error) enters a T_CL-deep return pipe with the memory (port, id, last, resp,
from memory); at its end the beat (the memory's word, or 0 for an error) goes into its port's read FIFO
(fallthrough_fifo, RQ_DEPTH), whose head drives R. A port's read credit counts beats issued and not yet taken
by RREADY; a read beat needs credit < RQ_DEPTH. Writes: the last beat pushes {id, resp} into the port's B FIFO
(BQ_DEPTH), whose head drives B.
Statistics (32-bit, wrapping): read beats, write beats (memory beats), ACTs, row hits (memory beats issued
without an ACT for that beat), REFs, error bursts; a CTRL write with bit 0 set clears them (the clear wins over
that clock's events). STATUS: [0] a burst active, [4:1] refreshes owed.
The bank state and the timing ages are the same as ddr_mem's (saturating at 255), so the controller never
breaks a timing rule; the test checks ddr_mem's err_o stays 0."""
import sys
from pathlib import Path

for _d in (Path(__file__).resolve().parents[2] / "ddr_mem" / "model",
           Path(__file__).resolve().parents[3] / "fifo" / "fallthrough_fifo" / "model"):
    if str(_d) not in sys.path:
        sys.path.insert(0, str(_d))
from ddr_mem_model import ACT, NOP, PRE, PREA, RD, REF, WR                     # noqa: E402
from fallthrough_fifo_model import FallthroughFifo                          # noqa: E402

AGE_MAX = 255
OKAY, SLVERR, DECERR = 0, 2, 3
M32 = 0xFFFFFFFF


class DdrCtrl:
    """ddr_ctrl with its parameters (the RTL's defaults)."""

    def __init__(self, nports=2, data_w=256, addr_w=32, id_w=4, bank_w=3, row_w=14, col_w=8, t_rcd=4, t_rp=4,
                 t_ras=10, t_cl=5, t_wr=4, t_rtp=2, t_wtr=2, t_rrd=2, t_rfc=30, t_refi=1950, priority=0,
                 rq_depth=16, bq_depth=2):
        self.p = dict(nports=nports, data_w=data_w, addr_w=addr_w, id_w=id_w, bank_w=bank_w, row_w=row_w,
                      col_w=col_w, t_rcd=t_rcd, t_rp=t_rp, t_ras=t_ras, t_cl=t_cl, t_wr=t_wr, t_rtp=t_rtp,
                      t_wtr=t_wtr, t_rrd=t_rrd, t_rfc=t_rfc, t_refi=t_refi, priority=priority, rq_depth=rq_depth,
                      bq_depth=bq_depth)
        self.nb = 1 << bank_w
        self.off = (data_w // 8).bit_length() - 1
        self.size = self.off
        self.words = 1 << (bank_w + row_w + col_w)
        self.reset()

    def reset(self):
        p, nb = self.p, self.nb
        self.open = [False] * nb
        self.row = [0] * nb
        self.age_act = [AGE_MAX] * nb
        self.age_pre = [AGE_MAX] * nb
        self.age_wr = [AGE_MAX] * nb
        self.age_rd = [AGE_MAX] * nb
        self.g_act = self.g_wr = self.g_ref = AGE_MAX
        self.ref_timer, self.owed = 0, 0
        self.busy, self.dir, self.port, self.id, self.word, self.left, self.resp = 0, 0, 0, 0, 0, 0, 0
        self.beat_act = 0
        self.last_grant = 2 * p["nports"] - 1
        self.pipe = [None] * p["t_cl"]                     # stage 0 the clock after issue, t_cl-1 the last
        self.rq = [FallthroughFifo(p["data_w"] + p["id_w"] + 3, p["rq_depth"]) for _ in range(p["nports"])]
        self.bq = [FallthroughFifo(p["id_w"] + 2, p["bq_depth"]) for _ in range(p["nports"])]
        self.cred = [0] * p["nports"]
        self.stats = dict(rd_beats=0, wr_beats=0, acts=0, hits=0, refs=0, errs=0)

    def _decode(self, w):
        p = self.p
        return (w >> p["col_w"]) & (self.nb - 1), (w >> (p["col_w"] + p["bank_w"])) & ((1 << p["row_w"]) - 1), \
            w & ((1 << p["col_w"]) - 1)

    def _pre_ok(self, b):
        p = self.p
        return self.age_act[b] >= p["t_ras"] and self.age_wr[b] >= p["t_wr"] and self.age_rd[b] >= p["t_rtp"]

    def decide(self, i):
        """This clock's combinational outputs from the state and the inputs i (per-port lists)."""
        p, n = self.p, self.p["nports"]
        d = dict(cmd=NOP, bank=0, row=0, col=0, wrdata=0, wrstrb=0, arready=[0] * n, awready=[0] * n,
                 wready=[0] * n, beat=False, rbeat=False, grant=None)
        if self.owed > 0:
            if self.g_ref >= p["t_rfc"]:
                opened = [b for b in range(self.nb) if self.open[b]]
                if opened and all(self._pre_ok(b) for b in opened):
                    d["cmd"] = PREA
                elif not opened and min(self.age_pre) >= p["t_rp"]:
                    d["cmd"] = REF
        elif self.busy:
            pt = self.port
            if self.resp:
                if self.dir == 0 and self.cred[pt] < p["rq_depth"]:
                    d["beat"] = d["rbeat"] = True
                elif self.dir == 1 and i["wvalid"][pt]:
                    d["beat"] = True
                    d["wready"][pt] = 1
            elif self.g_ref >= p["t_rfc"]:
                b, r, c = self._decode(self.word)
                if self.open[b] and self.row[b] == r:
                    if self.age_act[b] >= p["t_rcd"]:
                        if self.dir == 0:
                            if self.g_wr >= p["t_wtr"] and self.cred[pt] < p["rq_depth"]:
                                d.update(cmd=RD, bank=b, col=c, beat=True, rbeat=True)
                        elif i["wvalid"][pt]:
                            d.update(cmd=WR, bank=b, col=c, wrdata=i["wdata"][pt], wrstrb=i["wstrb"][pt], beat=True)
                            d["wready"][pt] = 1
                elif self.open[b]:
                    if self._pre_ok(b):
                        d.update(cmd=PRE, bank=b)
                elif self.age_pre[b] >= p["t_rp"] and self.g_act >= p["t_rrd"]:
                    d.update(cmd=ACT, bank=b, row=r)
        else:
            req = []
            for pt in range(n):
                req.append(i["arvalid"][pt])
                req.append(i["awvalid"][pt] and self.bq[pt].outputs()["level_o"] < p["bq_depth"])
            order = range(2 * n) if p["priority"] else [(self.last_grant + 1 + k) % (2 * n) for k in range(2 * n)]
            for k in order:
                if req[k]:
                    d["grant"] = k
                    (d["arready"] if k % 2 == 0 else d["awready"])[k // 2] = 1
                    break
        return d

    def outputs(self, i):
        d = self.decide(i)
        p, n = self.p, self.p["nports"]
        o = dict(cmd=d["cmd"], bank=d["bank"], row=d["row"], col=d["col"], wrdata=d["wrdata"], wrstrb=d["wrstrb"],
                 arready=d["arready"], awready=d["awready"], wready=d["wready"], stats=dict(self.stats),
                 status=self.status())
        dw, iw = p["data_w"], p["id_w"]
        o["rvalid"], o["rdata"], o["rid"], o["rresp"], o["rlast"] = [], [], [], [], []
        o["bvalid"], o["bid"], o["bresp"] = [], [], []
        for pt in range(n):
            r = self.rq[pt].outputs()
            v = r["m_data_o"] or 0
            o["rvalid"].append(r["m_valid_o"])
            o["rdata"].append(v & ((1 << dw) - 1))
            o["rid"].append((v >> dw) & ((1 << iw) - 1))
            o["rresp"].append((v >> (dw + iw)) & 3)
            o["rlast"].append((v >> (dw + iw + 2)) & 1)
            b = self.bq[pt].outputs()
            bv = b["m_data_o"] or 0
            o["bvalid"].append(b["m_valid_o"])
            o["bid"].append(bv & ((1 << iw) - 1))
            o["bresp"].append((bv >> iw) & 3)
        return o, d

    def status(self):
        """STATUS: [0] a burst active, [4:1] refreshes owed."""
        return self.busy | self.owed << 1

    def cycle(self, i, rddata=0, rst_n=1, ctrl_wr=0, ctrl=0):
        """The outputs during this clock (inputs i: per-port lists arvalid, araddr, arlen, arsize, arburst, arid,
        awvalid, awaddr, awlen, awsize, awburst, awid, wvalid, wdata, wstrb, rready, bready; rddata the memory's
        read word of this clock; ctrl_wr / ctrl: a CTRL write, bit 0 clears the statistics), then the clock edge."""
        o, d = self.outputs(i)
        if not rst_n:
            self.reset()
            return o
        p, n = self.p, self.p["nports"]
        sat = lambda a: min(a + 1, AGE_MAX)                                          # noqa: E731
        # read return: the pipe's last stage into its port's FIFO (this clock), R pops
        out = self.pipe[-1]
        for pt in range(n):
            push = out is not None and out[1] == pt
            data = 0
            if push:
                _, _, rid, last, resp, mem = out
                data = (rddata if mem else 0) | rid << p["data_w"] | resp << (p["data_w"] + p["id_w"]) \
                    | last << (p["data_w"] + p["id_w"] + 2)
            popped = o["rvalid"][pt] and i["rready"][pt]
            self.rq[pt].cycle(data, int(push), int(i["rready"][pt]))
            issued = int(d["rbeat"] and self.port == pt)
            self.cred[pt] += issued - int(popped)
        # B FIFOs: the last write beat pushes, B pops
        for pt in range(n):
            push = d["beat"] and self.dir == 1 and self.port == pt and self.left == 1
            self.bq[pt].cycle(self.id | self.resp << p["id_w"], int(push), int(i["bready"][pt]))
        # the return pipe
        entry = None
        if d["rbeat"]:
            entry = (1, self.port, self.id, int(self.left == 1), self.resp, int(self.resp == OKAY))
        self.pipe = [entry] + self.pipe[:-1]
        # statistics
        st = self.stats
        if d["cmd"] == RD:
            st["rd_beats"] = (st["rd_beats"] + 1) & M32
        if d["cmd"] == WR:
            st["wr_beats"] = (st["wr_beats"] + 1) & M32
        if d["cmd"] in (RD, WR) and not self.beat_act:
            st["hits"] = (st["hits"] + 1) & M32
        if d["cmd"] == ACT:
            st["acts"] = (st["acts"] + 1) & M32
        if d["cmd"] == REF:
            st["refs"] = (st["refs"] + 1) & M32
        # bank state and ages (as ddr_mem)
        self.age_act = [sat(a) for a in self.age_act]
        self.age_pre = [sat(a) for a in self.age_pre]
        self.age_wr = [sat(a) for a in self.age_wr]
        self.age_rd = [sat(a) for a in self.age_rd]
        self.g_act, self.g_wr, self.g_ref = sat(self.g_act), sat(self.g_wr), sat(self.g_ref)
        c, b = d["cmd"], d["bank"]
        if c == ACT:
            self.open[b], self.row[b], self.age_act[b], self.g_act = True, d["row"], 0, 0
            self.beat_act = 1
        elif c == WR:
            self.age_wr[b], self.g_wr = 0, 0
        elif c == RD:
            self.age_rd[b] = 0
        elif c == PRE:
            self.open[b], self.age_pre[b] = False, 0
        elif c == PREA:
            for k in range(self.nb):
                if self.open[k]:
                    self.open[k], self.age_pre[k] = False, 0
        elif c == REF:
            self.g_ref = 0
        # refresh schedule
        add = int(self.ref_timer == p["t_refi"] - 1)
        self.ref_timer = 0 if add else self.ref_timer + 1
        self.owed = min(self.owed + add - int(c == REF), 15)
        # the burst
        if d["beat"]:
            self.beat_act = 0
            self.word = (self.word + 1) & ((1 << (p["addr_w"] - self.off)) - 1)
            self.left -= 1
            if self.left == 0:
                self.busy = 0
        if d["grant"] is not None:
            k = d["grant"]
            pt, wr = k // 2, k % 2
            pre = "aw" if wr else "ar"
            addr, ln = i[pre + "addr"][pt], i[pre + "len"][pt]
            w = addr >> self.off
            if i[pre + "size"][pt] != self.size or i[pre + "burst"][pt] != 1:
                resp = SLVERR
            elif w + ln >= self.words:
                resp = DECERR
            else:
                resp = OKAY
            self.busy, self.dir, self.port, self.id = 1, wr, pt, i[pre + "id"][pt]
            self.word, self.left, self.resp, self.beat_act = w, ln + 1, resp, 0
            self.last_grant = k
            if resp:
                st["errs"] = (st["errs"] + 1) & M32
        if ctrl_wr and ctrl & 1:                                  # the clear wins over this clock's events
            for k in st:
                st[k] = 0
        return o
