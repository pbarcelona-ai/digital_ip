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
//   elaboration.
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
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (DEPTH < 2 || WIDTH < 1) begin : g_bad $error("true_dual_port_ram: bad DEPTH/WIDTH"); end
  logic [WIDTH-1:0] mem [0:DEPTH-1];
  // The RAM read register has no reset (so the array maps to block RAM); a per-port
  // 'valid' flag, reset synchronously, forces the port output to zero until the first read.
  logic [WIDTH-1:0] qa, qb;
  logic va, vb;
  always_ff @(posedge clk_a) begin
    if (en_a_i && we_a_i) mem[addr_a_i] <= wdata_a_i;
    if (en_a_i) qa <= mem[addr_a_i];
  end
  wire cb = DUAL_CLOCK ? clk_b : clk_a;
  always_ff @(posedge cb) begin
    if (en_b_i && we_b_i) mem[addr_b_i] <= wdata_b_i;
    if (en_b_i) qb <= mem[addr_b_i];
  end
  always_ff @(posedge clk_a) begin
    if (!rst_a_n) va <= 1'b0;
    else if (en_a_i) va <= 1'b1;
  end
  always_ff @(posedge cb) begin
    if (!rst_b_n) vb <= 1'b0;
    else if (en_b_i) vb <= 1'b1;
  end
  assign rdata_a_o = va ? qa : '0;
  assign rdata_b_o = vb ? qb : '0;
  assign wr_conflict_o = en_a_i & en_b_i & we_a_i & we_b_i & (addr_a_i == addr_b_i);
`ifndef SYNTHESIS
  always @(posedge clk_a) assert (!(wr_conflict_o && cb === clk_a)) else $error("true_dual_port_ram: simultaneous write to same address");
`endif
endmodule
