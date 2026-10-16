// ***************
// Filename: fallthrough_fifo.sv
// Author: FPGA Cores 4 U
// Description: First-word-fall-through FIFO with valid/ready handshakes.
//   Version 1.0.0. The oldest word is presented on m_data_o as soon as the
//   FIFO is not empty (m_valid_o), with no read latency; m_ready_i pops
//   it. Storage is a register-array with asynchronous read (distributed
//   RAM style), intended for shallow FIFOs (DEPTH <= 64); use ip_axis_fifo
//   for deep block-RAM FIFOs. Clock - clk. Reset - synchronous active low,
//   empty. Latency - 1 clock from a write into an empty FIFO to m_valid_o.
//   Overflow - s_ready_o is low when full, so a compliant source never
//   overflows. Errors - DEPTH must be a power of two >= 2 (rejected at
//   elaboration).
// Date: 2026-09-29

module fallthrough_fifo #(
  parameter int WIDTH = 32,
  parameter int DEPTH = 16
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic [WIDTH-1:0]       s_data_i,
  input  logic                   s_valid_i,
  output logic                   s_ready_o,
  output logic [WIDTH-1:0]       m_data_o,
  output logic                   m_valid_o,
  input  logic                   m_ready_i,
  output logic [$clog2(DEPTH):0] level_o
);
