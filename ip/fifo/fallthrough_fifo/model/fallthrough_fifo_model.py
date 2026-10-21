"""fallthrough_fifo model (Python model of ip/fifo/fallthrough_fifo/src/fallthrough_fifo.sv), clock exact: a
first-word-fall-through FIFO of DEPTH words (a power of two >= 2) of WIDTH bits.
  Outputs from the state (no input reaches an output in the same clock): m_valid_o = not empty, m_data_o = the
  oldest word (the contents of the read slot when empty), s_ready_o = not full, level_o = the number of words.
  Clock edge: a push (s_valid_i and s_ready_o) writes s_data_i; a pop (m_valid_o and m_ready_i) drops the oldest
  word; both may happen in one clock (not when full: s_ready_o is low then, even with a pop). Reset: empty
  (the storage keeps its contents)."""


class FallthroughFifo:
    """fallthrough_fifo with its parameters."""

    def __init__(self, width=32, depth=16):
        if depth < 2 or depth & (depth - 1):
            raise ValueError("DEPTH must be a power of two >= 2")
        self.width, self.depth = width, depth
        self.mem = [None] * depth                    # None: never written (X in the RTL)
        self.wptr = self.rptr = 0                    # AW + 1 bits, as the RTL

    def reset(self):
        self.wptr = self.rptr = 0

    def outputs(self):
        level = (self.wptr - self.rptr) % (2 * self.depth)
        return dict(s_ready_o=int(level != self.depth), m_valid_o=int(level != 0), level_o=level,
                    m_data_o=self.mem[self.rptr % self.depth])

    def cycle(self, s_data_i=0, s_valid_i=0, m_ready_i=0, rst_n=1):
        """The outputs during this clock, then the clock edge."""
        o = self.outputs()
        if not rst_n:
            self.reset()
            return o
        if s_valid_i and o["s_ready_o"]:
            self.mem[self.wptr % self.depth] = s_data_i & ((1 << self.width) - 1)
            self.wptr = (self.wptr + 1) % (2 * self.depth)
        if o["m_valid_o"] and m_ready_i:
            self.rptr = (self.rptr + 1) % (2 * self.depth)
        return o
