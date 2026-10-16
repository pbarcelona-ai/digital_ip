// ***************
// Filename: ip_axis_fifo.sv
// Author: FPGA Cores 4 U
// Description: Single clock AXI-Stream FIFO with tlast and tuser sideband
//   bits. Storage is a synchronous-read memory that maps to block RAM for
//   deep configurations, followed by a two register output pipeline
//   (memory data register and output register) so every path is short at
//   100 MHz. Reports the total number of stored entries on level_o.
//   Version 1.0.0. Clock - single clock clk. Reset - synchronous active
//   low, empty. Latency - 2 clocks from tvalid to output (registered
//   read). Timing - registered outputs. Errors - a write while full is
//   refused by tready=0; illegal parameters stop elaboration.
// Date: 2026-09-29

module ip_axis_fifo #(
  parameter int DATA_W = 8,     // tdata width
  parameter int DEPTH  = 512    // memory depth, must be a power of two >= 2
) (
  input  logic                     clk,
  input  logic                     rst_n,
  // Slave (write) port
  input  logic [DATA_W-1:0]        s_tdata,
  input  logic                     s_tlast,
  input  logic                     s_tuser,
  input  logic                     s_tvalid,
  output logic                     s_tready,
  // Master (read) port
  output logic [DATA_W-1:0]        m_tdata,
  output logic                     m_tlast,
  output logic                     m_tuser,
  output logic                     m_tvalid,
  input  logic                     m_tready,
  // Number of words held in the FIFO
  output logic [$clog2(DEPTH)+1:0] level_o
);
