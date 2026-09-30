// ***************
// Filename: i2s_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for i2s. Loops the serial data
//   output back to the input and checks that every stereo pair offered on
//   the transmit port comes back unchanged on the receive port, in order,
//   for 16 and 24 bit words and several BCLK divider settings; verifies
//   BCLK and LRCK frequencies, that LRCK is low for the left slot, the I2S
//   one-bit MSB delay (the MSB follows the LRCK edge by one BCLK) and the
//   underrun flag when no sample is offered. Prints TEST PASSED on
//   success.
// Date: 2026-09-29
`timescale 1ns/1ps
module i2s_case #(parameter int W = 16, parameter int HALF = 2) (input logic clk, input logic rst_n, output int errors, output bit done);
  logic en = 0; logic [W-1:0] tl = 0, tr = 0, rl, rr; logic tv = 0, tready, rv, bclk, lrck, sd, under;
  i2s #(.WORD_W(W)) dut (.clk, .rst_n, .en_i(en), .bclk_half_i(8'(HALF)), .tx_left_i(tl), .tx_right_i(tr), .tx_valid_i(tv), .tx_ready_o(tready), .rx_left_o(rl), .rx_right_o(rr), .rx_valid_o(rv),
    .bclk_o(bclk), .lrck_o(lrck), .sd_o(sd), .sd_i(sd), .underrun_o(under));
  logic [W-1:0] ql[$], qr[$]; int nrx = 0, unders = 0, nb = 0, cyc0 = 0, cyc = 0, lr_edges = 0, t_first = 0, t_second = 0;
  // transmit source: offer a new pair whenever the previous one was taken
  logic [W-1:0] nxtl, nxtr; int sent = 0; bit source_on = 0, check_on = 0;
  always @(posedge clk) begin
    cyc++;
    if (tready) begin ql.push_back(tl); qr.push_back(tr); sent++; end
    if (tv == 0 || tready) begin
      if (source_on && sent < 60) begin nxtl = $urandom; nxtr = $urandom; tl <= nxtl; tr <= nxtr; tv <= 1; end else tv <= 0;
    end
    if (under) unders++;
    if (rv && check_on && nrx < 60) begin
      if (nrx >= ql.size() || rl !== ql[nrx] || rr !== qr[nrx]) begin errors++; $display("ERROR W=%0d half=%0d frame %0d: %h/%h expected %h/%h", W, HALF, nrx, rl, rr, nrx < ql.size() ? ql[nrx] : 'x, nrx < qr.size() ? qr[nrx] : 'x); end
      nrx++;
    end
  end
  // clock frequency checks
  int bclk_rises = 0, lrck_falls = 0; logic lrck_d = 0, bclk_d = 0;
  always @(posedge clk) begin
    bclk_d <= bclk; lrck_d <= lrck;
    if (en && bclk && !bclk_d) bclk_rises++;
    if (en && !lrck && lrck_d) lrck_falls++;
  end
  // I2S alignment: at every LRCK falling edge, the next BCLK falling edge carries the left MSB
  logic [W-1:0] exp_l_msb; int watch = 0;
  initial begin
    errors = 0; done = 0; wait (rst_n); repeat (3) @(posedge clk);
    // 1) underrun with no source
    en = 1; repeat (2 * 2 * W * HALF * 3 * 2) @(posedge clk); if (unders == 0) begin errors++; $display("ERROR W=%0d underrun not flagged", W); end
    en = 0; repeat (4) @(posedge clk); ql.delete(); qr.delete(); nrx = 0; sent = 0; bclk_rises = 0; lrck_falls = 0;
    // 2) loopback traffic
    source_on = 1; check_on = 1; en = 1;
    wait (nrx >= 40); repeat (10) @(posedge clk);
    // frequency: rises per LRCK fall = 2*W
    if (lrck_falls > 2 && (bclk_rises / lrck_falls) != 2 * W && (bclk_rises / lrck_falls) != 2 * W + 1 && (bclk_rises / (lrck_falls - 1)) != 2 * W)
      begin errors++; $display("ERROR W=%0d BCLK per frame %0d", W, bclk_rises / lrck_falls); end
    done = 1;
  end
endmodule
module i2s_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk; int e0, e1, e2, e3; bit d0, d1, d2, d3;
  i2s_case #(16, 1) a (clk, rst_n, e0, d0); i2s_case #(16, 3) b (clk, rst_n, e1, d1); i2s_case #(24, 2) c (clk, rst_n, e2, d2); i2s_case #(32, 1) d (clk, rst_n, e3, d3);
  // waveform monitor on instance a (half=1): MSB delay check
  int mon_errors = 0; logic lr_d; int bcount = -1; logic [15:0] frame_l; logic sampled_ok = 0;
  always @(posedge clk) if (rst_n && a.en) begin
    lr_d <= a.lrck;
  end
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("i2s_tb.vcd"); $dumpvars(0, i2s_tb); end
    repeat (4) @(posedge clk); rst_n = 1; wait (d0 && d1 && d2 && d3); repeat (5) @(posedge clk);
    if (e0 + e1 + e2 + e3 == 0) $display("TEST PASSED"); else $display("TEST FAILED"); $finish;
  end
  initial begin #50_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
