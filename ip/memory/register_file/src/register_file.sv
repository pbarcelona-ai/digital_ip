// ***************
// Filename: register_file.sv
// Author: Paul Barcelona
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
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam int AW = $clog2(NREG);
  if (NREG < 2) begin : g_bad $error("register_file: NREG must be >= 2"); end
  logic [WIDTH-1:0] regs [0:NREG-1];
  always_ff @(posedge clk) begin
    if (!rst_n) for (int i = 0; i < NREG; i++) regs[i] <= '0;
    else if (we_i && !(ZERO_REG0 && waddr_i == '0)) regs[waddr_i] <= wdata_i;
  end
  always_comb begin
    for (int p = 0; p < NRD; p++) begin
      logic [AW-1:0] ra; ra = raddr_i[p*AW +: AW];
      if (ZERO_REG0 && ra == '0) rdata_o[p*WIDTH +: WIDTH] = '0;
      else if (BYPASS && we_i && ra == waddr_i) rdata_o[p*WIDTH +: WIDTH] = wdata_i;
      else rdata_o[p*WIDTH +: WIDTH] = regs[ra];
    end
  end
endmodule
