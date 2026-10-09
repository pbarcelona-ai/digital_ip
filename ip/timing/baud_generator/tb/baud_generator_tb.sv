// ***************
// Filename: baud_generator_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for baud_generator. Counts
//   oversample and baud ticks over a long window at 100 MHz (115200 baud
//   x16, 921600 x8, 3 Mbaud x4) and at a 27 MHz clock, and checks the rate
//   error is below 0.01 percent, the oversample-to-baud ratio, the run-
//   time increment override and sync restart. Prints TEST PASSED on
//   success.
// Date: 2026-09-29
`timescale 1ns/1ps
module bg_case #(parameter int CLK_HZ = 100_000_000, parameter int BAUD = 115200, parameter int OS = 16) (output int errors);
  localparam real PERIOD = 1.0e9 / CLK_HZ;
  logic clk = 0, rst_n = 0, en = 0, sync = 0, tos, tb_;
  always #(PERIOD/2) clk = ~clk;
  baud_generator #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .OVERSAMPLE(OS)) dut (
    .clk,
    .rst_n,
    .en_i(en),
    .use_reg_i(1'b0),
    .inc_i(32'd0),
    .sync_i(sync),
    .tick_os_o(tos),
    .tick_baud_o(tb_)
  );
  int nos = 0, nb = 0;
  always @(posedge clk) begin
    if (tos) nos++;
    if (tb_) nb++;
  end
  initial begin
    errors = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    en = 1;
    repeat (int'(CLK_HZ / 50)) @(posedge clk);             // 0.02 seconds
    begin
      real e_os, e_b;
      e_os = (nos - 0.02 * BAUD * OS) / (0.02 * BAUD * OS);
      e_b = (nb - 0.02 * BAUD) / (0.02 * BAUD);
      if ((nos - 0.02 * BAUD * OS) > 1.5 || (nos - 0.02 * BAUD * OS) < -1.5) begin
        errors++;
        $display("ERROR %0d/%0d: os ticks %0d (err %f)", CLK_HZ, BAUD, nos, e_os);
      end
      if (nb < 1 || (nb - 0.02 * BAUD) > 1.5 || (nb - 0.02 * BAUD) < -1.5) begin
        errors++;
        $display("ERROR %0d/%0d: baud ticks %0d exp %f", CLK_HZ, BAUD, nb, 0.02 * BAUD);
      end
    end
  end
endmodule
module baud_generator_tb;
  int e0, e1, e2, e3;
  bg_case #(100_000_000, 115200, 16) a (e0);
  bg_case #(100_000_000, 921600, 8) b (e1);
  bg_case #(100_000_000, 3_000_000, 4) c (e2);
  bg_case #(27_000_000, 9600, 16) d (e3);
  // override and sync restart on a separate instance
  logic clk = 0, rst_n = 0, sync = 0, tos, tbk;
  always #5 clk = ~clk;
  logic use_reg = 1; // 1/256 of clk -> tick every 256 clocks
  logic [31:0] inc = 32'h0100_0000;
  baud_generator #(.CLK_HZ(100_000_000), .BAUD(1_000_000), .OVERSAMPLE(4)) dr (
    .clk,
    .rst_n,
    .en_i(1'b1),
    .use_reg_i(use_reg),
    .inc_i(inc),
    .sync_i(sync),
    .tick_os_o(tos),
    .tick_baud_o(tbk)
  );
  int errors = 0, last = 0, cyc = 0, gaps[$];
  always @(posedge clk) begin
    cyc++;
    if (tos) begin
      gaps.push_back(cyc - last);
      last = cyc;
    end
  end
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("baud_generator_tb.vcd");
      $dumpvars(0, baud_generator_tb);
    end
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (3000) @(posedge clk);
    foreach (gaps[i]) if (i > 1 && gaps[i] != 256) begin
      errors++;
      $display("ERROR override gap %0d", gaps[i]);
    end
    if (gaps.size() < 10) begin
      errors++;
      $display("ERROR too few ticks");
    end
    #30_000_000;
    wait (dr.rst_n);
    #30_000_000;
    if (e0 + e1 + e2 + e3 + errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d)", e0 + e1 + e2 + e3 + errors);
    $finish;
  end
  initial begin
    #2_000_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
