// ***************
// Filename: axi4_lite_regs.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Lite register bank with per-register access types.
//   Version 1.0.0. NREG 32-bit registers, each RW (0, software read/write
//   with byte strobes), RO (1, reads hw_i, writes rejected with SLVERR),
//   W1C (2, status register - hardware sets bits through hw_set_i,
//   software clears bits by writing 1) or W1S (3, software sets bits by
//   writing 1, hardware clears through hw_set_i). ACCESS holds 2 bits per
//   register. RESET_VALS holds reset values. reg_o exposes RW/W1C/W1S
//   state, wr_pulse_o pulses for one clock on any write to register n.
//   Built on axi4_lite_slave (same handshake rules and latency). Clock -
//   aclk. Reset - synchronous aresetn, registers take RESET_VALS. Latency
//   - write 4 clocks, read 4 clocks. Errors - SLVERR on write to RO,
//   DECERR beyond NREG words; NREG < 1 rejected at elaboration.
// Date: 2026-09-29

module axi4_lite_regs #(
  parameter int ADDR_W = 8,
  parameter int NREG   = 8,
  parameter logic [2*NREG-1:0]  ACCESS     = '0,     // 2 bits per register
  parameter logic [32*NREG-1:0] RESET_VALS = '0
) (
  input  logic              aclk,
  input  logic              aresetn,
  input  logic [ADDR_W-1:0] s_axil_awaddr,
  input  logic              s_axil_awvalid,
  output logic              s_axil_awready,
  input  logic [31:0]       s_axil_wdata,
  input  logic [3:0]        s_axil_wstrb,
  input  logic              s_axil_wvalid,
  output logic              s_axil_wready,
  output logic [1:0]        s_axil_bresp,
  output logic              s_axil_bvalid,
  input  logic              s_axil_bready,
  input  logic [ADDR_W-1:0] s_axil_araddr,
  input  logic              s_axil_arvalid,
  output logic              s_axil_arready,
  output logic [31:0]       s_axil_rdata,
  output logic [1:0]        s_axil_rresp,
  output logic              s_axil_rvalid,
  input  logic              s_axil_rready,
  input  logic [32*NREG-1:0] hw_i,          // RO register values
  input  logic [32*NREG-1:0] hw_set_i,      // W1C: set bits, W1S: clear bits (one clock pulses)
  output logic [32*NREG-1:0] reg_o,
  output logic [NREG-1:0]    wr_pulse_o
);
