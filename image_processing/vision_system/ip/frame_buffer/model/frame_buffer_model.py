"""frame_buffer model (Python model of image_processing/vision_system/ip/frame_buffer/src/frame_buffer.sv), clock
exact: a frame store of DEPTH pixels written through one port and read through four (the four replicated banks
hold the same data). A read (rd_en) returns the four words one clock later, the values before a write in the
same clock (read before write); without rd_en the read data hold. Memory words never written read as 0 here
(X in the RTL: the comparison only reads written words)."""


class FrameBuffer:
    """frame_buffer: clock(wr_en, wr_addr, wr_data, rd_en, addrs) -> the rd_data registers after the edge."""

    def __init__(self, depth):
        self.depth = depth
        self.mem = {}
        self.rd = [0, 0, 0, 0]

    def clock(self, wr_en, wr_addr, wr_data, rd_en, addrs):
        if rd_en:
            self.rd = [self.mem.get(a, 0) for a in addrs]
        if wr_en:
            self.mem[wr_addr] = wr_data
        return list(self.rd)
