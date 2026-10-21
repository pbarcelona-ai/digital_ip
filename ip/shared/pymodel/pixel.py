"""Pixel arithmetic shared by the video IP models (ip/shared/pymodel): luma and chroma as the RTL computes
them, run filling, border padding, the Bayer colour of each pixel and sign extension."""
import numpy as np


def luma(rgb):
    """(R + 2 G + B) >> 2 per pixel."""
    r, g, b = (rgb[..., k].astype(np.int32) for k in range(3))
    return (r + 2 * g + b) >> 2


def chroma(rgb):
    """(Y, Cb, Cr, saturation): Cb = 128 + (B - Y) >> 1, Cr = 128 + (R - Y) >> 1, |Cb - 128| + |Cr - 128|."""
    y = luma(rgb)
    r, b = rgb[..., 0].astype(np.int32), rgb[..., 2].astype(np.int32)
    cb = 128 + ((b - y) >> 1)
    cr = 128 + ((r - y) >> 1)
    return y, cb, cr, np.abs(cb - 128) + np.abs(cr - 128)


def fill(bits, span):
    """A set bit in the last span pixels of the line (run-fill counter; span 0 or 1: the bit itself)."""
    out = bits.copy()
    for k in range(1, max(1, span)):
        out[:, k:] |= bits[:, :bits.shape[1] - k]
    return out


def reflect101(a, r):
    """a padded by r on each side, mirrored without repeating the border pixel."""
    return np.pad(a, ((r, r), (r, r)) + ((0, 0),) * (a.ndim - 2), mode="reflect")


def clamp_pad(a, r):
    """a padded by r on each side with copies of the border pixel."""
    return np.pad(a, ((r, r), (r, r)) + ((0, 0),) * (a.ndim - 2), mode="edge")


def bayer_colour(h, w, cfa=0):
    """CFA colour of every pixel of an h x w RAW frame: 0 R, 1 Gr, 2 Gb, 3 B for RGGB (cfa 0); other
    patterns swap the phase."""
    yy, xx = np.mgrid[0:h, 0:w]
    phase = ((yy & 1) << 1 | (xx & 1)) ^ {0: 0, 1: 1, 2: 2, 3: 3}.get(cfa, 0)
    return np.choose(phase, [0, 1, 2, 3])


def signed(v, bits):
    """The low bits of v as a two's complement number."""
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v
