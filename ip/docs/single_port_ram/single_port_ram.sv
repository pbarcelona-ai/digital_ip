// ***************
// Filename: single_port_ram.sv
// Author: FPGA Cores 4 U
// Description: Generic synchronous single-port RAM. Version 1.0.0. One
//   clock, one address, optional byte write enables (BYTE_EN). Read
//   behaviour on a write to the same address is selectable - MODE 0
//   READ_FIRST (old data), 1 WRITE_FIRST (new data), 2 NO_CHANGE (output
//   holds). Inferred as block RAM by Yosys and Vivado. Clock - clk. Reset
//   - none on the array; the output register resets synchronously (active
//   low) to zero, memory content is undefined until written unless
//   INIT_ZERO=1. Latency - read data valid one clock after the address.
//   Errors - DEPTH<2, WIDTH<1, or invalid MODE rejected at elaboration;
//   BYTE_EN requires WIDTH multiple of 8.
// Date: 2026-09-29

module single_port_ram #(
  parameter int WIDTH     = 32,
  parameter int DEPTH     = 1024,
  parameter int MODE      = 0,           // 0 read-first, 1 write-first, 2 no-change
  parameter bit BYTE_EN   = 1'b0,
  parameter bit INIT_ZERO = 1'b0
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     en_i,
  input  logic                     we_i,
  input  logic [WIDTH/8-1:0]       be_i,      // used when BYTE_EN=1
  input  logic [$clog2(DEPTH)-1:0] addr_i,
  input  logic [WIDTH-1:0]         wdata_i,
  output logic [WIDTH-1:0]         rdata_o
);
