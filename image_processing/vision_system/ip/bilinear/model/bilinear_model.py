"""bilinear model (Python model of image_processing/vision_system/ip/bilinear/src/bilinear.sv), bit and clock
exact: 2 x 2 RGB888 interpolation with 8-bit (Q0.8) fractions,
  w00 = (256 - fx)(256 - fy), w10 = fx (256 - fy), w01 = (256 - fx) fy, w11 = fx fy,
  out = (TL w00 + TR w10 + BL w01 + BR w11 + 32768) >> 16 per channel ([23:16], [15:8], [7:0]),
LATENCY 3 clocks from valid_in to valid_out, one pixel per clock."""

LATENCY = 3


def bilinear(fx, fy, tl, tr, bl, br):
    """The output pixel (24-bit) for fractions fx, fy (0..255) and the four 24-bit corner pixels."""
    w = ((256 - fx) * (256 - fy), fx * (256 - fy), (256 - fx) * fy, fx * fy)
    out = 0
    for sh in (16, 8, 0):
        acc = sum(((p >> sh) & 0xFF) * wi for p, wi in zip((tl, tr, bl, br), w))
        out |= (((acc + 32768) >> 16) & 0xFF) << sh
    return out
