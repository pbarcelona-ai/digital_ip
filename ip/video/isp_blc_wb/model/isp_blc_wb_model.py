"""isp_blc_wb model (Python model of ip/video/isp_blc_wb/src/isp_blc_wb.sv) on a whole RAW frame (h x w
int64), colour c of each pixel from the CFA phase (pixel.bayer_colour: 0 R, 1 Gr, 2 Gb, 3 B):
  black level:   v = max(raw - blc[c], 0)
  white balance: out = min((v x gain[c] + 128) >> 8, 2**PW - 1)   (gains unsigned Q4.8 for R, Gr, Gb, B)
Each stage is skipped when its bypass is set (the caller does not call it). blc_wb() is the whole block on a
frame, as the RTL streams it: the CFA pattern and both bypass bits taken at the frame's first pixel; the offsets
and gains are read with every pixel (change them between frames)."""
import numpy as np

from pixel import bayer_colour

PW = 10                        # RAW bits


def blc(raw, col, levels):
    """Black level: levels = [R, Gr, Gb, B] offsets."""
    return np.maximum(raw - np.array(levels)[col], 0)


def wb(raw, col, gains):
    """White balance: gains = [R, Gr, Gb, B] in Q4.8 (the RTL's G gain serves both greens)."""
    return np.minimum((raw * np.array(gains)[col] + 128) >> 8, (1 << PW) - 1)


def blc_wb(raw, cfa=0, blc_bypass=False, wb_bypass=False, levels=(0, 0, 0, 0), gains=(256, 256, 256), pw=PW):
    """isp_blc_wb on a RAW frame: levels [R, Gr, Gb, B], gains [R, G, B] (Q4.8, G for both greens)."""
    raw = np.asarray(raw, np.int64)
    col = bayer_colour(raw.shape[0], raw.shape[1], cfa)
    v = raw if blc_bypass else np.maximum(raw - np.array(levels)[col], 0)
    if wb_bypass:
        return v
    g = np.array([gains[0], gains[1], gains[1], gains[2]])[col]
    return np.minimum((v * g + 128) >> 8, (1 << pw) - 1)

