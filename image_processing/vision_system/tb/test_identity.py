import os, sys
import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, with_timeout

sys.path.insert(0, os.path.dirname(__file__))
import image_io as io
from test_vision_system import (axil_write, axil_read, init_signals,
                                  stream_frame_in, capture_frame_out,
                                  REG_K1, REG_K2, REG_K3, REG_CENTER_X, REG_CENTER_Y,
                                  REG_SCALE, REG_IMG_WIDTH, REG_IMG_HEIGHT, REG_STATUS)


@cocotb.test()
async def test_identity(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await init_signals(dut)
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)

    w, h = 8, 6
    src = np.zeros((h, w, 3), dtype=np.uint8)
    for y in range(h):
        for x in range(w):
            src[y, x] = [x * 20, y * 30, (x + y) * 10]

    await axil_write(dut, REG_K1, 0)
    await axil_write(dut, REG_K2, 0)
    await axil_write(dut, REG_K3, 0)
    await axil_write(dut, REG_CENTER_X, io.to_q16(0.5))
    await axil_write(dut, REG_CENTER_Y, io.to_q16(0.5))
    await axil_write(dut, REG_SCALE, io.to_q16(1.0))
    await axil_write(dut, REG_IMG_WIDTH, w)
    await axil_write(dut, REG_IMG_HEIGHT, h)
    for _ in range(200):
        st = await axil_read(dut, REG_STATUS)
        if (st & 0x4) == 0:
            break
        await ClockCycles(dut.clk, 1)

    out_task = cocotb.start_soon(capture_frame_out(dut, w, h))
    await stream_frame_in(dut, src)
    out = await with_timeout(out_task, 200_000, "ns")

    print("SRC:\n", src[:, :, 0])
    print("OUT:\n", out[:, :, 0])
    diff = np.abs(out.astype(int) - src.astype(int))
    print("max diff:", diff.max(), "mean diff:", diff.mean())
