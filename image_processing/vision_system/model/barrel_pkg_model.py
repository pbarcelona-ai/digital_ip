"""barrel_pkg model (Python model of image_processing/vision_system/include/barrel_pkg.sv), bit exact: the
signed Q16.16 helpers every vision_system block uses.
  s32 / s40   wrap to a signed 32 / 40-bit value (SystemVerilog adds and shifts in those widths);
  qsat        (64-bit product) >>> 16, saturated to signed 32 bits;
  qsat48      an already-shifted 48-bit value saturated to signed 32 bits;
  qmul(a, b)  qsat(a * b) = qsat48(mulq_s(a, b)), the saturating Q16.16 multiply;
  sums        sat40(exact sum) = qsat48(the Python sum): the saturating Q16.16 sum.
Constants: FRAC_BITS 16, Q16_ONE, MAX_W / MAX_H 720, ADDR_W, COORD_W, PIX_W 24."""
from mulq_s_model import mulq_s

FRAC_BITS = 16
Q16_ONE = 1 << 16
PIX_W = 24
MAX_W = MAX_H = 720
ADDR_W = (MAX_W * MAX_H - 1).bit_length()
COORD_W = (max(MAX_W, MAX_H) - 1).bit_length() + 1
S32_MAX, S32_MIN = (1 << 31) - 1, -(1 << 31)


def s32(v):
    """v as a signed 32-bit value (two's complement wrap)."""
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v >> 31 else v


def s40(v):
    """v as a signed 40-bit value."""
    v &= (1 << 40) - 1
    return v - (1 << 40) if v >> 39 else v


def qsat48(s):
    """A shifted product saturated to signed 32 bits."""
    return S32_MAX if s > S32_MAX else S32_MIN if s < S32_MIN else s


def qsat(prod):
    """A 64-bit Q32.32 product shifted back to Q16.16 and saturated."""
    return qsat48(prod >> FRAC_BITS)


def qmul(a, b):
    """Saturating Q16.16 multiply of signed 32-bit a, b."""
    return qsat48(mulq_s(a, b))
