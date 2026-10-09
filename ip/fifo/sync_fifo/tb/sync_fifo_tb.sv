// ***************
// Filename: sync_fifo_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for sync_fifo. Random simultaneous
//   reads and writes checked against a reference queue including full,
//   empty, level, almost flags, overflow and underflow sticky flags (with
//   clear), and one clock read latency. Prints TEST PASSED on success.
//   The test tasks are in tests/sync_fifo_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module sync_fifo_tb;
  localparam int D = 16;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic wr = 0, rd = 0, rv, full, empty, af, ae, clr = 0, ovf, unf;
  logic [15:0] wdat = 0, rdat;
  logic [4:0] lvl;
  sync_fifo #(.WIDTH(16), .DEPTH(D)) dut (
    .clk,
    .rst_n,
    .wr_en_i(wr),
    .wdata_i(wdat),
    .rd_en_i(rd),
    .rdata_o(rdat),
    .rd_valid_o(rv),
    .full_o(full),
    .empty_o(empty),
    .level_o(lvl),
    .afull_thresh_i(5'd12),
    .aempty_thresh_i(5'd2),
    .almost_full_o(af),
    .almost_empty_o(ae),
    .clr_err_i(clr),
    .overflow_o(ovf),
    .underflow_o(unf)
  );
  int errors = 0;
  logic [15:0] q[$];
  logic exp_v;
  logic [15:0] exp_d;
  // test tasks: tests/sync_fifo_tests.sv
  `include "sync_fifo_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("sync_fifo_tb.vcd");
      $dumpvars(0, sync_fifo_tb);
    end
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);
    check(empty && !full && lvl == 0 && ae && !af, "reset state");
    // underflow
    @(posedge clk);
    #1 rd = 1;
    @(posedge clk);
    #1 rd = 0;
    @(posedge clk);
    #1;
    check(unf == 1 && rv == 0, "underflow flag");
    clr = 1;
    @(posedge clk);
    #1 clr = 0;
    @(posedge clk);
    #1 check(unf == 0, "clr underflow");
    // fill to full and overflow
    for (int i = 0; i < D + 2; i++) begin
      @(posedge clk);
      #1 wr = 1;
      wdat = 16'h1000 + i;
    end
    @(posedge clk);
    #1 wr = 0;
    @(posedge clk);
    #1;
    check(full && lvl == D && ovf && af && !ae, $sformatf("full state lvl %0d", lvl));
    // read everything: ordering and latency
    for (int i = 0; i < D; i++) begin
      @(posedge clk);
      #1 rd = 1;
      @(posedge clk);
      #1 rd = 0;
      check(rv && rdat == 16'h1000 + i, $sformatf("read %0d got %h rv %b", i, rdat, rv));
    end
    rd = 0;
    @(posedge clk);
    #1 check(empty && lvl == 0 && ae, "empty after drain");
    // random traffic vs model
    for (int n = 0; n < 4000; n++) begin
      logic do_w, do_r;
      @(posedge clk);
      #1;
      wr = ($urandom_range(0, 9) < 5);
      rd = ($urandom_range(0, 9) < 5);
      wdat = $urandom;
      // model uses the values applied now and the state before the next edge
      do_w = wr && q.size() < D;
      do_r = rd && q.size() > 0;
      exp_v = do_r;
      if (do_r) exp_d = q[0];
      if (do_w) q.push_back(wdat);
      if (do_r) void'(q.pop_front());
      @(posedge clk);
      #1;
      check(rv === exp_v, "rd_valid");
      if (exp_v) check(rdat === exp_d, $sformatf("data %h exp %h", rdat, exp_d));
      check(lvl == q.size(), $sformatf("level %0d exp %0d", lvl, q.size()));
      check(full == (q.size() == D) && empty == (q.size() == 0), "flags");
      wr = 0;
      rd = 0;
    end
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #5000000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
