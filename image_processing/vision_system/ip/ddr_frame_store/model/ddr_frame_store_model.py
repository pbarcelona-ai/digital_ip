"""ddr_frame_store model (Python model of image_processing/vision_system/ip/ddr_frame_store/src/ddr_frame_store.sv),
clock exact: vision_system's frame store in DDR, an AXI4 master of the shared controller (ip/memory/ddr_ctrl).

Frame store ports as vision_system's other stores (frame_buffer, ext_frame_buffer), plus the buffer selects:
  - Two frame buffers in DDR at byte addresses BASE0 / BASE1 (wr_buf / rd_buf choose one per access); pixel
    address a of buffer b is the 32-bit slot at BASE<b> + 4 a (the pixel in its low PIX_W bits, the rest 0).
    Every slot of a buffer must lie in the memory behind the controller (an error response is not reported:
    BRESP / RRESP are ignored, the read data used as returned).
  - Writes (wr_en with wr_ready, wr_addr, wr_data, wr_buf): a combiner gathers the pixels of one DATA_W-bit
    word (PPB = DATA_W / 32 slots, byte strobes per slot). A write to another word pushes the gathered word
    into the write queue (WQ_DEPTH words) and starts the next; a word whose slots are all written is pushed at
    once; a partial word is pushed after FLUSH_IDLE clocks without a write (when the queue has room).
    wr_ready = the queue is not full. Each queued word becomes one single-beat AXI write (AWLEN 0, full size,
    INCR, AWID WR_ID, WLAST 1): AW and W are presented together, each dropped at its handshake; the next word
    is loaded (popped) once both have gone, while fewer than OUT_MAX writes wait for B (BREADY is always 1).
    wr_idle = nothing gathered, queued, presented or waiting for B: every write has reached the memory.
  - Reads (rd_en with rd_ready, rd_addr0..3, rd_buf): a direct-mapped cache of CACHE_LINES lines of LINE_PIX
    pixels (line l = slot index >> log2(LINE_PIX) over the whole address space, set l mod CACHE_LINES, tag
    l / CACHE_LINES), its RAM in four copies (one read port per address, every copy written by a fill). The
    request in lookup looks its four addresses up every clock: each one that hits and is not yet read is read
    from its copy (the word the next clock, the pixel captured then); a miss loads the line of the first
    address not read and missing: one AXI read burst of LINE_PIX / PPB beats (ARID RD_ID, full size, INCR;
    RREADY is 1 while loading), each beat written as it arrives, the line valid after the last; the lookups
    then go on. The request completes in the clock its last addresses are read; the clock after that its
    pixels are on rd_data0..3 with rd_valid (registers). rd_ready = no request in lookup, or the one in lookup
    completing this clock (so the next is taken in that clock: one request per clock while the lines are
    cached; request to rd_valid 3 clocks). LINE_PIX: 2 .. 256 beats, at most 1024 pixels (a fill never
    crosses 4 KB).
  - rd_flush (taken while rd_ready is high, before a request in the same clock): every cache line becomes
    invalid. The cache does not see writes: a writer pulses rd_flush after a buffer it has rewritten is
    complete (wr_idle) and before reading it.
  - clear (the user's soft reset, e.g. vision_system's CTRL[0]): the read request in lookup is dropped
    without rd_valid - at once, or after its line fill's last beat during a fill (an AXI burst is always
    completed) - and so is a completed request's rd_valid due in that clock; rd_en is ignored in that clock. The write side is not affected (gathered and
    queued words are written), nor are the cache lines.
All outputs are registers or functions of registers (no input reaches an output in the same clock).
Reset (synchronous, active low; the controller's reset, so no AXI transaction is abandoned): empty queue,
nothing gathered or presented, no read active, every line invalid (the cache RAM keeps its contents)."""



class DdrFrameStore:
    """ddr_frame_store with its parameters."""

    def __init__(self, pix_w=24, addr_w=19, data_w=256, axi_addr_w=32, id_w=4, base0=0, base1=None, line_pix=32,
                 cache_lines=64, wq_depth=8, flush_idle=8, out_max=8, wr_id=0, rd_id=1):
        ppb = data_w // 32
        if data_w < 64 or data_w & (data_w - 1):
            raise ValueError("DATA_W must be a power of two >= 64")
        for n, v in (("LINE_PIX", line_pix), ("CACHE_LINES", cache_lines), ("WQ_DEPTH", wq_depth)):
            if v < 2 or v & (v - 1):
                raise ValueError(f"{n} must be a power of two >= 2")
        if line_pix < 2 * ppb or line_pix // ppb > 256 or line_pix > 1024:
            raise ValueError("LINE_PIX must be 2 .. 256 beats of DATA_W / 32 pixels, at most 1024 pixels (4 KB)")
        if not 1 <= flush_idle <= 255 or not 1 <= out_max <= 255:
            raise ValueError("FLUSH_IDLE and OUT_MAX must be 1 .. 255")
        self.pix_w, self.addr_w, self.data_w, self.axi_addr_w, self.id_w = pix_w, addr_w, data_w, axi_addr_w, id_w
        self.base = [base0, (1 << (addr_w + 2)) if base1 is None else base1]
        self.ppb, self.off = ppb, (data_w // 8).bit_length() - 1
        self.line_pix, self.lb, self.beats = line_pix, line_pix.bit_length() - 1, line_pix // ppb
        self.cache_lines, self.wq_depth, self.flush_idle, self.out_max = cache_lines, wq_depth, flush_idle, out_max
        self.wr_id, self.rd_id = wr_id, rd_id
        self.waw = axi_addr_w - self.off                         # word address bits
        self.ram = [None] * (cache_lines * self.beats)           # None: never written (X in the RTL); the four
        self.ram_q = [None] * 4                                  # copies hold the same words: one list
        self.reset()

    def reset(self):
        # write side
        self.cv, self.cw, self.cdata, self.cstrb, self.idle = 0, 0, 0, 0, 0
        self.wq = []                                             # (word, data, strb), oldest first
        self.aw_v = self.w_v = 0
        self.aw_word, self.w_data, self.w_strb = 0, 0, 0
        self.outst = 0
        # read side
        self.lv, self.fill = 0, 0                                # a request in lookup; a line fill
        self.slot = [0] * 4                                      # the four slot indices of the request
        self.got = [0] * 4                                       # its addresses read
        self.rp = [0] * 4                                        # read last clock (the word on the copy's output)
        self.rsel = [0] * 4                                      # its pixel in the word
        self.cap = [0] * 4                                       # captured pixels of the request in lookup
        self.out = [0] * 4
        self.fin = 0                                             # the request completed last clock
        self.valid = [0] * self.cache_lines
        self.tag = [0] * self.cache_lines
        self.fill_set, self.fill_beat, self.drop = 0, 0, 0
        self.ar_v, self.ar_addr = 0, 0
        self.rd_valid = 0

    def outputs(self):
        full = (1 << (self.data_w // 8)) - 1
        return dict(
            wr_ready=int(len(self.wq) < self.wq_depth),
            wr_idle=int(not self.cv and not self.wq and not self.aw_v and not self.w_v and self.outst == 0),
            rd_ready=int(not self.lv or (not self.fill and self._all_in())),
            rd_valid=self.rd_valid,
            rd_data=list(self.out),
            awvalid=self.aw_v, awaddr=(self.aw_word << self.off) & ((1 << self.axi_addr_w) - 1), awlen=0,
            awsize=self.off, awburst=1, awid=self.wr_id,
            wvalid=self.w_v, wdata=self.w_data, wstrb=self.w_strb & full, wlast=1, bready=1,
            arvalid=self.ar_v, araddr=self.ar_addr, arlen=self.beats - 1, arsize=self.off, arburst=1,
            arid=self.rd_id, rready=int(self.fill))

    def _look(self, t):
        """(line, set, tag) of address t of the request in lookup."""
        line = self.slot[t] >> self.lb
        return line, line % self.cache_lines, line // self.cache_lines

    def _hit(self, t):
        _, st, tg = self._look(t)
        return self.valid[st] and self.tag[st] == tg

    def _all_in(self):
        return all(self.got[t] or self._hit(t) for t in range(4))

    def _slot(self, buf, addr):
        """The 32-bit slot index of pixel addr in buffer buf."""
        return ((self.base[buf & 1] >> 2) + (addr & ((1 << self.addr_w) - 1))) & ((1 << (self.axi_addr_w - 2)) - 1)

    def cycle(self, i, rst_n=1):
        """The outputs during this clock (inputs i: wr_en, wr_addr, wr_data, wr_buf, rd_en, rd_addr (four),
        rd_buf, rd_flush, clear, awready, wready, bvalid, arready, rvalid, rdata), then the clock edge."""
        o = self.outputs()
        if not rst_n:
            self.reset()
            return o
        g = lambda k: i.get(k, 0)                                # noqa: E731
        pm = (1 << self.pix_w) - 1
        # ---------------- write side
        level = len(self.wq)
        push = None
        wr = g("wr_en") and o["wr_ready"]
        if wr:
            s = self._slot(g("wr_buf"), g("wr_addr"))
            word, k = s // self.ppb, s % self.ppb
            if self.cv and word != self.cw:
                push = (self.cw, self.cdata, self.cstrb)
                self.cdata, self.cstrb = 0, 0
            elif not self.cv:
                self.cdata, self.cstrb = 0, 0
            self.cv, self.cw = 1, word
            self.cdata = (self.cdata & ~(0xFFFFFFFF << 32 * k)) | ((g("wr_data") & pm) << 32 * k)
            self.cstrb |= 0xF << 4 * k
            if push is None and self.cstrb == (1 << (self.data_w // 8)) - 1:
                push = (self.cw, self.cdata, self.cstrb)
                self.cv = 0
            self.idle = 0
        elif self.cv:
            if self.idle == self.flush_idle - 1 and level < self.wq_depth:
                push = (self.cw, self.cdata, self.cstrb)
                self.cv, self.idle = 0, 0
            else:
                self.idle = min(self.idle + 1, self.flush_idle - 1)
        # the AXI write engine (the queue's head is loaded once AW and W have both gone)
        b_done = g("bvalid") and o["bready"]
        if self.aw_v and g("awready"):
            self.aw_v = 0
        if self.w_v and g("wready"):
            self.w_v = 0
        load = not o["awvalid"] and not o["wvalid"] and level > 0 and self.outst < self.out_max
        if load:
            self.aw_word, self.w_data, self.w_strb = self.wq.pop(0)
            self.aw_v = self.w_v = 1
        self.outst += int(load) - int(b_done)
        if push is not None:
            self.wq.append(push)
        # ---------------- read side
        clear = g("clear")
        look = self.lv and not self.fill
        hit = [self._hit(t) for t in range(4)]
        all_in = all(self.got[t] or hit[t] for t in range(4))
        done = look and not clear and all_in
        miss = look and not clear and not all_in
        rd_tap = [int(look and not clear and not self.got[t] and hit[t]) for t in range(4)]
        accept = g("rd_en") and o["rd_ready"] and not clear
        # the words read last clock: into the outputs (their request completed) or the capture
        for t in range(4):
            if self.rp[t]:
                w = self.ram_q[t]
                v = ((w >> self.pix_w * self.rsel[t]) & pm) if w is not None else None
            if self.fin:
                self.out[t] = v if self.rp[t] else self.cap[t]
            elif self.rp[t]:
                self.cap[t] = v
        self.rd_valid = int(self.fin and not clear)
        self.fin = int(done)
        for t in range(4):                                       # the reads of this clock (synchronous copies)
            if rd_tap[t]:
                _, st, _ = self._look(t)
                self.ram_q[t] = self.ram[st * self.beats + (self.slot[t] % self.line_pix) // self.ppb]
                self.rsel[t] = self.slot[t] % self.ppb
        self.rp = rd_tap
        self.got = [int(self.got[t] or rd_tap[t]) for t in range(4)]
        if g("rd_flush") and o["rd_ready"]:
            self.valid = [0] * self.cache_lines
        if look and clear:                                       # the request dropped at once
            self.lv = 0
        elif done:
            self.lv = 0
        if accept:
            self.lv, self.got = 1, [0] * 4
            self.slot = [self._slot(g("rd_buf"), a) for a in i["rd_addr"]]
        fill_was = self.fill
        if miss:                                                 # the first missing address's line
            mk = next(t for t in range(4) if not self.got[t] and not hit[t])
            line, st, tg = self._look(mk)
            self.valid[st], self.tag[st] = 0, tg
            self.fill_set, self.fill_beat = st, 0
            self.ar_v = 1
            self.ar_addr = (line << (self.lb + 2)) & ((1 << self.axi_addr_w) - 1)
            self.fill = 1
        if fill_was:
            if self.ar_v and g("arready"):
                self.ar_v = 0
            drop = self.drop or clear
            if g("rvalid"):
                d = g("rdata")
                self.ram[self.fill_set * self.beats + self.fill_beat] = \
                    sum(((d >> 32 * k) & pm) << self.pix_w * k for k in range(self.ppb))
                if self.fill_beat == self.beats - 1:
                    self.valid[self.fill_set] = 1
                    self.fill = 0
                    if drop:                                     # dropped: the burst completed, no lookup
                        self.lv = 0
                    drop = 0
                self.fill_beat = (self.fill_beat + 1) % self.beats
            self.drop = drop
        return o
