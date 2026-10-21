"""isp_gamma model (Python model of ip/video/isp_gamma/src/isp_gamma.sv): one programmable curve of
2**IN_W entries x OUT_W bits applied to all three components; power-up contents the linear curve
in >> (IN_W - OUT_W). gamma_frame() is the block on a frame: bypass (taken with the frame's first pixel)
outputs in >> (IN_W - OUT_W); the table is read with every pixel (write it between frames)."""
import numpy as np

IN_W, OUT_W = 10, 8


def linear_curve():
    """The power-up table."""
    return [min((1 << OUT_W) - 1, i >> (IN_W - OUT_W)) for i in range(1 << IN_W)]


def gamma(rgb, table):
    """The table applied to every component of rgb (values clamped into the table's range)."""
    lut = np.array(table)
    return lut[np.clip(rgb, 0, (1 << IN_W) - 1)]


def gamma_frame(rgb, table, bypass=False, in_w=IN_W, out_w=OUT_W):
    """isp_gamma on a frame (h x w x 3 of in_w-bit components)."""
    rgb = np.asarray(rgb, np.int64)
    if bypass:
        return rgb >> (in_w - out_w)
    return np.array(table, np.int64)[rgb]
