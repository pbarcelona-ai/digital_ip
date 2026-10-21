"""isp_dpc model (Python model of ip/video/isp_dpc/src/isp_dpc.sv) on a whole RAW frame (h x w int64):
each pixel against its 8 same-colour neighbours (two pixels away horizontally, vertically, diagonally;
borders mirrored without repeating the edge pixel): above max + thr -> max (hot), below min - thr -> min
(dead), else unchanged. dpc_frame() is the block on a frame: bypass (taken when the frame's first output pixel
leaves) passes it unchanged; the number of corrected pixels is corrected_o's pulse count; the threshold is read
with every pixel (change it between frames). Frames of at least 3 x 3 (isp_window N = 5)."""
import numpy as np

from pixel import reflect101


def dpc(raw, thr):
    """RAW frame (h x w) with hot / dead pixels replaced by the neighbours' max / min (threshold thr)."""
    h, w = raw.shape
    p = reflect101(raw, 2)
    nb = np.stack([p[2 + dy:2 + dy + h, 2 + dx:2 + dx + w] for dy in (-2, 0, 2) for dx in (-2, 0, 2)
                   if (dy, dx) != (0, 0)])
    mx, mn = nb.max(0), nb.min(0)
    return np.where(raw > mx + thr, mx, np.where(raw < mn - thr, mn, raw))


def dpc_frame(raw, thr, bypass=False):
    """isp_dpc on a frame: (output frame, corrected pixels)."""
    raw = np.asarray(raw, np.int64)
    if bypass:
        return raw, 0
    out = dpc(raw, thr)
    return out, int((out != raw).sum())
