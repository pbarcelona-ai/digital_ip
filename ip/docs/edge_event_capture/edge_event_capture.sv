// ***************
// Filename: edge_event_capture_top.sv
// Author: FPGA Cores 4 U
// Description: Multi-channel edge detector IP. Each of WIDTH inputs goes
//   through a synchronizer chain, an optional debounce filter (input must
//   be stable for DEBOUNCE clocks), and rise/fall detection with enable
//   masks. Events set write-1-to-clear pending flags, increment an event
//   counter, drive direct pulse outputs and are timestamped into an AXI-
//   Stream event record {timestamp, fall flags, rise flags} through a FIFO
//   (drop counter on overflow). Map - 0x00 CTRL [0]en, 0x04 RISE_EN, 0x08
//   FALL_EN, 0x0C DEBOUNCE clocks, 0x10 RISE_PEND (W1C), 0x14 FALL_PEND
//   (W1C), 0x18 EVENT_COUNT, 0x1C TIMESTAMP, 0x20 DROP_COUNT, 0x24 IRQ_EN.
//   Version 1.0.0. Clock - single clock aclk, every input is synchronous
//   to it unless a two-flop synchronizer is mentioned. Reset - synchronous
//   active low aresetn, registers take the documented reset values.
//   Latency - AXI-Lite write response and read data follow the request by
//   about 2 to 3 clocks (ip_axil_regs, registered read path). Timing -
//   registered outputs, no combinational path from the bus to the pins.
//   Errors - out of range AXI-Lite accesses return SLVERR; illegal
//   parameter values stop elaboration with an $error.
// Date: 2026-09-29

module edge_event_capture_top #(
  parameter int WIDTH      = 8,
  parameter int SYNC_STAGES = 2,
  parameter int FIFO_DEPTH = 512,
  parameter int TS_W       = 32
) (
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
  input  logic [WIDTH-1:0]         sig_i,
  output logic [WIDTH-1:0]         rise_o,      // one clock pulses
  output logic [WIDTH-1:0]         fall_o,
  output logic                     irq_o,
  // Event record stream: {timestamp, fall flags, rise flags}
  output logic [TS_W+2*WIDTH-1:0]  m_axis_tdata,
  output logic                     m_axis_tvalid,
  input  logic                     m_axis_tready,
  output logic                     m_axis_tlast
);
