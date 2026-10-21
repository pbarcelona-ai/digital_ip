"""ddr_mem model (Python model of ip/memory/ddr_mem/src/ddr_mem.sv), clock exact: a generic DDR memory behind a
DFI-style command interface, one command per clock (controller clock = DFI clock, 1:1), with the timing
checks of a JEDEC SDRAM. Simulation model of an external memory, not synthesizable logic.

Commands (cmd): 0 NOP, 1 ACT (open row in bank), 2 RD (bank, col), 3 WR (bank, col, wrdata, wrstrb), 4 PRE (close
bank; a PRE of a closed bank is a no-op), 5 PREA (close every bank), 6 REF (refresh, every bank closed), 7 is an
illegal command. Word address of an access: (row << (BANK_W + COL_W)) | (bank << COL_W) | col, row = the bank's open
row; it must be below MEM_WORDS. A RD presented in clock n gives rddata_valid with the word in clock n + T_CL
(the word as stored at clock n: a WR in the same clock is not seen); a WR writes the bytes with wrstrb set in
clock n. Unwritten words read 0. A RD or WR to a closed bank or beyond MEM_WORDS returns 0 / writes nothing.

Timing (clocks between the clocks of two commands): per bank the ages since its last ACT, PRE, WR and RD, and
globally since the last ACT (any bank), WR (any bank) and REF, each saturating at AGE_MAX (255); the timing
parameters must be below AGE_MAX. Checks, each a violation code (the command is still applied):
  1 ACT to an open bank            2 RD / WR to a closed bank       3 RD / WR before T_RCD after the ACT
  4 ACT before T_RP after the bank's PRE; REF before T_RP after any bank's PRE
  5 PRE before T_RAS after the ACT  6 PRE before T_WR after a WR or T_RTP after a RD of the bank
  7 ACT before T_RRD after any ACT  8 RD before T_WTR after any WR  9 REF with a bank open
  10 a command (not NOP) before T_RFC after a REF                   11 refresh overdue: more than REF_MAX clocks
     since reset or the last REF (flagged once until the next REF)  12 address at or beyond MEM_WORDS
  13 illegal command
PREA checks 5 and 6 for every open bank. err (sticky) is set at the first violation, err_code holds the
smallest code of the first clock with violations, err_cnt counts the clocks with at least one violation
(saturating at 0xFFFF). All outputs are registered: they change at the clock edge after the command."""

AGE_MAX = 255
NOP, ACT, RD, WR, PRE, PREA, REF = range(7)


class DdrMem:
    """ddr_mem with its parameters (the RTL's defaults)."""

    def __init__(self, data_w=256, bank_w=3, row_w=14, col_w=8, mem_words=1 << 16, t_rcd=4, t_rp=4, t_ras=10,
                 t_cl=5, t_wr=4, t_rtp=2, t_wtr=2, t_rrd=2, t_rfc=30, ref_max=9 * 1950):
        self.p = dict(data_w=data_w, bank_w=bank_w, row_w=row_w, col_w=col_w, mem_words=mem_words, t_rcd=t_rcd,
                      t_rp=t_rp, t_ras=t_ras, t_cl=t_cl, t_wr=t_wr, t_rtp=t_rtp, t_wtr=t_wtr, t_rrd=t_rrd,
                      t_rfc=t_rfc, ref_max=ref_max)
        for t in ("t_rcd", "t_rp", "t_ras", "t_cl", "t_wr", "t_rtp", "t_wtr", "t_rrd", "t_rfc"):
            if not 1 <= self.p[t] < AGE_MAX:
                raise ValueError(f"{t} must be 1 .. {AGE_MAX - 1}")
        self.nb = 1 << bank_w
        self.mem = {}
        self.reset()

    def reset(self):
        nb = self.nb
        self.open = [False] * nb
        self.row = [0] * nb
        self.age_act = [AGE_MAX] * nb
        self.age_pre = [AGE_MAX] * nb
        self.age_wr = [AGE_MAX] * nb
        self.age_rd = [AGE_MAX] * nb
        self.g_act = self.g_wr = self.g_ref = AGE_MAX
        self.ref_cnt = 0                                     # clocks since reset / the last REF
        self.overdue = False
        self.pipe = [(0, 0)] * self.p["t_cl"]                # (valid, data): pipe[0] leaves next
        self.err, self.err_code, self.err_cnt = 0, 0, 0
        self.rd_valid, self.rd_data = 0, 0

    def word(self, addr):
        return self.mem.get(addr, 0)

    def outputs(self):
        return dict(rddata_valid=self.rd_valid, rddata=self.rd_data, err=self.err, err_code=self.err_code,
                    err_cnt=self.err_cnt)

    def cycle(self, cmd=NOP, bank=0, row=0, col=0, wrdata=0, wrstrb=0, rst_n=1):
        """The outputs during this clock, then the clock edge with this clock's command."""
        o = self.outputs()
        if not rst_n:
            self.reset()
            return o
        p = self.p
        v = set()
        addr = None
        if cmd != NOP and self.g_ref < p["t_rfc"]:
            v.add(10)
        if cmd == ACT:
            if self.open[bank]:
                v.add(1)
            if self.age_pre[bank] < p["t_rp"]:
                v.add(4)
            if self.g_act < p["t_rrd"]:
                v.add(7)
        elif cmd in (RD, WR):
            if not self.open[bank]:
                v.add(2)
            else:
                if self.age_act[bank] < p["t_rcd"]:
                    v.add(3)
                a = (self.row[bank] << (p["bank_w"] + p["col_w"])) | (bank << p["col_w"]) | col
                if a >= p["mem_words"]:
                    v.add(12)
                else:
                    addr = a
            if cmd == RD and self.g_wr < p["t_wtr"]:
                v.add(8)
        elif cmd in (PRE, PREA):
            for b in (range(self.nb) if cmd == PREA else [bank]):
                if self.open[b]:
                    if self.age_act[b] < p["t_ras"]:
                        v.add(5)
                    if self.age_wr[b] < p["t_wr"] or self.age_rd[b] < p["t_rtp"]:
                        v.add(6)
        elif cmd == REF:
            if any(self.open):
                v.add(9)
            if min(self.age_pre) < p["t_rp"]:
                v.add(4)
        elif cmd != NOP:
            v.add(13)
        # the refresh deadline (counted in every clock)
        ref_cnt = 0 if cmd == REF else min(self.ref_cnt + 1, 1 << 24)
        if cmd != REF and not self.overdue and self.ref_cnt + 1 > p["ref_max"]:
            v.add(11)
            self.overdue = True
        if cmd == REF:
            self.overdue = False
        self.ref_cnt = ref_cnt
        # read data: the word before this clock's write
        rd_word = self.word(addr) if (cmd == RD and addr is not None) else 0
        self.pipe = self.pipe[1:] + [(int(cmd == RD), rd_word)]
        self.rd_valid, self.rd_data = self.pipe[0][0], self.pipe[0][1]
        # state and ages
        sat = lambda a: min(a + 1, AGE_MAX)                                          # noqa: E731
        self.age_act = [sat(a) for a in self.age_act]
        self.age_pre = [sat(a) for a in self.age_pre]
        self.age_wr = [sat(a) for a in self.age_wr]
        self.age_rd = [sat(a) for a in self.age_rd]
        self.g_act, self.g_wr, self.g_ref = sat(self.g_act), sat(self.g_wr), sat(self.g_ref)
        if cmd == ACT:
            self.open[bank], self.row[bank] = True, row
            self.age_act[bank] = 0
            self.g_act = 0
        elif cmd == WR:
            self.age_wr[bank] = 0
            self.g_wr = 0
            if addr is not None:
                old = self.word(addr)
                for i in range(p["data_w"] // 8):
                    if wrstrb >> i & 1:
                        old = (old & ~(0xFF << 8 * i)) | (wrdata & (0xFF << 8 * i))
                self.mem[addr] = old
        elif cmd == RD:
            self.age_rd[bank] = 0
        elif cmd == PRE:
            if self.open[bank]:
                self.open[bank] = False
                self.age_pre[bank] = 0
        elif cmd == PREA:
            for b in range(self.nb):
                if self.open[b]:
                    self.open[b] = False
                    self.age_pre[b] = 0
        elif cmd == REF:
            self.g_ref = 0
        if v:
            if not self.err:
                self.err, self.err_code = 1, min(v)
            self.err_cnt = min(self.err_cnt + 1, 0xFFFF)
        return o
