"""frame_store_ddr cocotb testbench: tests the DDR-backed double-buffered frame store with row cache.
Tests write/read, buffer swap, cache behavior, and frame-level operations.
Golden model: model/frame_store_ddr_model.py (clock exact).
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "model"))
from frame_store_ddr_model import FrameStoreDdrModel
import cocotb
from cocotb.triggers import RisingEdge, FallingEdge, Timer, ClockCycles, with_timeout
from cocotb.clock import Clock


class FrameStoreDdrTB:
    """Testbench driver for frame_store_ddr_cocotb_top."""

    # AXI-Lite timeout in clock cycles
    AXIL_TIMEOUT_CYCLES = 1000

    def __init__(self, dut):
        self.dut = dut
        # Match DUT's SMALL parameters from run.py and testbench top defaults
        self.model = FrameStoreDdrModel(
            pix_w=16,
            addr_w=20,
            frame_width=8,
            frame_height=8,
            cache_lines=4,
            cache_line_w=6,
            ddr_data_w=64,
            ddr_addr_w=18,
            ddr_id_w=2,
            ddr_bank_w=2,
            ddr_row_w=8,
            ddr_col_w=4,
            ddr_t_rcd=2,
            ddr_t_rp=2,
            ddr_t_ras=4,
            ddr_t_cl=2,
            ddr_t_wr=2,
            ddr_t_rtp=1,
            ddr_t_wtr=1,
            ddr_t_rrd=1,
            ddr_t_rfc=8,
            ddr_t_refi=64,
            ddr_priority=0,
            ddr_rq_depth=4,
            ddr_bq_depth=2,
            ddr_mem_words=4096,
            ddr_ref_max=576,
        )

    async def reset(self):
        self.dut.rst_n.value = 0
        # Initialize all frame store inputs to 0
        self.dut.fs.wr_en.value = 0
        self.dut.fs.wr_addr.value = 0
        self.dut.fs.wr_data.value = 0
        self.dut.fs.wr_buf_sel.value = 0
        self.dut.fs.wr_frame_done.value = 0
        self.dut.fs.rd_en.value = 0
        self.dut.fs.rd_addr0.value = 0
        self.dut.fs.rd_addr1.value = 0
        self.dut.fs.rd_addr2.value = 0
        self.dut.fs.rd_addr3.value = 0
        self.dut.fs.rd_buf_sel.value = 0
        # Initialize AXI-Lite signals properly
        self.dut.axi_awaddr.value = 0
        self.dut.axi_awvalid.value = 0
        self.dut.axi_wdata.value = 0
        self.dut.axi_wstrb.value = 0xF
        self.dut.axi_wvalid.value = 0
        self.dut.axi_bready.value = 1
        self.dut.axi_araddr.value = 0
        self.dut.axi_arvalid.value = 0
        self.dut.axi_rready.value = 1
        await ClockCycles(self.dut.clk, 5)
        self.dut.rst_n.value = 1
        await ClockCycles(self.dut.clk, 2)
        self.model.reset()
        

    async def axil_write(self, addr, data, timeout_cycles=None):
        """Write to AXI4-Lite register with timeout."""
        if timeout_cycles is None:
            timeout_cycles = self.AXIL_TIMEOUT_CYCLES
        
        self.dut.axi_awvalid.value = 1
        self.dut.axi_awaddr.value = addr
        self.dut.axi_wvalid.value = 1
        self.dut.axi_wdata.value = data
        self.dut.axi_wstrb.value = 0xF  # All byte lanes valid
        self.dut.axi_bready.value = 1
        
        await RisingEdge(self.dut.clk)
        
        # Wait for awready with timeout
        cycles = 0
        while not self.dut.axi_awready.value:
            await RisingEdge(self.dut.clk)
            cycles += 1
            if cycles >= timeout_cycles:
                raise TimeoutError(f"AXI-Lite write: awready timeout at addr 0x{addr:02X}")
        
        # Wait for wready with timeout
        cycles = 0
        while not self.dut.axi_wready.value:
            await RisingEdge(self.dut.clk)
            cycles += 1
            if cycles >= timeout_cycles:
                raise TimeoutError(f"AXI-Lite write: wready timeout at addr 0x{addr:02X}")
        
        self.dut.axi_awvalid.value = 0
        self.dut.axi_wvalid.value = 0
        
        # Wait for bvalid with timeout
        cycles = 0
        while not self.dut.axi_bvalid.value:
            await RisingEdge(self.dut.clk)
            cycles += 1
            if cycles >= timeout_cycles:
                raise TimeoutError(f"AXI-Lite write: bvalid timeout at addr 0x{addr:02X}")
        
        # Check bresp
        if int(self.dut.axi_bresp.value) != 0:
            raise RuntimeError(f"AXI-Lite write: bresp error at addr 0x{addr:02X}: {self.dut.axi_bresp.value}")

    async def axil_read(self, addr, timeout_cycles=None):
        """Read from AXI4-Lite register with timeout."""
        if timeout_cycles is None:
            timeout_cycles = self.AXIL_TIMEOUT_CYCLES
        
        self.dut.axi_arvalid.value = 1
        self.dut.axi_araddr.value = addr
        self.dut.axi_rready.value = 1
        
        await RisingEdge(self.dut.clk)
        
        # Wait for arready with timeout
        cycles = 0
        while not self.dut.axi_arready.value:
            await RisingEdge(self.dut.clk)
            cycles += 1
            if cycles >= timeout_cycles:
                raise TimeoutError(f"AXI-Lite read: arready timeout at addr 0x{addr:02X}")
        
        self.dut.axi_arvalid.value = 0
        
        # Wait for rvalid with timeout
        cycles = 0
        while not self.dut.axi_rvalid.value:
            await RisingEdge(self.dut.clk)
            cycles += 1
            if cycles >= timeout_cycles:
                raise TimeoutError(f"AXI-Lite read: rvalid timeout at addr 0x{addr:02X}")
        
        data = self.dut.axi_rdata.value
        
        # Check rresp
        if int(self.dut.axi_rresp.value) != 0:
            raise RuntimeError(f"AXI-Lite read: rresp error at addr 0x{addr:02X}: {self.dut.axi_rresp.value}")
        
        return int(data)

    def write_frame_store(self, inputs):
        """Drive frame store writer inputs for one cycle."""
        self.dut.fs.wr_en.value = inputs.get('wr_en', 0)
        self.dut.fs.wr_addr.value = inputs.get('wr_addr', 0)
        self.dut.fs.wr_data.value = inputs.get('wr_data', 0)
        self.dut.fs.wr_buf_sel.value = inputs.get('wr_buf_sel', 0)
        self.dut.fs.wr_frame_done.value = inputs.get('wr_frame_done', 0)

    def read_frame_store(self, inputs):
        """Drive frame store reader inputs for one cycle."""
        self.dut.fs.rd_en.value = inputs.get('rd_en', 0)
        self.dut.fs.rd_addr0.value = inputs.get('rd_addr0', 0)
        self.dut.fs.rd_addr1.value = inputs.get('rd_addr1', 0)
        self.dut.fs.rd_addr2.value = inputs.get('rd_addr2', 0)
        self.dut.fs.rd_addr3.value = inputs.get('rd_addr3', 0)
        self.dut.fs.rd_buf_sel.value = inputs.get('rd_buf_sel', 0)

    def get_outputs(self):
        """Get frame store outputs."""
        return {
            'wr_ready': int(self.dut.fs.wr_ready.value),
            'rd_ready': int(self.dut.fs.rd_ready.value),
            'rd_valid': int(self.dut.fs.rd_valid.value),
            'rd_data0': int(self.dut.fs.rd_data0.value),
            'rd_data1': int(self.dut.fs.rd_data1.value),
            'rd_data2': int(self.dut.fs.rd_data2.value),
            'rd_data3': int(self.dut.fs.rd_data3.value),
            'buf_swapped': int(self.dut.fs.buf_swapped.value),
            'cache_flushed': int(self.dut.fs.cache_flushed.value),
            'store_idle': int(self.dut.fs.store_idle.value),
            'wr_fill': int(self.dut.fs.wr_fill.value),
            'rd_fill': int(self.dut.fs.rd_fill.value),
        }

    async def cycle(self, wr_inputs, rd_inputs, swap_buf=False, cache_flush=False):
        """Run one clock cycle with given inputs.

        Drive inputs, wait for rising edge to sample them,
        then read registered outputs in ReadWrite phase.
        """
        # Drive inputs (they will be sampled on next rising edge)
        self.write_frame_store(wr_inputs)
        self.read_frame_store(rd_inputs)
        
        # Wait for rising edge (inputs sampled, DUT updates outputs)
        await RisingEdge(self.dut.clk)
        
        # DEBUG: Check rd_ready immediately after RisingEdge
        rd_ready_after = int(self.dut.fs.rd_ready.value)
        wr_ready_after = int(self.dut.fs.wr_ready.value)
        print(f"cycle: after RisingEdge, wr_ready={wr_ready_after}, rd_ready={rd_ready_after}, wr_en={wr_inputs.get('wr_en',0)}, rd_en={rd_inputs.get('rd_en',0)}")
        
        # Read outputs in ReadWrite phase (registered outputs are stable)
        outputs = self.get_outputs()
        
        # Model inputs - include control signals
        model_inputs = {**wr_inputs, **rd_inputs, 'swap_buf': swap_buf, 'cache_flush': cache_flush}
        model_out = self.model.cycle(model_inputs)
        
        return outputs, model_out

    async def wait_wr_ready(self, timeout_cycles=10000):
        """Wait for wr_ready to be asserted.
        
        Checks wr_ready in current phase. If not ready, waits for next RisingEdge.
        Returns after a rising edge where wr_ready was asserted.
        """
        cycles = 0
        while True:
            # Check wr_ready directly - works for registered signals
            wr_ready = int(self.dut.fs.wr_ready.value)
            print(f"wait_wr_ready: wr_ready = {wr_ready} (cycle {cycles})")
            if wr_ready:
                break
            # Not ready - wait for next clock edge
            await RisingEdge(self.dut.clk)
            cycles += 1
            if cycles >= timeout_cycles:
                raise TimeoutError(f"wr_ready timeout after {timeout_cycles} cycles")

    async def wait_rd_ready(self, timeout_cycles=10000):
        """Wait for rd_ready to be asserted.
        
        Checks rd_ready in current phase. If not ready, waits for next RisingEdge.
        Returns after a rising edge where rd_ready was asserted.
        """
        cycles = 0
        while True:
            # Check rd_ready directly - works for registered signals
            rd_ready = int(self.dut.fs.rd_ready.value)
            if cycles % 1000 == 0 and cycles > 0:
                print(f"wait_rd_ready: still waiting, rd_ready={rd_ready}, cycle={cycles}")
            if rd_ready:
                print(f"wait_rd_ready: rd_ready asserted at cycle {cycles}")
                break
            # Not ready - wait for next clock edge
            await RisingEdge(self.dut.clk)
            cycles += 1
            if cycles >= timeout_cycles:
                raise TimeoutError(f"rd_ready timeout after {timeout_cycles} cycles")

    async def write_pixels(self, pixels, buf_sel=0, timeout_cycles=10000):
        """Write multiple pixels, honoring wr_ready.
        
        Args:
            pixels: List of (addr, data) tuples
            buf_sel: Buffer selection
            timeout_cycles: Max cycles to wait for wr_ready
        """
        errors = []
        for i, (addr, data) in enumerate(pixels):
            # Wait for wr_ready at ReadOnly phase, then wait for next rising edge
            await self.wait_wr_ready(timeout_cycles)
            
            # Drive write - inputs will be sampled on next rising edge
            is_last = (i == len(pixels) - 1)
            wr_in = {
                'wr_en': 1, 
                'wr_addr': addr, 
                'wr_data': data & 0xFFFF,  # Mask to 16 bits
                'wr_buf_sel': buf_sel, 
                'wr_frame_done': 1 if is_last else 0
            }
            rd_in = {'rd_en': 0}
            
            # Use cycle method which handles timing
            dut_out, model_out = await self.cycle(wr_in, rd_in)
            errors.extend(self.check_outputs(dut_out, model_out, f"write {i} (addr={addr})"))
        
        return errors

    async def read_pixels(self, addresses, buf_sel=1, timeout_cycles=10000):
        """Read multiple pixels, honoring rd_ready.
        
        Args:
            addresses: List of addresses to read
            buf_sel: Buffer selection
            timeout_cycles: Max cycles to wait for rd_ready
        """
        errors = []
        for i, addr in enumerate(addresses):
            # DEBUG: Check rd_ready before waiting
            rd_ready_before = int(self.dut.fs.rd_ready.value)
            print(f"read_pixels[{i}]: rd_ready before wait = {rd_ready_before}")
            # Wait for rd_ready at ReadOnly phase, then wait for next rising edge
            await self.wait_rd_ready(timeout_cycles)
            
            # Drive read - inputs will be sampled on next rising edge
            wr_in = {'wr_en': 0}
            rd_in = {
                'rd_en': 1, 
                'rd_addr0': addr, 
                'rd_addr1': 0, 
                'rd_addr2': 0, 
                'rd_addr3': 0, 
                'rd_buf_sel': buf_sel
            }
            
            dut_out, model_out = await self.cycle(wr_in, rd_in)
            errors.extend(self.check_outputs(dut_out, model_out, f"read {i} (addr={addr})"))
        
        return errors

    def check_outputs(self, dut_out, model_out, name=""):
        """Compare DUT outputs with model."""
        errors = []
        for key in model_out:
            if key in dut_out and dut_out[key] != model_out[key]:
                errors.append(f"{name} {key}: DUT={dut_out[key]}, Model={model_out[key]}")
        return errors


@cocotb.test()
async def test_frame_store_ddr_basic(dut):
    """Basic write/read test."""
    tb = FrameStoreDdrTB(dut)
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await tb.reset()

    # Write a few pixels
    errors = []
    pixels = [(i, (i * 0x111) & 0xFFFF) for i in range(10)]
    errors.extend(await tb.write_pixels(pixels, buf_sel=0))

    # Read back the pixels
    addresses = list(range(10))
    errors.extend(await tb.read_pixels(addresses, buf_sel=1))

    assert not errors, f"Mismatches: {errors}"


@cocotb.test()
async def test_frame_store_ddr_full_frame(dut):
    """Test writing and reading a full small frame."""
    tb = FrameStoreDdrTB(dut)
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await tb.reset()

    frame_w, frame_h = 8, 8
    frame_size = frame_w * frame_h

    # Write full frame
    errors = []
    pixels = []
    for y in range(frame_h):
        for x in range(frame_w):
            addr = y * frame_w + x
            data = ((x << 8) | (y << 4) | ((x + y) & 0xF)) & 0xFFFF
            pixels.append((addr, data))
    errors.extend(await tb.write_pixels(pixels, buf_sel=0))

    # Swap buffers
    await tb.axil_write(0x00, 0x2)  # swap_buf
    # Wait one cycle for swap to take effect
    wr_in = {'wr_en': 0}
    rd_in = {'rd_en': 0}
    dut_out, model_out = await tb.cycle(wr_in, rd_in)
    errors.extend(tb.check_outputs(dut_out, model_out, "post_swap"))

    # Read back full frame
    addresses = list(range(frame_size))
    errors.extend(await tb.read_pixels(addresses, buf_sel=1))

    assert not errors, f"Mismatches: {errors}"


@cocotb.test()
async def test_frame_store_ddr_cache(dut):
    """Test row cache behavior - consecutive reads from same row should hit cache."""
    tb = FrameStoreDdrTB(dut)
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await tb.reset()

    frame_w, frame_h = 16, 16

    # Write a frame
    pixels = []
    for y in range(frame_h):
        for x in range(frame_w):
            addr = y * frame_w + x
            data = addr & 0xFFFF
            pixels.append((addr, data))
    await tb.write_pixels(pixels, buf_sel=0)

    # Swap buffers
    await tb.axil_write(0x00, 0x2)
    # Wait one cycle for swap to take effect
    wr_in = {'wr_en': 0}
    rd_in = {'rd_en': 0}
    await tb.cycle(wr_in, rd_in)

    # Read multiple pixels from the same row (should hit cache after first)
    errors = []
    addresses = [5 * frame_w + x for x in range(frame_w)]
    errors.extend(await tb.read_pixels(addresses, buf_sel=1))

    assert not errors, f"Mismatches: {errors}"


@cocotb.test()
async def test_frame_store_ddr_four_address_read(dut):
    """Test four-address read for bilinear/bicubic interpolation."""
    tb = FrameStoreDdrTB(dut)
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await tb.reset()

    frame_w, frame_h = 8, 8

    # Write a frame with known pattern
    pixels = []
    for y in range(frame_h):
        for x in range(frame_w):
            addr = y * frame_w + x
            data = ((x << 8) | (y << 4) | 0x8) & 0xFFFF
            pixels.append((addr, data))
    await tb.write_pixels(pixels, buf_sel=0)

    # Swap buffers
    await tb.axil_write(0x00, 0x2)
    # Wait one cycle for swap to take effect
    wr_in = {'wr_en': 0}
    rd_in = {'rd_en': 0}
    await tb.cycle(wr_in, rd_in)

    # Read four addresses at once (bilinear taps) - using cycle directly for multi-address
    errors = []
    wr_in = {'wr_en': 0}
    rd_in = {'rd_en': 1, 'rd_addr0': 10, 'rd_addr1': 11, 'rd_addr2': 18, 'rd_addr3': 19, 'rd_buf_sel': 1}
    
    # Wait for rd_ready
    await tb.wait_rd_ready()
    
    dut_out, model_out = await tb.cycle(wr_in, rd_in)
    errors.extend(tb.check_outputs(dut_out, model_out, "four-address read"))

    assert not errors, f"Mismatches: {errors}"


@cocotb.test()
async def test_frame_store_ddr_cache_flush(dut):
    """Test cache flush operation."""
    tb = FrameStoreDdrTB(dut)
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await tb.reset()

    # Write a frame
    pixels = []
    for y in range(8):
        for x in range(8):
            addr = y * 8 + x
            data = addr & 0xFFFF
            pixels.append((addr, data))
    await tb.write_pixels(pixels, buf_sel=0)

    # Swap buffers
    await tb.axil_write(0x00, 0x2)
    # Wait one cycle for swap to take effect
    wr_in = {'wr_en': 0}
    rd_in = {'rd_en': 0}
    await tb.cycle(wr_in, rd_in)

    # Read some pixels to populate cache
    for x in range(4):
        addr = 3 * 8 + x
        await tb.read_pixels([addr], buf_sel=1)

    # Flush cache
    await tb.axil_write(0x00, 0x4)  # cache_flush
    # Wait one cycle for cache flush to take effect
    wr_in = {'wr_en': 0}
    rd_in = {'rd_en': 0}
    await tb.cycle(wr_in, rd_in, cache_flush=True)

    # Read again - should still work (cache refilled from DDR)
    errors = []
    for x in range(4):
        addr = 3 * 8 + x
        errors.extend(await tb.read_pixels([addr], buf_sel=1))

    assert not errors, f"Mismatches: {errors}"


@cocotb.test()
async def test_wr_ready_debug(dut):
    """Debug test to check wr_ready after reset"""
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
    wr_ready = int(dut.fs.wr_ready.value)
    rd_ready = int(dut.fs.rd_ready.value)
    
    print(f"=== After reset: wr_ready = {wr_ready}, rd_ready = {rd_ready} ===")
    
    # Wait a few more cycles and check again
    for i in range(10):
        await RisingEdge(dut.clk)
        wr_ready = int(dut.fs.wr_ready.value)
        rd_ready = int(dut.fs.rd_ready.value)
        print(f"Cycle {i+3}: wr_ready = {wr_ready}, rd_ready = {rd_ready}")
    
    # This test always passes - just for debugging
    assert True


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
        
        # Also check AXI signals on port 1 - read whole packed value then slice
        s_axi_arvalid_val = int(dut.u_dut.s_axi_arvalid.value)
        s_axi_arvalid_1 = (s_axi_arvalid_val >> 1) & 0x1
        s_axi_arready_val = int(dut.u_dut.s_axi_arready.value)
        s_axi_arready_1 = (s_axi_arready_val >> 1) & 0x1
        s_axi_arid_val = int(dut.u_dut.s_axi_arid.value)
        s_axi_arid_1 = (s_axi_arid_val >> 2) & 0x3  # port 1 ID (2 bits)
        s_axi_araddr_val = int(dut.u_dut.s_axi_araddr.value)
        s_axi_araddr_1 = (s_axi_araddr_val >> 18) & 0x3FFFF  # port 1 addr (18 bits)
        s_axi_rvalid_val = int(dut.u_dut.s_axi_rvalid.value)
        s_axi_rvalid_1 = (s_axi_rvalid_val >> 1) & 0x1
        s_axi_rready_val = int(dut.u_dut.s_axi_rready.value)
        s_axi_rready_1 = (s_axi_rready_val >> 1) & 0x1
        s_axi_rid_val = int(dut.u_dut.s_axi_rid.value)
        s_axi_rid_1 = (s_axi_rid_val >> 2) & 0x3  # port 1 RID (2 bits)
        
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
