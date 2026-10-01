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
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (DEPTH < 2 || WIDTH < 1) begin : g_bad $error("single_port_ram: bad DEPTH/WIDTH"); end
  if (MODE < 0 || MODE > 2) begin : g_badm $error("single_port_ram: MODE must be 0..2"); end
  if (BYTE_EN && (WIDTH % 8) != 0) begin : g_badb $error("single_port_ram: BYTE_EN needs WIDTH % 8 == 0"); end
  logic [WIDTH-1:0] mem [0:DEPTH-1];
  if (INIT_ZERO) begin : g_init
    initial for (int i = 0; i < DEPTH; i++) mem[i] = '0;
  end
  always_ff @(posedge clk) begin
    if (en_i) begin
      if (we_i) begin
        if (BYTE_EN) begin
          for (int b = 0; b < WIDTH/8; b++) if (be_i[b]) mem[addr_i][b*8 +: 8] <= wdata_i[b*8 +: 8];
        end else mem[addr_i] <= wdata_i;
      end
    end
  end
  always_ff @(posedge clk) begin
    if (!rst_n) rdata_o <= '0;
    else if (en_i) begin
      if (we_i && MODE == 1) begin
        if (BYTE_EN) begin
          for (int b = 0; b < WIDTH/8; b++) rdata_o[b*8 +: 8] <= be_i[b] ? wdata_i[b*8 +: 8] : mem[addr_i][b*8 +: 8];
        end else rdata_o <= wdata_i;
      end
      else if (!(we_i && MODE == 2)) rdata_o <= mem[addr_i];
    end
  end
endmodule
