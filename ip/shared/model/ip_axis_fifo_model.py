"""ip_axis_fifo model (Python model of ip/shared/src/fifo/ip_axis_fifo.sv), clock accurate: a RAM of DEPTH
words, a memory read register and an output register (2-register read pipeline).

Per clock (the RTL's combinational terms from the state of that clock):
  empty = no word in the RAM, full = DEPTH words in the RAM; s_tready = not full; m_tvalid = o_vld;
  wr_en = s_tvalid and not full; move = mem_q_vld and (not o_vld or m_tready);
  rd_en = not empty and (not mem_q_vld or move);
  level = words in the RAM + mem_q_vld + o_vld;
then at the clock edge: write, read into mem_q, move mem_q to the output, an output taken (o_vld and
m_tready) leaves. A word written into an empty FIFO is on m_tvalid 3 clocks later.

Event-driven use: the model holds the state of clock self.t and the inputs recorded for that clock;
sync(t) steps to clock t (later clocks with s_tvalid and m_tready low: idle stretches are skipped, nothing
moves in them); push(t, word) / take(t) are the handshakes of clock t (both may happen in one clock).
Words are (data, last, user)."""


class AxisFifo:
    """ip_axis_fifo of depth words; the state of clock self.t."""

    def __init__(self, depth=512):
        self.depth = depth
        self.ram = []                     # words in the RAM, oldest first
        self.mem_q = None                 # memory read register (None: not valid)
        self.o_q = None                   # output register (None: o_vld low)
        self.t = 0
        self.in_w = None                  # word written in clock self.t (s_tvalid and s_tready)
        self.in_take = False              # output taken in clock self.t (o_vld and m_tready)

    # -- the state of clock self.t (sync first)
    def full(self):
        return len(self.ram) == self.depth

    def tvalid(self):
        return self.o_q is not None

    def level(self):
        return len(self.ram) + (self.mem_q is not None) + (self.o_q is not None)

    def _step(self):
        """The edge at the end of clock self.t with its recorded inputs."""
        take = self.in_take and self.o_q is not None
        move = self.mem_q is not None and (self.o_q is None or take)
        rd = bool(self.ram) and (self.mem_q is None or move)
        out = self.mem_q if move else (None if take else self.o_q)
        mem_q = None if move else self.mem_q
        if rd:
            mem_q = self.ram.pop(0)
        if self.in_w is not None:
            self.ram.append(self.in_w)
        self.mem_q, self.o_q = mem_q, out
        self.in_w, self.in_take = None, False
        self.t += 1

    def _idle(self):
        """Nothing changes at the next edge (no inputs, the read pipeline full or empty)."""
        if self.in_w is not None or self.in_take:
            return False
        return not ((self.mem_q is not None and self.o_q is None) or (self.ram and self.mem_q is None))

    def sync(self, t):
        """To clock t."""
        while self.t < t and not self._idle():
            self._step()
        if self.t < t:
            self.t = t

    def push(self, t, word):
        """s_tvalid with word in clock t: True if written (s_tready: not full)."""
        self.sync(t)
        if self.full():
            return False
        self.in_w = word
        return True

    def take(self, t):
        """m_tready in clock t: the word handed over, or None (m_tvalid low)."""
        self.sync(t)
        if self.o_q is None:
            return None
        self.in_take = True
        return self.o_q

    def first_valid(self, t):
        """The first clock >= t in which m_tvalid is high without further inputs (no take), or None."""
        self.sync(t)
        save = (list(self.ram), self.mem_q, self.o_q, self.t, self.in_w, self.in_take)
        self.in_take = False
        while self.o_q is None and (self.ram or self.mem_q is not None or self.in_w is not None):
            self._step()
        res = self.t if self.o_q is not None else None
        self.ram, self.mem_q, self.o_q, self.t, self.in_w, self.in_take = save
        return res
