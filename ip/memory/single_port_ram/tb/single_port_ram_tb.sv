// ***************
// Filename: single_port_ram_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for single_port_ram. Random reads
//   and writes compared with a reference array for all three read-during-
//   write modes, with and without byte enables. Prints TEST PASSED on
//   success.
// Date: 2026-09-29
`timescale 1ns/1ps
module spram_case #(parameter int MODE = 0, parameter bit BE = 0) (input logic clk, input logic rst_n, output int errors);
  localparam int D = 64, W = 32;
  logic en, we;
  logic [3:0] be;
  logic [5:0] a;
  logic [W-1:0] wd, rd;
  single_port_ram #(.WIDTH(W), .DEPTH(D), .MODE(MODE), .BYTE_EN(BE), .INIT_ZERO(1)) dut
    (
    .clk,
    .rst_n,
    .en_i(en),
    .we_i(we),
    .be_i(be),
    .addr_i(a),
    .wdata_i(wd),
    .rdata_o(rd)
  );
  logic [W-1:0] ref_m [0:D-1];
  logic [W-1:0] exp_q;
  initial begin
    errors = 0;
    for (int i = 0; i < D; i++) ref_m[i] = 0;
    en = 0;
    we = 0;
    be = 0;
    a = 0;
    wd = 0;
    exp_q = 0;
  end
  always @(posedge clk) if (rst_n) begin
    if (en) begin
      if (we) begin
        logic [W-1:0] nw;
        nw = ref_m[a];
        for (int b = 0; b < 4; b++) if (!BE || be[b]) nw[b*8 +: 8] = wd[b*8 +: 8];
        if (MODE == 0) exp_q <= ref_m[a];
        else if (MODE == 1) exp_q <= nw;
        ref_m[a] <= nw;
      end else exp_q <= ref_m[a];
    end
  end
  always @(negedge clk) if (rst_n && rd !== exp_q) begin
    errors++;
    $display("ERROR mode %0d be %0d: rd %h exp %h", MODE, BE, rd, exp_q);
  end
  always @(posedge clk) if (rst_n) begin
    #1 en = $urandom_range(0, 9) < 8;
    we = $urandom_range(0, 1);
    be = $urandom;
    a = $urandom_range(0, 15);
    wd = $urandom;
  end
endmodule
module single_port_ram_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int e0, e1, e2, e3;
  spram_case #(0, 0) c0 (
    clk,
    rst_n,
    e0
  );
  spram_case #(1, 0) c1 (
    clk,
    rst_n,
    e1
  );
  spram_case #(2, 1) c2 (
    clk,
    rst_n,
    e2
  );
  spram_case #(1, 1) c3 (
    clk,
    rst_n,
    e3
  );
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("single_port_ram_tb.vcd");
      $dumpvars(0, single_port_ram_tb);
    end
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (3000) @(posedge clk);
    #2;
    if (e0 + e1 + e2 + e3 == 0) $display("TEST PASSED");
    else $display("TEST FAILED");
    $finish;
  end
endmodule
