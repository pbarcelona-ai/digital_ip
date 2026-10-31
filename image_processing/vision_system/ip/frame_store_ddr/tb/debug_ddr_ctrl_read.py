"""Debug test to monitor DDR controller internal state during reads"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.clock import Clock

@cocotb.test()
async def test_ddr_ctrl_debug_reads(dut):
    """Monitor DDR controller internal state during reads"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    
    # Reset
    dut.rst_n.value = 0
    dut.fs.wr_en.value = 0
    dut.fs.wr_addr.value = 0
    dut.fs.wr_data.value = 0
    dut.fs.wr_buf_sel.value = 0
    dut.fs.wr_frame_done.value = 0
    dut.fs.rd_en.value = 0
    dut.fs.rd_addr0.value = 0
    dut.fs.rd_addr1.value = 0
    dut.fs.rd_addr2.value = 0
    dut.fs.rd_addr3.value = 0
    dut.fs.rd_buf_sel.value = 0
    
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 2)
    
    # Write a few pixels first
    print("=== Writing pixels ===")
    for pixel_idx in range(8):
        while True:
            await RisingEdge(dut.clk)
            wr_ready = int(dut.fs.wr_ready.value)
            if wr_ready == 1:
                break
        
        dut.fs.wr_en.value = 1
        dut.fs.wr_addr.value = pixel_idx
        dut.fs.wr_data.value = (pixel_idx * 0x111) & 0xFFFF
        dut.fs.wr_buf_sel.value = 0
        dut.fs.wr_frame_done.value = 1 if pixel_idx == 7 else 0
        await RisingEdge(dut.clk)
        dut.fs.wr_en.value = 0
        dut.fs.wr_frame_done.value = 0
    
    # Wait for write to complete
    for i in range(30):
        await RisingEdge(dut.clk)
    
    # Now trigger swap_buf via AXI
    print("=== Swapping buffers ===")
    dut.axi_awvalid.value = 1
    dut.axi_awaddr.value = 0x00
    dut.axi_wvalid.value = 1
    dut.axi_wdata.value = 0x02  # swap_buf
    dut.axi_wstrb.value = 0xF
    dut.axi_bready.value = 1
    
    while True:
        await RisingEdge(dut.clk)
        if int(dut.axi_awready.value) and int(dut.axi_wready.value):
            break
    dut.axi_awvalid.value = 0
    dut.axi_wvalid.value = 0
    
    while True:
        await RisingEdge(dut.clk)
        if int(dut.axi_bvalid.value):
            break
    
    await ClockCycles(dut.clk, 2)
    
    # Now try to read - monitor DDR controller state
    print("=== Reading pixels ===")
    dut.fs.rd_en.value = 1
    dut.fs.rd_addr0.value = 0
    dut.fs.rd_addr1.value = 1
    dut.fs.rd_addr2.value = 2
    dut.fs.rd_addr3.value = 3
    dut.fs.rd_buf_sel.value = 1
    
    for cycle in range(200):
        await RisingEdge(dut.clk)
        
        busy = int(dut.ddr_ctrl_busy.value)
        owed = int(dut.ddr_ctrl_owed.value)
        g_ref = int(dut.ddr_ctrl_g_ref.value)
        grant_v = int(dut.ddr_ctrl_grant_v.value)
        awready_0 = int(dut.ddr_ctrl_awready_0.value)
        wready_0 = int(dut.ddr_ctrl_wready_0.value)
        arready_1 = int(dut.ddr_ctrl_arready_1.value)
        dfi_cmd = int(dut.ddr_ctrl_dfi_cmd.value)
        dfi_bank = int(dut.ddr_ctrl_dfi_bank.value)
        dfi_row = int(dut.ddr_ctrl_dfi_row.value)
        dfi_col = int(dut.ddr_ctrl_dfi_col.value)
        mem_err = int(dut.ddr_mem_err.value)
        mem_err_code = int(dut.ddr_mem_err_code.value)
        mem_err_cnt = int(dut.ddr_mem_err_cnt.value)
        wr_ready = int(dut.fs.wr_ready.value)
        rd_ready = int(dut.fs.rd_ready.value)
        rd_valid = int(dut.fs.rd_valid.value)
        
        # Also check AXI signals on port 1
        s_axi_arvalid_1 = int(dut.u_dut.s_axi_arvalid[1])
        s_axi_arready_1 = int(dut.u_dut.s_axi_arready[1])
        s_axi_arid_1 = int(dut.u_dut.s_axi_arid[3:2])  # port 1 ID
        s_axi_araddr_1 = int(dut.u_dut.s_axi_araddr[35:18])  # port 1 addr
        s_axi_rvalid_1 = int(dut.u_dut.s_axi_rvalid[1])
        s_axi_rready_1 = int(dut.u_dut.s_axi_rready[1])
        s_axi_rid_1 = int(dut.u_dut.s_axi_rid[3:2])  # port 1 RID
        
        print(f"Cycle {cycle}: rd_ready={rd_ready} rd_valid={rd_valid} "
              f"busy={busy} owed={owed} g_ref={g_ref} grant_v={grant_v} "
              f"arready_1={arready_1} dfi_cmd={dfi_cmd} dfi_bank={dfi_bank} dfi_row={dfi_row} dfi_col={dfi_col} "
              f"mem_err={mem_err} "
              f"s_axi_arvalid_1={s_axi_arvalid_1} s_axi_arready_1={s_axi_arready_1} "
              f"s_axi_rvalid_1={s_axi_rvalid_1} s_axi_rready_1={s_axi_rready_1} s_axi_rid_1={s_axi_rid_1}")
        
        if rd_valid == 1:
            print(f"READ COMPLETE at cycle {cycle}")
            rd_data0 = int(dut.fs.rd_data0.value)
            rd_data1 = int(dut.fs.rd_data1.value)
            rd_data2 = int(dut.fs.rd_data2.value)
            rd_data3 = int(dut.fs.rd_data3.value)
            print(f"  rd_data: {rd_data0}, {rd_data1}, {rd_data2}, {rd_data3}")
            break
    
    dut.fs.rd_en.value = 0
    
    assert True  # This test always passes - just for debugging
