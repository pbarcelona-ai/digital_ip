"""Debug test to check wr_ready after reset"""
import cocotb
from cocotb.triggers import RisingEdge, ReadOnly, ClockCycles
from cocotb.clock import Clock

@cocotb.test()
async def test_wr_ready_after_reset(dut):
    """Check wr_ready after reset"""
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
    
    # Check wr_ready at ReadOnly phase
    await ReadOnly()
    wr_ready = int(dut.fs.wr_ready.value)
    rd_ready = int(dut.fs.rd_ready.value)
    wr_state = str(dut.fs.wr_state.value) if hasattr(dut.fs, 'wr_state') else "N/A"
    
    print(f"wr_ready = {wr_ready}")
    print(f"rd_ready = {rd_ready}")
    print(f"wr_state = {wr_state}")
    
    # Wait a few more cycles and check again
    for i in range(5):
        await RisingEdge(dut.clk)
        await ReadOnly()
        wr_ready = int(dut.fs.wr_ready.value)
        print(f"Cycle {i+3}: wr_ready = {wr_ready}")
    
    assert wr_ready == 1, f"wr_ready should be 1 but is {wr_ready}"
