"""Debug test to monitor DDR controller internal state during writes"""
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from cocotb.clock import Clock

@cocotb.test()
async def test_ddr_ctrl_debug_writes(dut):
    """Monitor DDR controller internal state during writes"""
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
    
    # Check initial state
    wr_ready = int(dut.fs.wr_ready.value)
    busy = int(dut.ddr_ctrl_busy.value)
    owed = int(dut.ddr_ctrl_owed.value)
    g_ref = int(dut.ddr_ctrl_g_ref.value)
    grant_v = int(dut.ddr_ctrl_grant_v.value)
    awready_0 = int(dut.ddr_ctrl_awready_0.value)
    wready_0 = int(dut.ddr_ctrl_wready_0.value)
    
    print(f"Initial: wr_ready={wr_ready} busy={busy} owed={owed} g_ref={g_ref} grant_v={grant_v} awready0={awready_0} wready0={wready_0}")
    
    # Write a few pixels and monitor
    for pixel_idx in range(10):
        print(f"Waiting for wr_ready for pixel {pixel_idx}...")
        cycles = 0
        while True:
            await RisingEdge(dut.clk)
            wr_ready = int(dut.fs.wr_ready.value)
            cycles += 1
            if cycles > 100:
                print(f"  TIMEOUT! wr_ready never became 1 after {cycles} cycles")
                # Print DDR state
                busy = int(dut.ddr_ctrl_busy.value)
                owed = int(dut.ddr_ctrl_owed.value)
                g_ref = int(dut.ddr_ctrl_g_ref.value)
                grant_v = int(dut.ddr_ctrl_grant_v.value)
                awready_0 = int(dut.ddr_ctrl_awready_0.value)
                wready_0 = int(dut.ddr_ctrl_wready_0.value)
                dfi_cmd = int(dut.ddr_ctrl_dfi_cmd.value)
                print(f"  DDR state: busy={busy} owed={owed} g_ref={g_ref} grant_v={grant_v} awready0={awready_0} wready0={wready_0} dfi_cmd={dfi_cmd}")
                break
            if wr_ready == 1:
                print(f"  Got wr_ready after {cycles} cycles")
                break
        
        if cycles > 100:
            break
        
        # Drive write
        dut.fs.wr_en.value = 1
        dut.fs.wr_addr.value = pixel_idx
        dut.fs.wr_data.value = (pixel_idx * 0x111) & 0xFFFF
        dut.fs.wr_buf_sel.value = 0
        dut.fs.wr_frame_done.value = 1 if pixel_idx == 9 else 0
        
        await RisingEdge(dut.clk)
        
        # Read DDR controller state after the write
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
        
        print(f"Pixel {pixel_idx}: busy={busy} owed={owed} g_ref={g_ref} grant_v={grant_v} "
              f"awready0={awready_0} wready0={wready_0} "
              f"dfi_cmd={dfi_cmd} dfi_bank={dfi_bank} dfi_row={dfi_row} dfi_col={dfi_col} "
              f"mem_err={mem_err} mem_err_code={mem_err_code} mem_err_cnt={mem_err_cnt} "
              f"wr_ready={wr_ready}")
        
        # Clear write enable
        dut.fs.wr_en.value = 0
        dut.fs.wr_frame_done.value = 0
    
    # Wait a bit more to see what happens
    for i in range(30):
        await RisingEdge(dut.clk)
        
        busy = int(dut.ddr_ctrl_busy.value)
        owed = int(dut.ddr_ctrl_owed.value)
        g_ref = int(dut.ddr_ctrl_g_ref.value)
        grant_v = int(dut.ddr_ctrl_grant_v.value)
        awready_0 = int(dut.ddr_ctrl_awready_0.value)
        wready_0 = int(dut.ddr_ctrl_wready_0.value)
        dfi_cmd = int(dut.ddr_ctrl_dfi_cmd.value)
        dfi_bank = int(dut.ddr_ctrl_dfi_bank.value)
        dfi_row = int(dut.ddr_ctrl_dfi_row.value)
        dfi_col = int(dut.ddr_ctrl_dfi_col.value)
        mem_err = int(dut.ddr_mem_err.value)
        mem_err_code = int(dut.ddr_mem_err_code.value)
        mem_err_cnt = int(dut.ddr_mem_err_cnt.value)
        
        wr_ready = int(dut.fs.wr_ready.value)
        
        print(f"Post-write {i}: busy={busy} owed={owed} g_ref={g_ref} grant_v={grant_v} "
              f"awready0={awready_0} wready0={wready_0} "
              f"dfi_cmd={dfi_cmd} dfi_bank={dfi_bank} dfi_row={dfi_row} dfi_col={dfi_col} "
              f"mem_err={mem_err} mem_err_code={mem_err_code} mem_err_cnt={mem_err_cnt} "
              f"wr_ready={wr_ready}")
    
    assert True  # This test always passes - just for debugging

