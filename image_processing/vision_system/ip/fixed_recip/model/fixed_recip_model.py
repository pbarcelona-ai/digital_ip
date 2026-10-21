"""fixed_recip model (Python model of image_processing/vision_system/ip/fixed_recip/src/fixed_recip.sv), bit and
clock exact: the restoring shift / subtract reciprocal of an unsigned Q16.16 operand,
  result = floor(2**W / D) (1 / D in Q16.16 for W = 32), all ones when it does not fit in W bits;
an operand of 0 is taken as 1 (so the result saturates). Timing: a start accepted in S_IDLE (at clock edge 0)
gives done one clock wide after edge W + 2 with the result valid from then on; busy is high from edge 0 to edge
W + 2; a start while the divider is busy is ignored."""


def recip(operand, w=32):
    """The divider's result for an unsigned W-bit operand, step by step as the RTL computes it."""
    m = (1 << (w + 1)) - 1
    div = operand if operand else 1
    rem, quot = 1, 0
    for _ in range(w + 1):                          # steps 0 .. W
        if rem >= div:
            rem, quot = ((rem - div) << 1) & m, ((quot << 1) | 1) & m
        else:
            rem, quot = (rem << 1) & m, (quot << 1) & m
    return (1 << w) - 1 if quot >> w else quot & ((1 << w) - 1)


def done_edge(w=32):
    """Clock edges from the start edge to the one after which done is high (and result valid)."""
    return w + 2
