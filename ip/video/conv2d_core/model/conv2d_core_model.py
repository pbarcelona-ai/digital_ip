"""conv2d_core model (Python model of ip/video/conv2d_core/src/conv2d_core.sv): an n x n kernel k (row-major,
signed COEF_W-bit) applied to each of the C components,
  out = clamp((sum(k x p) + 2**(shift - 1)) >>> shift, 0, 2**CW - 1)   (no rounding term for shift 0),
over isp_window's neighbourhoods (BORDER 0 clamp to edge, 1 mirror, reflect-101).
  conv2d()     a whole frame (numpy, H x W x C);
  Conv2dCore   beat exact (the outputs for a sequence of input beats, independent of the stream timing): the
               isp_window scan (isp_window_model.IspWindow), the kernel and shift taken with the first window
               of a frame (R lines after its start-of-frame pixel) and held for the frame's other windows.
The RTL's accumulator is ACC_W = PROD_W + clog2(N * N) + 1 bits (PROD_W = CW + 1 + COEF_W): every sum of N * N
products plus the rounding term fits for shifts below ACC_W; for shifts of ACC_W or more (27 for N 5, 8-bit
data, 12-bit coefficients) the rounding term leaves the accumulator and both the RTL and this model give 0."""
import numpy as np

from isp_window_model import IspWindow


def conv2d(rgb, k, shift, n, border=0, cw=8):
    """A frame: out = clamp((sum(k * p) + 2^(shift-1)) >>> shift, 0, 2^cw - 1), BORDER 0 clamp, 1 mirror."""
    r = n // 2
    a = rgb.astype(np.int64)
    p = np.pad(a, ((r, r), (r, r)) + ((0, 0),) * (a.ndim - 2), mode="reflect" if border else "edge")
    h, w = rgb.shape[:2]
    acc = np.zeros(rgb.shape, np.int64)
    for i in range(n):
        for j in range(n):
            c = k[i * n + j]
            if c:
                acc += c * p[i:i + h, j:j + w]
    if shift:
        acc = (acc + (1 << (shift - 1))) >> shift
    return np.clip(acc, 0, (1 << cw) - 1).astype(np.uint8 if cw <= 8 else np.uint16)


def mac(win, k, shift, c, cw):
    """One window (packed C x CW-bit pixels): the packed output pixel."""
    out = 0
    for j in range(c):
        acc = sum(kk * ((p >> (j * cw)) & ((1 << cw) - 1)) for kk, p in zip(k, win))
        if shift:
            acc = (acc + (1 << (shift - 1))) >> shift
        out |= min(max(acc, 0), (1 << cw) - 1) << (j * cw)
    return out


class Conv2dCore:
    """conv2d_core: push(data, tuser, width, height, k, shift) returns the output beats it releases, each a
    tuple (data, tlast, tuser); k is the kernel (signed ints) on coef_i at that time."""

    def __init__(self, n=5, c=3, cw=8, border=0):
        self.c, self.cw = c, cw
        self.win = IspWindow(n, border)
        self.k, self.shift = [0] * (n * n), 0             # coef_q / shift_q after reset

    def _out(self, wins, k, shift):
        res = []
        for o in wins:
            if o["user"]:
                self.k, self.shift = list(k), shift
            res.append((mac(o["win"], self.k, self.shift, self.c, self.cw), o["last"], o["user"]))
        return res

    def push(self, data, user, w, h, k, shift):
        return self._out(self.win.push(data, user, w, h), k, shift)

    def flush(self, w, h, k, shift):
        return self._out(self.win.flush(w, h), k, shift)
