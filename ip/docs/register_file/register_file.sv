// ***************
// Filename: register_file.sv
// Author: FPGA Cores 4 U
// Description: Multi-register file. Version 1.0.0. NREG registers of WIDTH
//   bits with one write port and NRD combinational read ports (asynchronous
//   read, so no read latency - LUT-RAM friendly). ZERO_REG0=1 hard-wires
//   register 0 to zero. Write-through bypass (BYPASS=1) returns write data on
//   a read of the register being written in the same clock. Clock - clk.
//   Reset - synchronous active low, all registers cleared. Errors - NREG<2
//   rejected at elaboration; writes to register 0 with ZERO_REG0 are ignored.
//   Latency - as documented in the parent block, fixed and independent of
//   data.
//   data.
// Date: 2026-09-29

module register_file #(
  parameter int WIDTH     = 32,
  parameter int NREG      = 16,
  parameter int NRD       = 2,
  parameter bit ZERO_REG0 = 1'b0,
  parameter bit BYPASS    = 1'b0
) (
  input  logic                              clk,
  input  logic                              rst_n,
  input  logic                              we_i,
  input  logic [$clog2(NREG)-1:0]           waddr_i,
  input  logic [WIDTH-1:0]                  wdata_i,
  input  logic [NRD*$clog2(NREG)-1:0]       raddr_i,   // NRD packed addresses
  output logic [NRD*WIDTH-1:0]              rdata_o
);
