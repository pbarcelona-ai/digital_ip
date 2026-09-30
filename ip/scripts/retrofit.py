#!/usr/bin/env python3
# ***************
# Filename: retrofit.py
# Author: Paul Barcelona
# Description: One-off retrofit script used to add IP_VERSION, parameter
#   validation, immediate assertions and documentation text to the first-
#   generation IPs and to regenerate standard file headers. Kept for
#   reference; already applied. Usage - retrofit.py rootdir.
# Date: 2026-09-29
import os, re, sys, textwrap
ROOT = sys.argv[1]
DATE = "2026-09-29"
AXIL_ASSERT = r"""
`ifndef SYNTHESIS
  // ---- immediate assertions (simulation only; skipped by synthesis) ----
  logic ip_chk_b_q, ip_chk_r_q;
  always @(posedge aclk) begin
    if (aresetn) begin
      ip_chk_b_q <= s_axil_bvalid & ~s_axil_bready;
      ip_chk_r_q <= s_axil_rvalid & ~s_axil_rready;
      assert (s_axil_bresp == 2'b00 || s_axil_bresp == 2'b10) else $error("%m: reserved BRESP value");
      assert (s_axil_rresp == 2'b00 || s_axil_rresp == 2'b10) else $error("%m: reserved RRESP value");
      if (ip_chk_b_q) assert (s_axil_bvalid) else $error("%m: BVALID dropped before BREADY");
      if (ip_chk_r_q) assert (s_axil_rvalid) else $error("%m: RVALID dropped before RREADY");
    end else begin ip_chk_b_q <= 1'b0; ip_chk_r_q <= 1'b0; end
  end
`endif
"""
AXIL_DOC = ("Version 1.0.0. Clock - single clock aclk, every input is synchronous to it unless a "
  "two-flop synchronizer is mentioned. Reset - synchronous active low aresetn, registers take the documented "
  "reset values. Latency - AXI-Lite write response and read data follow the request by about 2 to 3 clocks "
  "(ip_axil_regs, registered read path). Timing - registered outputs, no combinational path from the bus "
  "to the pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal parameter values stop "
  "elaboration with an $error.")
def v(cond, msg, name): return f"  if ({cond}) begin : g_chk_{name} $error(\"%m: {msg}\"); end\n"
CFG = {
 "rtl/cdc/reset_ctrl/ip_reset_sync_top.sv": dict(val=v("STAGES < 2","STAGES must be >= 2","stg")+v("NUM_OUT < 1","NUM_OUT must be >= 1","nout")+v("HOLD_DEFAULT < 1","HOLD_DEFAULT must be >= 1","hold"),
   doc="Version 1.0.0. Clock - aclk, the external reset arst_i is asynchronous and is synchronized with STAGES flops. Reset - the reset asserts asynchronously and releases synchronously; outputs are held for HOLD_DEFAULT clocks or the programmed hold. Latency - release is STAGES+1 clocks after arst_i deasserts plus the hold. Errors - illegal parameters stop elaboration; out of range AXI-Lite accesses return SLVERR.", axil=False),
 "rtl/timing/baud_nco/baud_nco_top.sv": dict(val=v("PHASE_W < 16 || PHASE_W > 32","PHASE_W must be 16..32","pw")+v("CLK_HZ < 1 || BAUD < 1 || OSR < 1","CLK_HZ, BAUD and OSR must be positive","pos")+v("BAUD * OSR > CLK_HZ / 2","BAUD*OSR must not exceed CLK_HZ/2","rate"), doc=AXIL_DOC),
 "rtl/timing/pwm/pwm_top.sv": dict(val=v("CHANNELS < 1 || CHANNELS > 8","CHANNELS must be 1..8","ch"), doc=AXIL_DOC),
 "rtl/timing/watchdog/watchdog_top.sv": dict(val=v("RESET_CYCLES < 1","RESET_CYCLES must be >= 1","rc"), doc=AXIL_DOC),
 "rtl/peripherals/gpio/gpio_top.sv": dict(val=v("WIDTH < 1 || WIDTH > 32","WIDTH must be 1..32","w"), doc=AXIL_DOC),
 "rtl/peripherals/intc/intc_top.sv": dict(val=v("NUM_IRQ < 1 || NUM_IRQ > 32","NUM_IRQ must be 1..32","n"), doc=AXIL_DOC),
 "rtl/peripherals/quadrature_decoder/quad_dec_top.sv": dict(val="", doc=AXIL_DOC),
 "rtl/peripherals/uart/uart_top.sv": dict(val=v("CLK_HZ < 1 || BAUD < 1 || BAUD * 16 > CLK_HZ / 2","need BAUD*16 <= CLK_HZ/2","rate")+v("FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0","FIFO_DEPTH must be a power of two >= 2","fd"), doc=AXIL_DOC),
 "rtl/peripherals/i2c_master/i2c_top.sv": dict(val=v("CLK_HZ < 1 || SCL_HZ < 1 || SCL_HZ * 8 > CLK_HZ","need SCL_HZ*8 <= CLK_HZ","rate")+v("FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0","FIFO_DEPTH must be a power of two >= 2","fd"), doc=AXIL_DOC),
 "rtl/peripherals/spi_master/spi_top.sv": dict(val=v("CLK_HZ < 1 || SCLK_HZ < 1 || SCLK_HZ * 2 > CLK_HZ","need SCLK_HZ*2 <= CLK_HZ","rate")+v("DATA_W < 1 || DATA_W > 32","DATA_W must be 1..32","dw")+v("NUM_CS < 1 || NUM_CS > 8","NUM_CS must be 1..8","cs")+v("FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0","FIFO_DEPTH must be a power of two >= 2","fd"), doc=AXIL_DOC),
 "rtl/peripherals/edge_event_capture/edge_event_capture_top.sv": dict(val=v("WIDTH < 1 || WIDTH > 32","WIDTH must be 1..32","w")+v("SYNC_STAGES < 2","SYNC_STAGES must be >= 2","ss")+v("FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0","FIFO_DEPTH must be a power of two >= 2","fd")+v("TS_W < 8 || TS_W > 32","TS_W must be 8..32","ts"), doc=AXIL_DOC),
 "rtl/bus/dma_engine/dma_engine.sv": dict(val=v("MAX_BURST < 1 || MAX_BURST > 256","MAX_BURST must be 1..256 (AXI4 limit)","mb")+v("FIFO_DEPTH < MAX_BURST","FIFO_DEPTH must hold a full burst","fd"), doc=AXIL_DOC+" The AXI4 master follows the AXI4 rules of 4 KB burst boundaries; a bus error response stops the transfer and is reported in STATUS."),
 "rtl/bus/axis_dma/axis_dma.sv": dict(val=v("MAX_BURST < 1 || MAX_BURST > 256","MAX_BURST must be 1..256 (AXI4 limit)","mb")+v("FIFO_DEPTH < MAX_BURST","FIFO_DEPTH must hold a full burst","fd"), doc=AXIL_DOC+" The AXI4 master follows the AXI4 rules of 4 KB burst boundaries; a bus error response stops the transfer and is reported in STATUS."),
 "rtl/fifo/async_fifo/async_fifo.sv": dict(val=v("DEPTH < 4 || (DEPTH & (DEPTH - 1)) != 0","DEPTH must be a power of two >= 4","d")+v("DATA_W < 1","DATA_W must be >= 1","w"), axil=False,
   doc="Version 1.0.0. Clocks - wclk and rclk are unrelated (Gray-coded pointers, two-flop synchronizers), each with its own synchronous active low reset (reset both together). Latency - a written word is visible on the read side 3 to 5 read clocks later; full/empty flags are conservative, never optimistic. Timing - constrain the pointer crossings with set_max_delay -datapath_only (or false path with skew control); the memory read path is registered. Errors - writing when full or reading when empty is ignored (and asserted in simulation); illegal parameters stop elaboration."),
 "rtl/cdc/axis_async_bridge/axis_async_bridge.sv": dict(val=v("DEPTH < 4 || (DEPTH & (DEPTH - 1)) != 0","DEPTH must be a power of two >= 4","d")+v("DATA_W < 1","DATA_W must be >= 1","w"), axil=False,
   doc="Version 1.0.0. Clocks - s_clk and m_clk unrelated, built on async_fifo with the same crossing rules and latency (3 to 5 destination clocks). Reset - synchronous active low per domain. Timing - see async_fifo. Errors - none at run time (full FIFO deasserts s_tready, nothing is dropped); illegal parameters stop elaboration."),
 "rtl/cdc/axi4_lite_cdc/axi4_lite_cdc.sv": dict(val=v("ADDR_W < 2 || ADDR_W > 32","ADDR_W must be 2..32","aw"), axil=False,
   doc="Version 1.0.0. Clocks - s_clk (slave side) and m_clk (master side) unrelated, each channel crosses with a toggle handshake and two-flop synchronizers. Reset - synchronous active low per domain, reset both together. Latency - roughly 6 to 10 clocks of the slower domain per transaction; one transaction outstanding at a time. Timing - address/data registers cross under a max-delay constraint of one destination period. Errors - the master side response (including SLVERR) is passed back unchanged; illegal parameters stop elaboration."),
 "rtl/fifo/ip_axis_fifo.sv": dict(val=v("DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0","DEPTH must be a power of two >= 2","d")+v("DATA_W < 1","DATA_W must be >= 1","w"), axil=False,
   doc="Version 1.0.0. Clock - single clock clk. Reset - synchronous active low, empty. Latency - 2 clocks from tvalid to output (registered read). Timing - registered outputs. Errors - a write while full is refused by tready=0; illegal parameters stop elaboration."),
 "rtl/common/ip_axil_regs.sv": dict(val=v("NREG < 1 || NREG > (1 << (ADDR_W - 2))","NREG must fit the address space","nreg")+v("ADDR_W < 3","ADDR_W must be >= 3","aw"), doc=AXIL_DOC),
 "rtl/cdc/reset_ctrl/rst_sync.sv": dict(val=v("STAGES < 2","STAGES must be >= 2","stg"), axil=False, doc=None),
 "rtl/cdc/axi4_lite_cdc/cdc_sync_bit.sv": dict(val=v("STAGES < 2","STAGES must be >= 2","stg"), axil=False, doc=None),
 "rtl/bus/dma_common/dma_rd_engine.sv": dict(val="", axil=False, doc=None),
 "rtl/bus/dma_common/dma_wr_engine.sv": dict(val="", axil=False, doc=None),
 "rtl/timing/baud_nco/nco_sine_rom.sv": dict(val="", axil=False, doc=None),
 "rtl/peripherals/uart/uart_rx.sv": dict(val="", axil=False, doc=None),
 "rtl/peripherals/uart/uart_baud.sv": dict(val="", axil=False, doc=None),
 "rtl/peripherals/uart/uart_tx.sv": dict(val="", axil=False, doc=None),
 "rtl/peripherals/spi_master/spi_engine.sv": dict(val="", axil=False, doc=None),
 "rtl/peripherals/i2c_master/i2c_master_fsm.sv": dict(val="", axil=False, doc=None),
 "rtl/peripherals/i2c_master/i2c_bit_ctrl.sv": dict(val="", axil=False, doc=None),
 "rtl/timing/baud_nco/nco_core.sv": dict(val=v("PHASE_W < 16 || PHASE_W > 32","PHASE_W must be 16..32","pw"), axil=False, doc=None),
}
def parse_header(txt):
    lines = txt.split("\n"); i = 0
    if not lines[0].startswith("// ***************"): return None
    desc = []; i = 1
    while not lines[i].startswith("// Date:"):
        if lines[i].startswith("// Description:"): desc.append(lines[i][len("// Description:"):].strip())
        elif lines[i].startswith("//   "): desc.append(lines[i][5:].strip())
        i += 1
    return " ".join(desc), "\n".join(lines[i+1:])
def header(fname, desc):
    out = ["// ***************", f"// Filename: {fname}", "// Author: Paul Barcelona"]
    out += textwrap.wrap(desc, width=75, initial_indent="// Description: ", subsequent_indent="//   ")
    out += [f"// Date: {DATE}"]
    assert all(len(l) <= 75 for l in out), out
    return "\n".join(out) + "\n"
for base in ("rtl", "tb", "assertions", "packages"):
    for root, _, files in os.walk(os.path.join(ROOT, base)):
        for f in files:
            if not f.endswith(".sv"): continue
            p = os.path.join(root, f); rel = os.path.relpath(p, ROOT); txt = open(p).read()
            ph = parse_header(txt)
            if not ph: continue
            desc, body = ph
            cfg = CFG.get(rel)
            if cfg:
                if "IP_VERSION" not in body:
                    m = re.search(r"^\);\s*$", body, re.M)
                    assert m, rel
                    block = "  localparam logic [31:0] IP_VERSION = 32'h0001_0000;\n" + cfg["val"]
                    if cfg.get("axil", True): block += AXIL_ASSERT
                    body = body[:m.end()] + "\n" + block + body[m.end():]
                if cfg["doc"] and "Version 1.0.0" not in desc: desc = desc.rstrip() + " " + cfg["doc"]
                elif cfg["doc"] is None and "Version 1.0.0" not in desc: desc = desc.rstrip() + " Version 1.0.0. Helper block of its IP; see the top level description for clock, reset, latency and error behavior."
            open(p, "w").write(header(f, desc) + body)
print("retrofit done")
