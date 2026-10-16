// ***************
// Filename: baud_nco_top.sv
// Author: FPGA Cores 4 U
// Description: Baud rate generator and NCO IP. Phase accumulator NCO gives
//   a baud tick strobe, square wave and, on an AXI-Stream master, 16 bit
//   sine and cosine samples (tdata = {cos, sin}). AXI-Lite map - 0x00
//   CTRL[0]=en [1]=stream_en [2]=phase reset pulse, 0x04 FCW, 0x08
//   PHASE_OFF[15:0], 0x0C GAIN[14:0], 0x10 STATUS, 0x14 TICK_COUNT (write
//   clears). f_out = f_clk * FCW / 2^PHASE_W. Default FCW is computed for
//   BAUD*OSR at CLK_HZ. Version 1.0.0. Clock - single clock aclk, every
//   input is synchronous to it unless a two-flop synchronizer is
//   mentioned. Reset - synchronous active low aresetn, registers take the
//   documented reset values. Latency - AXI-Lite write response and read
//   data follow the request by about 2 to 3 clocks (ip_axil_regs,
//   registered read path). Timing - registered outputs, no combinational
//   path from the bus to the pins. Errors - out of range AXI-Lite accesses
//   return SLVERR; illegal parameter values stop elaboration with an
//   $error.
// Date: 2026-09-29

module baud_nco_top #(
  parameter int PHASE_W = 32,
  parameter int CLK_HZ  = 100_000_000,   // clock frequency for default FCW
  parameter int BAUD    = 115_200,       // default baud rate
  parameter int OSR     = 16             // default oversampling ratio
) (
  input  logic        aclk,
  input  logic        aresetn,
  // AXI4-Lite slave
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
  // AXI4-Stream master: {cos[15:0], sin[15:0]}
  output logic [31:0] m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast,
  // Direct outputs
  output logic        baud_tick_o,
  output logic        sq_o
);
