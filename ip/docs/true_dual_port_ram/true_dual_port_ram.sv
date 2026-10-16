// ***************
// Filename: true_dual_port_ram.sv
// Author: FPGA Cores 4 U
// Description: True dual-port RAM. Version 1.0.0. Two fully independent ports
//   A and B, each with its own clock, enable, write enable, address, data in
//   and registered data out (read-first). Simultaneous writes to the same
//   address from both ports are undefined - the wr_conflict_o flag
//   (simulation-only assertion plus registered detect when both ports share
//   one clock) reports it. Inferred as block RAM in a single-clock
//   configuration. Reset - output registers reset synchronously to zero per
//   port. Latency - 1 clock per port. Errors - DEPTH<2 or WIDTH<1 rejected at
//   elaboration. Clock - the clock of the parent block, all signals are
//   synchronous to it.
//   synchronous to it.
// Date: 2026-09-29

module true_dual_port_ram #(
  parameter int WIDTH = 32,
  parameter int DEPTH = 1024,
  parameter bit DUAL_CLOCK = 1'b0        // 0: both ports use clk_a (clk_b ignored), 1: independent clocks
) (
  input  logic                     clk_a,
  input  logic                     rst_a_n,
  input  logic                     en_a_i,
  input  logic                     we_a_i,
  input  logic [$clog2(DEPTH)-1:0] addr_a_i,
  input  logic [WIDTH-1:0]         wdata_a_i,
  output logic [WIDTH-1:0]         rdata_a_o,
  input  logic                     clk_b,
  input  logic                     rst_b_n,
  input  logic                     en_b_i,
  input  logic                     we_b_i,
  input  logic [$clog2(DEPTH)-1:0] addr_b_i,
  input  logic [WIDTH-1:0]         wdata_b_i,
  output logic [WIDTH-1:0]         rdata_b_o,
  output logic                     wr_conflict_o   // same-address writes in the same clock (shared clock only)
);
