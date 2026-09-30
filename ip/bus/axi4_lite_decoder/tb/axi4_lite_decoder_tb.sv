// ***************
// Filename: axi4_lite_decoder_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for axi4_lite_decoder. Three
//   regions of different sizes (4 KB, 64 KB and 256 B at scattered bases)
//   are checked with directed boundary addresses and 20000 random
//   addresses against a behavioral range model (hit, miss). Prints TEST
//   PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module axi4_lite_decoder_tb;
  localparam int AW = 32;
  localparam logic [3*AW-1:0] BASE = {32'h4000_0100, 32'h2001_0000, 32'h1000_1000};
  localparam logic [3*AW-1:0] MASK = {32'hFFFF_FF00, 32'hFFFF_0000, 32'hFFFF_F000};
  logic [AW-1:0] a = 0; logic [2:0] sel; logic miss, multi;
  axi4_lite_decoder #(.ADDR_W(AW), .NSLAVE(3), .BASE(BASE), .MASK(MASK)) dut (.addr_i(a), .sel_o(sel), .miss_o(miss), .multi_o(multi));
  int errors = 0;
  function automatic logic [3:0] model(input logic [31:0] x);   // {miss, sel}
    if (x >= 32'h1000_1000 && x < 32'h1000_2000) return {1'b0, 3'b001};
    if (x >= 32'h2001_0000 && x < 32'h2002_0000) return {1'b0, 3'b010};
    if (x >= 32'h4000_0100 && x < 32'h4000_0200) return {1'b0, 3'b100};
    return 4'b1000;
  endfunction
  task automatic t(input logic [31:0] x);
    logic [3:0] e; a = x; #1; e = model(x);
    if ({miss, sel} !== ((e[3]) ? {1'b1, 3'b000} : {1'b0, e[2:0]}) || multi) begin errors++; $display("ERROR addr %h: sel %b miss %b exp %b", x, sel, miss, e); end
  endtask
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("axi4_lite_decoder_tb.vcd"); $dumpvars(0, axi4_lite_decoder_tb); end
    t(32'h1000_0FFF); t(32'h1000_1000); t(32'h1000_1FFF); t(32'h1000_2000); t(32'h2000_FFFF); t(32'h2001_0000);
    t(32'h2001_FFFF); t(32'h2002_0000); t(32'h4000_00FF); t(32'h4000_0100); t(32'h4000_01FF); t(32'h4000_0200); t(0); t(32'hFFFF_FFFF);
    repeat (20000) begin
      case ($urandom_range(0, 3))
        0: t($urandom);
        1: t(32'h1000_1000 + $urandom_range(0, 8191) - 2048);
        2: t(32'h2001_0000 + $urandom_range(0, 131071) - 32768);
        3: t(32'h4000_0100 + $urandom_range(0, 511) - 128);
      endcase
    end
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
