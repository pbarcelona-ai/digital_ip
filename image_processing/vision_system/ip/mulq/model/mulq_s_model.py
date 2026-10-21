"""mulq_s model (Python model of image_processing/vision_system/ip/mulq/src/mulq_s.sv), bit and clock exact:
s = (a * b) >>> 16 of two signed 32-bit operands as an exact signed 48-bit value (floor division by 2**16),
2 clocks after a and b are presented (throughput one per clock, no reset)."""

LATENCY = 2                    # clocks from a / b to s


def mulq_s(a, b):
    """(a * b) >>> 16 for signed 32-bit a, b: the exact 48-bit signed result."""
    return (a * b) >> 16
