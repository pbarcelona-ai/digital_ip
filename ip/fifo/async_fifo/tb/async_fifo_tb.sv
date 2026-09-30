// ***************
// Filename: async_fifo_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for the asynchronous FIFO. Two
//   instances with unrelated clock ratios (fast write to slow read and
//   slow write to fast read) are fed random data with random valid and
//   ready patterns; a scoreboard checks order and integrity, and the test
//   checks that full is reached and no data is lost or duplicated. Prints
//   TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps

module afifo_case #(
  parameter real WPER = 10.0, parameter real RPER = 27.0, parameter int DEPTH = 16,
  parameter int N = 3000
) (output int errors, output bit done);
  logic wclk = 0, rclk = 0, wrst_n = 0, rrst_n = 0;
  always #(WPER/2) wclk = ~wclk;
  always #(RPER/2) rclk = ~rclk;
  logic [15:0] wdata, rdata; logic wvalid, wready, rvalid, rready;
  logic [$clog2(DEPTH):0] wlevel;
  async_fifo #(.DATA_W(16), .DEPTH(DEPTH)) dut (.wclk, .wrst_n, .wdata, .wvalid, .wready,
    .wlevel_o(wlevel), .rclk, .rrst_n, .rdata, .rvalid, .rready);
  int wcount = 0, rcount = 0, full_seen = 0;
  logic [15:0] expq[$];
  initial begin errors = 0; done = 0; wvalid = 0; rready = 0; wdata = 0;
    repeat (4) @(posedge wclk); wrst_n = 1; rrst_n = 1; end
  // Writer: random gaps
  always @(posedge wclk) if (wrst_n) begin
    if (wvalid && wready) begin expq.push_back(wdata); wcount++; end
    if (!wready) full_seen++;
    if (wcount < N) begin
      if (!wvalid || wready) begin
        wvalid <= ($urandom_range(0, 9) < 8); wdata <= $urandom;
      end
    end else if (wready) wvalid <= 0;
  end
  // Reader: random back pressure (heavier in first half to force full)
  always @(posedge rclk) if (rrst_n) begin
    rready <= (rcount < N/3) ? ($urandom_range(0, 9) < 2) : ($urandom_range(0, 9) < 8);
    if (rvalid && rready) begin
      if (expq.size() == 0) begin errors++; $display("ERROR: read with no expected data"); end
      else begin
        logic [15:0] e; e = expq.pop_front();
        if (rdata !== e) begin errors++; $display("ERROR: got %h exp %h (#%0d)", rdata, e, rcount); end
      end
      rcount++;
      if (rcount == N) begin
        if (full_seen == 0) begin errors++; $display("ERROR: FIFO never became full"); end
        done = 1;
      end
    end
  end
endmodule

module async_fifo_tb;
  int e1, e2; bit d1, d2;
  afifo_case #(.WPER(10.0), .RPER(27.0)) c1 (.errors(e1), .done(d1));   // fast write
  afifo_case #(.WPER(23.0), .RPER(7.0))  c2 (.errors(e2), .done(d2));   // fast read
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("async_fifo_tb.vcd"); $dumpvars(0, async_fifo_tb); end
    wait (d1 && d2); #1000;
    if (e1 + e2 == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", e1 + e2);
    $finish;
  end
  initial begin #20_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
