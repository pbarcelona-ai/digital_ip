"""Cocotb reference tests for fixed-point and IEEE-754 binary32 MAC modes."""
from __future__ import annotations

from fractions import Fraction
import os
import random

import cocotb
from cocotb.triggers import Timer


def signed_value(raw: int, width: int) -> int:
    sign = 1 << (width - 1)
    return raw - (1 << width) if raw & sign else raw


def round_ratio_even(numerator: int, denominator: int) -> tuple[int, bool]:
    quotient, remainder = divmod(numerator, denominator)
    increment = 2 * remainder > denominator or (2 * remainder == denominator and (quotient & 1) != 0)
    return quotient + int(increment), remainder != 0


def fixed_reference(a: int, b: int, accumulator: int, config: dict[str, int | bool]) -> tuple[int, int, int]:
    a_width = int(config["A_WIDTH"])
    b_width = int(config["B_WIDTH"])
    acc_width = int(config["ACC_WIDTH"])
    out_width = int(config["OUT_WIDTH"])
    a_value = signed_value(a, a_width) if config["A_SIGNED"] else a
    b_value = signed_value(b, b_width) if config["B_SIGNED"] else b
    acc_value = signed_value(accumulator, acc_width) if config["ACC_SIGNED"] else accumulator

    product = a_value * b_value
    shift = int(config["A_FRAC_BITS"]) + int(config["B_FRAC_BITS"]) - int(config["ACC_FRAC_BITS"])
    inexact = False
    if shift > 0:
        magnitude, inexact = round_ratio_even(abs(product), 1 << shift)
        aligned_product = -magnitude if product < 0 else magnitude
    else:
        aligned_product = product << -shift
    total = acc_value + aligned_product

    if config["OUT_SIGNED"]:
        minimum = -(1 << (out_width - 1))
        maximum = (1 << (out_width - 1)) - 1
    else:
        minimum = 0
        maximum = (1 << out_width) - 1
    overflow = total < minimum or total > maximum
    if overflow and config["SATURATE"]:
        total = min(max(total, minimum), maximum)
    result = total & ((1 << out_width) - 1)
    return result, int(overflow), int(inexact or overflow)


def decode_binary32(bits: int) -> tuple[str, Fraction | None, int, bool]:
    sign = bits >> 31
    exponent = (bits >> 23) & 0xff
    fraction = bits & 0x7fffff
    if exponent == 0xff:
        if fraction:
            return "nan", None, sign, (fraction & (1 << 22)) == 0
        return "inf", None, sign, False
    if exponent == 0:
        significand = fraction
        power = -149
    else:
        significand = (1 << 23) | fraction
        power = exponent - 127 - 23
    value = Fraction(significand << power, 1) if power >= 0 else Fraction(significand, 1 << -power)
    return "finite", -value if sign else value, sign, False


def encode_binary32(value: Fraction) -> tuple[int, int, int, int]:
    if value == 0:
        return 0, 0, 0, 0
    sign = int(value < 0)
    magnitude = abs(value)
    numerator, denominator = magnitude.numerator, magnitude.denominator
    exponent = numerator.bit_length() - denominator.bit_length()
    if exponent >= 0:
        if numerator < (denominator << exponent):
            exponent -= 1
    elif (numerator << -exponent) < denominator:
        exponent -= 1

    if exponent < -126:
        significand, inexact = round_ratio_even(numerator << 149, denominator)
        if significand >= (1 << 23):
            return (sign << 31) | (1 << 23), 0, 0, int(inexact)
        return (sign << 31) | significand, 0, int(inexact), int(inexact)

    scale = 23 - exponent
    if scale >= 0:
        significand, inexact = round_ratio_even(numerator << scale, denominator)
    else:
        significand, inexact = round_ratio_even(numerator, denominator << -scale)
    if significand >= (1 << 24):
        significand >>= 1
        exponent += 1
    if exponent > 127:
        return (sign << 31) | 0x7f800000, 1, 0, 1
    result = (sign << 31) | ((exponent + 127) << 23) | (significand & 0x7fffff)
    return result, 0, 0, int(inexact)


def float_fma_reference(a_bits: int, b_bits: int, c_bits: int) -> tuple[int, int, int, int, int]:
    a_kind, a_value, a_sign, a_snan = decode_binary32(a_bits)
    b_kind, b_value, b_sign, b_snan = decode_binary32(b_bits)
    c_kind, c_value, c_sign, c_snan = decode_binary32(c_bits)
    canonical_nan = 0x7fc00000
    invalid = int(a_snan or b_snan or c_snan)
    if "nan" in (a_kind, b_kind, c_kind):
        return canonical_nan, 0, 0, 0, invalid

    a_zero = a_kind == "finite" and a_value == 0
    b_zero = b_kind == "finite" and b_value == 0
    product_inf = a_kind == "inf" or b_kind == "inf"
    product_sign = a_sign ^ b_sign
    if product_inf and (a_zero or b_zero):
        return canonical_nan, 0, 0, 0, 1
    if product_inf:
        if c_kind == "inf" and c_sign != product_sign:
            return canonical_nan, 0, 0, 0, 1
        return (product_sign << 31) | 0x7f800000, 0, 0, 0, 0
    if c_kind == "inf":
        return c_bits, 0, 0, 0, 0

    exact = a_value * b_value + c_value
    return encode_binary32(exact)[0], *encode_binary32(exact)[1:], 0


async def reset_dut(dut) -> None:
    dut.clk.value = 0
    dut.valid_i.value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await Timer(5, unit="ns")
        dut.clk.value = 1
        await Timer(5, unit="ns")
        dut.clk.value = 0
    dut.rst_n.value = 1
    await Timer(5, unit="ns")
    dut.clk.value = 1
    await Timer(1, unit="ns")
    dut.clk.value = 0


async def compare(dut, a: int, b: int, accumulator: int, expected: tuple[int, ...]) -> None:
    dut.clk.value = 0
    dut.a_i.value = a
    dut.b_i.value = b
    dut.acc_i.value = accumulator
    dut.valid_i.value = 1
    await Timer(5, unit="ns")
    dut.clk.value = 1
    await Timer(1, unit="ns")
    assert int(dut.valid_o.value) == 1
    observed = (int(dut.result_o.value), int(dut.overflow_o.value), int(dut.underflow_o.value),
                int(dut.inexact_o.value), int(dut.invalid_o.value))
    assert observed == expected, f"a={a:#x} b={b:#x} acc={accumulator:#x}: {observed} != {expected}"
    dut.clk.value = 0
    await Timer(5, unit="ns")
    dut.valid_i.value = 0


@cocotb.test()
async def python_reference_matches_mac(dut):
    case = os.environ["MAC_CASE"]
    configs = {
        "signed_fixed": dict(A_WIDTH=8, B_WIDTH=8, ACC_WIDTH=16, OUT_WIDTH=8,
                             A_SIGNED=True, B_SIGNED=True, ACC_SIGNED=True, OUT_SIGNED=True,
                             A_FRAC_BITS=4, B_FRAC_BITS=4, ACC_FRAC_BITS=4, SATURATE=True),
        "unsigned_fixed": dict(A_WIDTH=8, B_WIDTH=8, ACC_WIDTH=16, OUT_WIDTH=16,
                               A_SIGNED=False, B_SIGNED=False, ACC_SIGNED=False, OUT_SIGNED=False,
                               A_FRAC_BITS=0, B_FRAC_BITS=0, ACC_FRAC_BITS=0, SATURATE=True),
        "binary32": dict(A_WIDTH=32, B_WIDTH=32, ACC_WIDTH=32, OUT_WIDTH=32,
                         FLOATING_POINT=True),
    }
    config = configs[case]
    await reset_dut(dut)
    randomizer = random.Random(0x4D4143)

    if case != "binary32":
        a_width, b_width, acc_width = config["A_WIDTH"], config["B_WIDTH"], config["ACC_WIDTH"]
        for _ in range(100):
            a = randomizer.randrange(1 << a_width)
            b = randomizer.randrange(1 << b_width)
            accumulator = randomizer.randrange(1 << acc_width)
            result, overflow, inexact = fixed_reference(a, b, accumulator, config)
            await compare(dut, a, b, accumulator, (result, overflow, 0, inexact, 0))
    else:
        vectors = [
            (0x3f800000, 0x40000000, 0x40400000),
            (0x3f800001, 0x3f7ffffe, 0xbf800000),
            (0x00000001, 0x3f800000, 0x00000000),
            (0x00000001, 0x3f000000, 0x00000000),
            (0x00000000, 0x7f800000, 0x00000000),
            (0x7f7fffff, 0x40000000, 0x00000000),
        ]
        vectors.extend((randomizer.getrandbits(32), randomizer.getrandbits(32), randomizer.getrandbits(32))
                       for _ in range(100))
        for a, b, accumulator in vectors:
            await compare(dut, a, b, accumulator, float_fma_reference(a, b, accumulator))