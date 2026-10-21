"""isp_csc model (Python model of ip/video/isp_csc/src/isp_csc.sv), BT.601 limited range, 8 bit:
  Y  = 16 + ((66 R + 129 G + 25 B + 128) >> 8)
  Cb = 128 + ((-38 R - 74 G + 112 B + 128) >> 8)
  Cr = 128 + ((112 R - 94 G - 18 B + 128) >> 8)
BT.709 (bt709):
  Y  = 16 + ((47 R + 157 G + 16 B + 128) >> 8)
  Cb = 128 + ((-26 R - 86 G + 112 B + 128) >> 8)
  Cr = 128 + ((112 R - 102 G - 10 B + 128) >> 8)
(>> arithmetic; each result clamped to 0..255.) The output pixel is (Cr, Y, Cb) in component order 0, 1, 2 (as
the RTL packs it); csc_frame() is the block on a frame: bypass and the matrix taken with the frame's first pixel,
bypass passing RGB unchanged."""
import numpy as np


def csc_bt601(rgb):
    """RGB (h x w x 3, 0-255) -> (Cr, Y, Cb) per pixel, BT.601 limited range."""
    R, G, B = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    Y = 16 + ((66 * R + 129 * G + 25 * B + 128) >> 8)
    Cb = 128 + ((-38 * R - 74 * G + 112 * B + 128) >> 8)
    Cr = 128 + ((112 * R - 94 * G - 18 * B + 128) >> 8)
    return np.stack([Cr, Y, Cb], -1)


M601 = ((66, 129, 25), (-38, -74, 112), (112, -94, -18))
M709 = ((47, 157, 16), (-26, -86, 112), (112, -102, -10))


def csc_frame(rgb, bt709=False, bypass=False):
    """isp_csc on a frame (h x w x 3, R G B): (Cr, Y, Cb) per pixel, or the input with bypass."""
    rgb = np.asarray(rgb, np.int64)
    if bypass:
        return rgb
    m = np.array(M709 if bt709 else M601, np.int64)
    y, cb, cr = [(rgb @ m[i] + 128) >> 8 for i in range(3)]
    return np.clip(np.stack([128 + cr, 16 + y, 128 + cb], -1), 0, 255)
