"""isp_demosaic model (Python model of ip/video/isp_demosaic/src/isp_demosaic.sv): bilinear 3 x 3 Bayer
to RGB on a whole RAW frame (h x w int64; colour c of each pixel from pixel.bayer_colour), borders mirrored
without repeating the edge pixel. With n, s, e, w the cross neighbours and d the diagonals:
  R:  R = c, G = (n + s + e + w + 2) / 4, B = (sum d + 2) / 4
  B:  B = c, G = (n + s + e + w + 2) / 4, R = (sum d + 2) / 4
  Gr: G = c, R = (e + w + 1) / 2, B = (n + s + 1) / 2
  Gb: G = c, B = (e + w + 1) / 2, R = (n + s + 1) / 2
Returns h x w x 3 (R, G, B). demosaic_frame() is the block on a frame: the CFA pattern and bypass taken when the
frame's first output pixel leaves; bypass gives the RAW value in all three components. Frames of at least 2 x 2
(isp_window N = 3)."""
import numpy as np

from pixel import reflect101


def demosaic(raw, col):
    """RAW frame (h x w) with its CFA colours col -> h x w x 3 (R, G, B)."""
    h, w = raw.shape
    p = reflect101(raw, 1)
    n_, s_ = p[0:h, 1:w + 1], p[2:h + 2, 1:w + 1]
    e_, w_ = p[1:h + 1, 2:w + 2], p[1:h + 1, 0:w]
    d = p[0:h, 0:w] + p[0:h, 2:w + 2] + p[2:h + 2, 0:w] + p[2:h + 2, 2:w + 2]
    cross = (n_ + s_ + e_ + w_ + 2) >> 2
    diag = (d + 2) >> 2
    hor = (e_ + w_ + 1) >> 1
    ver = (n_ + s_ + 1) >> 1
    R = np.select([col == 0, col == 3, col == 1, col == 2], [raw, diag, hor, ver])
    G = np.select([col == 0, col == 3], [cross, cross], raw)
    B = np.select([col == 0, col == 3, col == 1, col == 2], [diag, raw, ver, hor])
    return np.stack([R, G, B], -1)


def demosaic_frame(raw, cfa=0, bypass=False):
    """isp_demosaic on a frame (h x w RAW): h x w x 3 (R, G, B)."""
    from pixel import bayer_colour
    raw = np.asarray(raw, np.int64)
    if bypass:
        return np.stack([raw, raw, raw], -1)
    return demosaic(raw, bayer_colour(raw.shape[0], raw.shape[1], cfa))
