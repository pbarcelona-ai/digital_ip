// ***************
// Filename: ecc_memory_ctrl_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for ecc_memory_ctrl and the
//   ecc_encoder/ecc_decoder pair. Exhaustive single-bit error injection
//   into every codeword bit position and random double-bit errors for 8,
//   32 and 64 bit words (all singles must be corrected, all doubles
//   detected); then the controller with scrubbing - random writes and
//   reads, single-bit memory errors that must be corrected and scrubbed (a
//   second read is clean), double-bit errors that must be flagged, an
//   overall-parity-bit error, the error counters and the read latency.
//   Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module ecc_code_case #(parameter int DW = 32) (output int errors);
  localparam int R = $clog2(DW + $clog2(DW + 1) + 1); localparam int CW = DW + R + 1;
  logic [DW-1:0] d, dout; logic [CW-1:0] code, bad; logic sec, ded; logic [R-1:0] syn;
  ecc_encoder #(.DATA_W(DW)) e (.data_i(d), .code_o(code));
  ecc_decoder #(.DATA_W(DW)) dd (.code_i(bad), .data_o(dout), .sec_o(sec), .ded_o(ded), .syndrome_o(syn));
  initial begin
    errors = 0;
    for (int n = 0; n < 40; n++) begin
      d = {DW{1'b0}}; for (int b = 0; b < DW; b += 32) d[b +: 32] = $urandom; #1;
      bad = code; #1; if (sec || ded || dout !== d) begin errors++; $display("ERROR DW=%0d clean word flagged", DW); end
      for (int i = 0; i < CW; i++) begin
        bad = code; bad[i] = ~bad[i]; #1;
        if (!sec || ded || dout !== d) begin errors++; $display("ERROR DW=%0d single error bit %0d: sec %b ded %b", DW, i, sec, ded); end
      end
      for (int k = 0; k < 60; k++) begin
        int a, b2; a = $urandom_range(0, CW - 1); b2 = $urandom_range(0, CW - 1); if (a == b2) b2 = (a + 1) % CW;
        bad = code; bad[a] = ~bad[a]; bad[b2] = ~bad[b2]; #1;
        if (!ded || sec) begin errors++; $display("ERROR DW=%0d double error %0d,%0d not detected", DW, a, b2); end
      end
    end
  end
endmodule
module ecc_memory_ctrl_tb;
  localparam int DW = 32, CW = 39, D = 64;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  logic req = 0, we = 0, rdy, rv, sec, ded, clr = 0; logic [5:0] a = 0; logic [DW-1:0] wd = 0, rd; logic [CW-1:0] inj = 0; logic [15:0] sc, dc; logic [5:0] ea;
  ecc_memory_ctrl #(.DATA_W(DW), .DEPTH(D), .SCRUB(1)) dut (.clk, .rst_n, .req_i(req), .we_i(we), .addr_i(a), .wdata_i(wd), .ready_o(rdy), .inject_i(inj), .rvalid_o(rv), .rdata_o(rd), .sec_o(sec), .ded_o(ded),
    .clr_i(clr), .sec_count_o(sc), .ded_count_o(dc), .err_addr_o(ea));
  int e8, e32, e64;
  ecc_code_case #(8) c8 (e8); ecc_code_case #(32) c32 (e32); ecc_code_case #(64) c64 (e64);
  int errors = 0; logic [DW-1:0] m [D]; bit corrupt [D];
  task automatic check(input bit c, input string m_); if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m_); end endtask
  task automatic wr(input int addr, input logic [DW-1:0] d, input logic [CW-1:0] mask);
    @(posedge clk); #1; while (!rdy) begin @(posedge clk); #1; end
    req = 1; we = 1; a = addr; wd = d; inj = mask; @(posedge clk); #1 req = 0; we = 0; inj = 0; m[addr] = d; corrupt[addr] = (mask != 0) && ($countones(mask) > 1);
  endtask
  // read and wait for the response; returns via globals
  logic [DW-1:0] g_d; bit g_sec, g_ded; int g_lat;
  task automatic rdw(input int addr);
    int n; n = 0;
    @(posedge clk); #1; while (!rdy) begin @(posedge clk); #1; end
    req = 1; we = 0; a = addr; @(posedge clk); #1 req = 0;
    while (!rv) begin @(posedge clk); #1; n++; end
    g_d = rd; g_sec = sec; g_ded = ded; g_lat = n;
  endtask
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("ecc_memory_ctrl_tb.vcd"); $dumpvars(0, ecc_memory_ctrl_tb); end
    repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
    for (int i = 0; i < D; i++) wr(i, $urandom, 0);
    for (int i = 0; i < D; i++) begin rdw(i); check(g_d == m[i] && !g_sec && !g_ded, $sformatf("clean read %0d: %h vs %h", i, g_d, m[i])); end
    check(g_lat == 1, $sformatf("read latency %0d (expected response 2 clocks after the request)", g_lat));
    // single-bit memory errors: corrected, flagged, scrubbed
    for (int t = 0; t < 30; t++) begin
      int ad, bit_; ad = $urandom_range(0, D - 1); bit_ = $urandom_range(0, CW - 1);
      wr(ad, $urandom, CW'(1) << bit_);
      rdw(ad); check(g_d == m[ad] && g_sec && !g_ded, $sformatf("single error bit %0d addr %0d: data %h exp %h sec %b ded %b", bit_, ad, g_d, m[ad], g_sec, g_ded));
      check(ea == ad, "error address");
      rdw(ad); check(g_d == m[ad] && !g_sec && !g_ded, $sformatf("scrub failed addr %0d (sec %b)", ad, g_sec));
    end
    check(sc == 30, $sformatf("sec count %0d", sc));
    // double-bit errors
    for (int t = 0; t < 20; t++) begin
      int ad, b1, b2; ad = $urandom_range(0, D - 1); b1 = $urandom_range(0, CW - 1); b2 = (b1 + $urandom_range(1, CW - 1)) % CW;
      wr(ad, $urandom, (CW'(1) << b1) | (CW'(1) << b2));
      rdw(ad); check(g_ded && !g_sec, $sformatf("double error not flagged addr %0d bits %0d,%0d", ad, b1, b2));
    end
    check(dc == 20, $sformatf("ded count %0d", dc));
    // overall parity bit error (bit 0)
    wr(5, 32'hDEADBEEF, CW'(1)); rdw(5); check(g_sec && !g_ded && g_d == 32'hDEADBEEF, "overall parity error");
    // counters clear
    @(posedge clk); #1 clr = 1; @(posedge clk); #1 clr = 0; @(posedge clk); #1; check(sc == 0 && dc == 0, "clear");
    // random traffic
    for (int n = 0; n < 500; n++) begin
      int ad; ad = $urandom_range(0, D - 1);
      if ($urandom_range(0, 1) || corrupt[ad]) wr(ad, $urandom, 0); else begin rdw(ad); check(g_d == m[ad] && !g_ded, "random read"); end
    end
    if (e8 + e32 + e64 != 0) errors += e8 + e32 + e64;
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #50_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
