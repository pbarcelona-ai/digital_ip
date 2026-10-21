"""ext_frame_buffer model (Python model of image_processing/vision_system/ip/ext_frame_buffer/src/
ext_frame_buffer.sv), clock exact: an SDR SDRAM frame store with a write FIFO and four serialized reads.
  Init: INIT_WAIT_CYCLES, precharge all, two auto refreshes, mode register (CAS latency, burst 1), then idle.
  Writes: queued in a FIFO_DEPTH FIFO (wr_ready = initialized, no refresh due, room); each becomes ACTIVATE (if
  its row is not open, after a PRECHARGE once tRAS has passed and the last write's tWR) and WRITE.
  Reads: rd_ready = initialized, no read active, FIFO empty; a read takes four addresses and reads them one by
  one (ACTIVATE as needed, READ, CAS_LATENCY + 1 clocks), rd_valid one clock with the four words.
  Refresh: due every REFRESH_INTERVAL_CYCLES clocks on a free-running schedule (the count runs every clock once
  initialized, a REFRESH takes one interval off it), served from idle (precharging an open row first).
  Address: row = addr >> COL_W, column = the low COL_W bits, bank 0; the pixel in DQ[PIX_W-1:0].
cycle(inputs) returns the outputs during that clock (the command pins, the ready / idle flags and the registered
read results) and then applies the clock edge. The SDRAM is modelled ideally: a WRITE stores the data at (row,
column), and the data captured at the end of a read is the word of that read's (row, column) (0 if never
written); the cocotb responder drives DQ the same way."""

(ST_INIT_WAIT, ST_INIT_PRE, ST_INIT_RP, ST_INIT_REF1, ST_INIT_RFC1, ST_INIT_REF2, ST_INIT_RFC2, ST_INIT_MODE,
 ST_INIT_MRD, ST_IDLE, ST_PRE, ST_RP, ST_ACT, ST_RCD, ST_READ, ST_CAS, ST_WRITE, ST_REFRESH, ST_RFC) = range(19)


class ExtFrameBuffer:
    """ext_frame_buffer with its parameters (the RTL's defaults)."""

    def __init__(self, pix_w=24, col_w=10, a_w=13, fifo_depth=32, init_wait=20000, t_rp=2, t_rcd=2, t_ras=5,
                 t_rfc=7, t_mrd=2, t_wr=2, cas=2, refresh_interval=780):
        self.pix_w, self.col_w, self.a_w, self.depth = pix_w, col_w, a_w, fifo_depth
        self.t = dict(rp=t_rp, rcd=t_rcd, ras=t_ras, rfc=t_rfc, mrd=t_mrd, wr=t_wr, cas=cas, ref=refresh_interval)
        self.mode_reg = ((cas << 4) | 0x200) & ((1 << a_w) - 1)
        self.sdram = {}
        self.s = dict(state=ST_INIT_WAIT, wait=init_wait, init=0, orv=0, orow=0, rdue=0, rcnt=0, rage=0, wage=0,
                      rap=0, rptr=0, wptr=0, cnt=0, rindex=0, ract=0, rvalid=0, rdata=[0, 0, 0, 0],
                      raddr=[0, 0, 0, 0], fa=[0] * fifo_depth, fd=[0] * fifo_depth, last_read=0)

    def _cur(self, s):
        addr = s["raddr"][s["rindex"]] if s["ract"] else s["fa"][s["rptr"]]
        return addr, (addr >> self.col_w) & ((1 << self.a_w) - 1), addr & ((1 << self.col_w) - 1)

    def cycle(self, wr_en=0, wr_addr=0, wr_data=0, rd_en=0, rd_addr=(0, 0, 0, 0)):
        s, t = self.s, self.t
        st = s["state"]
        _, row, col = self._cur(s)
        wr_ready = int(s["init"] and not s["rdue"] and s["cnt"] < self.depth)
        push = int(bool(wr_en) and wr_ready)
        pop = int(st == ST_WRITE)
        rd_ready = int(s["init"] and not s["ract"] and s["cnt"] == 0)
        ras = cas = we = 1
        a, dq_oe, dq_out = 0, 0, 0
        if st in (ST_INIT_PRE, ST_PRE):
            ras, we, a = 0, 0, 1 << 10
        elif st in (ST_INIT_REF1, ST_INIT_REF2, ST_REFRESH):
            ras, cas = 0, 0
        elif st == ST_INIT_MODE:
            ras, cas, we, a = 0, 0, 0, self.mode_reg
        elif st == ST_ACT:
            ras, a = 0, row
        elif st == ST_READ:
            cas, a = 0, col
        elif st == ST_WRITE:
            cas, we, a, dq_oe, dq_out = 0, 0, col, 1, s["fd"][s["rptr"]]
        out = dict(wr_ready=wr_ready, rd_ready=rd_ready, rd_valid=s["rvalid"], rd_data=list(s["rdata"]),
                   wr_idle=int(s["init"] and s["cnt"] == 0 and not pop and s["wage"] == 0),
                   cke=int(st != ST_INIT_WAIT), ras_n=ras, cas_n=cas, we_n=we, a=a, dq_oe=dq_oe, dq_out=dq_out)
        # the SDRAM sees the command at this edge
        if st == ST_WRITE:
            self.sdram[(row, col)] = dq_out
        if st == ST_READ:
            s["last_read"] = self.sdram.get((row, col), 0)
        # ---- clock edge (nonblocking: n from the old values s, later assignments win)
        n = dict(s, rdata=list(s["rdata"]), raddr=list(s["raddr"]), fa=list(s["fa"]), fd=list(s["fd"]))
        n["rvalid"] = 0
        if s["wage"]:
            n["wage"] = s["wage"] - 1
        if s["orv"] and s["rage"] < t["ras"]:
            n["rage"] = s["rage"] + 1
        if s["init"]:                                          # free-running schedule
            if st == ST_REFRESH:
                n["rcnt"], n["rdue"] = s["rcnt"] + 1 - t["ref"], 0
            else:
                n["rcnt"] = s["rcnt"] + 1
                if s["rcnt"] + 1 >= t["ref"]:
                    n["rdue"] = 1
        if push:
            n["fa"][s["wptr"]], n["fd"][s["wptr"]] = wr_addr, wr_data
            n["wptr"] = (s["wptr"] + 1) % self.depth
        if pop:
            n["rptr"] = (s["rptr"] + 1) % self.depth
        n["cnt"] = s["cnt"] + push - pop
        if rd_en and rd_ready:
            n["raddr"], n["rindex"], n["ract"] = list(rd_addr), 0, 1

        def wait_then(nxt):
            if s["wait"] <= 1:
                n["state"] = nxt
            else:
                n["wait"] = s["wait"] - 1
        if st == ST_INIT_WAIT:
            wait_then(ST_INIT_PRE)
        elif st == ST_INIT_PRE:
            n["orv"], n["wait"], n["state"] = 0, t["rp"], ST_INIT_RP
        elif st == ST_INIT_RP:
            wait_then(ST_INIT_REF1)
        elif st in (ST_INIT_REF1, ST_INIT_REF2):
            n["wait"], n["state"] = t["rfc"], st + 1
        elif st == ST_INIT_RFC1:
            wait_then(ST_INIT_REF2)
        elif st == ST_INIT_RFC2:
            wait_then(ST_INIT_MODE)
        elif st == ST_INIT_MODE:
            n["wait"], n["state"] = t["mrd"], ST_INIT_MRD
        elif st == ST_INIT_MRD:
            if s["wait"] <= 1:
                n["init"], n["rcnt"], n["state"] = 1, 0, ST_IDLE
            else:
                n["wait"] = s["wait"] - 1
        elif st == ST_IDLE:
            if s["rdue"] and s["wage"] == 0:
                if s["orv"]:
                    if s["rage"] >= t["ras"]:
                        n["rap"], n["state"] = 1, ST_PRE
                else:
                    n["state"] = ST_REFRESH
            elif s["ract"] or s["cnt"]:
                if s["orv"] and s["orow"] != row:
                    if s["wage"] == 0 and s["rage"] >= t["ras"]:
                        n["rap"], n["state"] = 0, ST_PRE
                elif s["orv"]:
                    if s["ract"]:
                        if s["wage"] == 0:
                            n["state"] = ST_READ
                    else:
                        n["state"] = ST_WRITE
                else:
                    n["state"] = ST_ACT
        elif st == ST_PRE:
            n["orv"], n["rage"], n["wait"], n["state"] = 0, 0, t["rp"], ST_RP
        elif st == ST_RP:
            wait_then(ST_REFRESH if s["rap"] else ST_ACT)
        elif st == ST_ACT:
            n["orow"], n["orv"], n["rage"], n["wait"], n["state"] = row, 1, 0, t["rcd"], ST_RCD
        elif st == ST_RCD:
            wait_then(ST_READ if s["ract"] else ST_WRITE)
        elif st == ST_READ:
            n["wait"], n["state"] = t["cas"] + 1, ST_CAS
        elif st == ST_CAS:
            if s["wait"] <= 1:
                n["rdata"][s["rindex"]] = s["last_read"] & ((1 << self.pix_w) - 1)
                if s["rindex"] == 3:
                    n["rvalid"], n["ract"] = 1, 0
                else:
                    n["rindex"] = s["rindex"] + 1
                n["state"] = ST_IDLE
            else:
                n["wait"] = s["wait"] - 1
        elif st == ST_WRITE:
            n["wage"], n["state"] = t["wr"], ST_IDLE
        elif st == ST_REFRESH:
            n["orv"], n["wait"], n["state"] = 0, t["rfc"], ST_RFC
        elif st == ST_RFC:
            wait_then(ST_IDLE)
        self.s = n
        return out
