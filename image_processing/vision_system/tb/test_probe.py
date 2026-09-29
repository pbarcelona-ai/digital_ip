import os, sys
import numpy as np
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, with_timeout

sys.path.insert(0, os.path.dirname(__file__))
import image_io as io
from test_vision_system import (axil_write, axil_read, init_signals,
                                  REG_K1, REG_K2, REG_K3, REG_CENTER_X, REG_CENTER_Y,
                                  REG_SCALE, REG_IMG_WIDTH, REG_IMG_HEIGHT, REG_STATUS,
                                  pack_pixel)


@cocotb.test()
async def test_probe(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await init_signals(dut)
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)

    w, h = 8, 8
    src = np.zeros((h, w, 3), dtype=np.uint8)
    for y in range(h):
        for x in range(w):
            src[y, x] = [x * 20, y * 20, 0]

    k1f = -0.08
    k1q = io.to_q16(k1f)
    await axil_write(dut, REG_K1, k1q)
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

    print("cx_pix_q16 =", int(dut.cx_pix_q16.value.signed_integer))
    print("cy_pix_q16 =", int(dut.cy_pix_q16.value.signed_integer))
    print("recip_halfw_q16 =", int(dut.recip_halfw_q16.value))
    print("halfw_scaled_q16 =", int(dut.halfw_scaled_q16.value.signed_integer))
    print("k1_q16 =", int(dut.k1_q16.value.signed_integer))

    # golden for cross-check
    cfg = io.RemapConfig(w, h, io.to_q16(0.5), io.to_q16(0.5), io.to_q16(1.0))
    print("golden cx_pix", cfg.cx_pix, "recip_halfw", cfg.recip_halfw, "halfw_scaled", cfg.halfw_scaled)

    # Drive one pixel request at a time via s_axis with big gaps, and
    # snoop u_coord_gen's output each cycle it is valid.
    probe_log = []

    async def monitor():
        while True:
            await RisingEdge(dut.clk)
            if dut.u_out.u_coord_gen.out_valid.value == 1:
                sx = int(dut.u_out.u_coord_gen.out_sx_q16.value.signed_integer)
                sy = int(dut.u_out.u_coord_gen.out_sy_q16.value.signed_integer)
                probe_log.append((sx, sy))

    mon_task = cocotb.start_soon(monitor())

    for y in range(h):
        for x in range(w):
            dut.s_axis_tvalid.value = 1
            dut.s_axis_tdata.value = pack_pixel(src[y, x])
            dut.s_axis_tlast.value = 1 if x == w - 1 else 0
            dut.s_axis_tuser.value = 1 if (x == 0 and y == 0) else 0
            await RisingEdge(dut.clk)
        dut.s_axis_tvalid.value = 0
        dut.s_axis_tlast.value = 0
        dut.s_axis_tuser.value = 0
        await ClockCycles(dut.clk, 5)

    await ClockCycles(dut.clk, 400)
    mon_task.kill()

    print(f"captured {len(probe_log)} coord_gen outputs (expect {w*h})")
    for i in range(min(20, len(probe_log))):
        y, x = i // w, i % w
        rtl_sx, rtl_sy = probe_log[i]
        dxq = (x << 16) - cfg.cx_pix
        dyq = (y << 16) - cfg.cy_pix
        nx = io.qmul(dxq, cfg.recip_halfw)
        ny = io.qmul(dyq, cfg.recip_halfh)
        r2 = io.qmul(nx, nx) + io.qmul(ny, ny)
        factor = io.ONE_Q16 + io.qmul(k1q, r2)
        gsx = cfg.cx_pix + io.qmul(io.qmul(nx, factor), cfg.halfw_scaled)
        gsy = cfg.cy_pix + io.qmul(io.qmul(ny, factor), cfg.halfh_scaled)
        match = "OK" if (gsx == rtl_sx and gsy == rtl_sy) else "MISMATCH"
        print(f"(x={x},y={y}) RTL sx,sy=({rtl_sx},{rtl_sy})  golden=({gsx},{gsy})  {match}")
