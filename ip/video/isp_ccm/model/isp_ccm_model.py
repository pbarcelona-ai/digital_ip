"""isp_ccm model (Python model of ip/video/isp_ccm/src/isp_ccm.sv): 3 x 3 colour correction with offsets,
out[i] = clamp(((sum_j coef[i][j] x in[j] + 512) >> 10) + off[i], 0, 2**PW - 1); coefficients signed Q5.10
(1024 = 1.0), offsets signed in output units; the arithmetic shift rounds half up. ccm_frame() is the block
on a frame: bypass taken with the frame's first pixel, coefficients and offsets read with every pixel."""
import numpy as np

PW = 10                        # component bits


def ccm(rgb, coef, off):
    """rgb: h x w x 3 ints; coef: 3 x 3 signed (row i: output component i); off: 3 signed."""
    m, o = np.array(coef), np.array(off)
    return np.clip(((rgb @ m.T + 512) >> 10) + o, 0, (1 << PW) - 1)


def ccm_frame(rgb, coef, off, bypass=False, pw=PW):
    """isp_ccm on a frame (h x w x 3, component 0 = R): the corrected frame, or the input with bypass."""
    rgb = np.asarray(rgb, np.int64)
    if bypass:
        return rgb
    m, o = np.array(coef, np.int64), np.array(off, np.int64)
    return np.clip(((rgb @ m.T + 512) >> 10) + o, 0, (1 << pw) - 1)
