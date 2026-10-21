"""isp_window model (Python model of ip/video/isp_window/src/isp_window.sv), beat exact: the windows the block
outputs for a sequence of input beats, independent of the stream timing.

The block scans a (W + R) x (H + R) grid (R = (N - 1) / 2) in raster order. A scan position inside the frame
(x < W, y < H) takes one input beat; the others need none. A position with x >= R and y >= R outputs the
window centred on (x - R, y - R): row r, column c of the window is the frame pixel at (cx - R + c, cy - R + r)
with the BORDER rule for coordinates outside the frame (0 clamp to edge, 1 mirror without repeating the edge,
reflect-101), tuser on the window of (0, 0), tlast on the windows of column W - 1, m_x / m_y the centre.
Resync, at a position that takes a beat: at (0, 0) a beat without tuser is dropped; elsewhere a beat with
tuser restarts the scan at (0, 0) (the windows already output for the short frame stay valid) and is then
taken as the new frame's first pixel. Input tlast is not used. The frame size (width_i / height_i) is read at
every position: change it only while the scan waits at (0, 0) (sof_wait_o)."""


def border(i, n, mode):
    """Coordinate i (-R .. n - 1 + R) of a frame of n pixels after the BORDER rule (0 clamp, 1 mirror)."""
    if i < 0:
        return -i if mode else 0
    if i >= n:
        return 2 * (n - 1) - i if mode else n - 1
    return i


def window(px, w, h, cx, cy, n, mode):
    """The n x n window (row-major list) centred on (cx, cy) of the frame px[y][x] of size w x h."""
    r = n // 2
    return [px[border(cy - r + i, h, mode)][border(cx - r + j, w, mode)] for i in range(n) for j in range(n)]


def pack(win, pw):
    """A window as m_axis_tdata: element r * N + c at bits [(r * N + c) * PW +: PW]."""
    v = 0
    for i, p in enumerate(win):
        v |= (p & ((1 << pw) - 1)) << (i * pw)
    return v


class IspWindow:
    """isp_window scan: push(beat) returns the windows output up to the next position that waits for a beat.
    Each output is a dict: win (list), x, y (centre), last, user."""

    def __init__(self, n=3, mode=0):
        self.N, self.R, self.mode = n, n // 2, mode
        self.x = self.y = 0
        self.px = []                                       # the current frame's pixels, rows of the scan

    def _step(self, w, h, out):
        """One position: output its window (if any) and advance; positions that take no beat only."""
        x, y, r = self.x, self.y, self.R
        if x >= r and y >= r:
            cx, cy = x - r, y - r
            out.append(dict(win=window(self.px, w, h, cx, cy, self.N, self.mode), x=cx, y=cy,
                            last=int(x == w + r - 1), user=int(cx == 0 and cy == 0)))
        if x == w + r - 1:
            self.x, self.y = 0, (0 if y == h + r - 1 else y + 1)
        else:
            self.x += 1

    def _idle(self, w, h, out):
        while not (self.x < w and self.y < h):            # positions without input
            self._step(w, h, out)

    def push(self, data, user, w, h):
        """One input beat (pixel data, tuser) with the frame size in effect; the windows it releases."""
        if w <= self.R or h <= self.R:
            raise ValueError(f"isp_window: frame {w} x {h} below the minimum {self.R + 1} x {self.R + 1}")
        out = []
        self._idle(w, h, out)
        at_sof = self.x == 0 and self.y == 0
        if at_sof and not user:
            return out                                     # dropped: waiting for a frame start
        if not at_sof and user:
            self.x = self.y = 0                            # early start of frame: restart the scan
        if self.x == 0 and self.y == 0:
            self.px = [[0] * w for _ in range(h)]
        self.px[self.y][self.x] = data
        self._step(w, h, out)
        self._idle(w, h, out)
        return out

    def flush(self, w, h):
        """The windows of the positions after the last beat that need none (the end of the frame)."""
        out = []
        self._idle(w, h, out)
        return out
