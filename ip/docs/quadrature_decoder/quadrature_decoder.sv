// ***************
// Filename: quad_dec_top.sv
// Author: FPGA Cores 4 U
// Description: Quadrature encoder decoder IP. A/B/index inputs pass two
//   flop synchronizers and a programmable stability filter, then a x4
//   decoder updates a 32 bit signed position counter, direction flag and
//   illegal transition (error) counter. Index pulse latches and optionally
//   clears the position. A window timer measures counts per window
//   (velocity) and emits each sample on an AXI-Stream master. Map - 0x00
//   CTRL [0]en [1]clear pos (pulse) [2]index clears pos [3]swap A/B
//   [15:8]filter clocks, 0x04 POSITION, 0x08 VELOCITY, 0x0C WINDOW clocks,
//   0x10 STATUS [0]dir [1]error [2]index seen (W1C), 0x14 ERR_COUNT, 0x18
//   INDEX_POS. Version 1.0.0. Clock - single clock aclk, every input is
//   synchronous to it unless a two-flop synchronizer is mentioned. Reset -
//   synchronous active low aresetn, registers take the documented reset
//   values. Latency - AXI-Lite write response and read data follow the
//   request by about 2 to 3 clocks (ip_axil_regs, registered read path).
//   Timing - registered outputs, no combinational path from the bus to the
//   pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal
//   parameter values stop elaboration with an $error.
// Date: 2026-09-29

module quad_dec_top (
  input  logic        aclk,
  input  logic        aresetn,
  // AXI4-Lite slave (register access)
  input  logic [7:0]  s_axil_awaddr,
  input  logic        s_axil_awvalid,
  output logic        s_axil_awready,
  input  logic [31:0] s_axil_wdata,
  input  logic [3:0]  s_axil_wstrb,
  input  logic        s_axil_wvalid,
  output logic        s_axil_wready,
  output logic [1:0]  s_axil_bresp,
  output logic        s_axil_bvalid,
  input  logic        s_axil_bready,
  input  logic [7:0]  s_axil_araddr,
  input  logic        s_axil_arvalid,
  output logic        s_axil_arready,
  output logic [31:0] s_axil_rdata,
  output logic [1:0]  s_axil_rresp,
  output logic        s_axil_rvalid,
  input  logic        s_axil_rready,
  input  logic        enc_a_i,
  input  logic        enc_b_i,
  input  logic        enc_z_i,
  // Velocity samples (signed counts per window)
  output logic [31:0] m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast
);
