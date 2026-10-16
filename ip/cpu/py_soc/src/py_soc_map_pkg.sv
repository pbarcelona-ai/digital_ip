// ***************
// Filename: py_soc_map_pkg.sv
// Author: FPGA Cores 4 U
// Description: Memory map of py_soc (CPU clock domain): the base address of
//   every register window on its AXI4-Lite interconnect. py_soc's decoder
//   (py_axil_xbar BASE / MASK), the testbenches and the firmware (pyc.py:
//   "from py_soc_map_pkg import *") take the addresses from this file, so
//   they agree by construction. Each peripheral window is 256 bytes (the
//   register map: ID block at +0x00, registers from +0x10); a streaming
//   peripheral's py_stream_port data port is a second window at +DPORT.
//   EXT is the window of the m_ext_axil_* master port (EXT_EN = 1): a design
//   around py_soc places its own registers there (see its map package, e.g.
//   video_processor_map_pkg).
// Date: 2026-10-12
package py_soc_map_pkg;
  localparam logic [31:0] WIN_MASK    = 32'hFFFF_FF00;   // a 256-byte register window
  localparam logic [31:0] DPORT       = 32'h0000_0100;   // data port window after the registers
  localparam logic [31:0] SYSCTL_BASE = 32'h0000_0100;
  localparam logic [31:0] INTC_BASE   = 32'h0000_1000;
  localparam logic [31:0] WDT_BASE    = 32'h0000_2000;
  localparam logic [31:0] GPIO0_BASE  = 32'h0000_3000;
  localparam logic [31:0] GPIO1_BASE  = 32'h0000_4000;
  localparam logic [31:0] GPIO2_BASE  = 32'h0000_5000;
  localparam logic [31:0] UART0_BASE  = 32'h0000_6000;   // + DPORT: UART0 data port
  localparam logic [31:0] UART1_BASE  = 32'h0000_7000;
  localparam logic [31:0] I2C0_BASE   = 32'h0000_8000;
  localparam logic [31:0] I2C1_BASE   = 32'h0000_9000;
  localparam logic [31:0] SPI0_BASE   = 32'h0000_A000;
  localparam logic [31:0] SPI1_BASE   = 32'h0000_B000;
  localparam logic [31:0] FLASH_BASE  = 32'h0000_C000;
  localparam logic [31:0] EXT_BASE    = 32'h0001_0000;   // 0x1_0000-0x1_FFFF: m_ext_axil_*
  localparam logic [31:0] EXT_MASK    = 32'hFFFF_0000;
endpackage
