// ***************
// Filename: priority_encoder_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for priority_encoder. Exhaustively
//   checks every 8 bit request pattern for both priority directions
//   (combinational) and random 8 bit patterns against the registered
//   variant with one clock latency. Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module priority_encoder_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic [7:0] req = 0;
  logic [2:0] il, ih, ir;
  logic [7:0] ol, oh, orr;
  logic vl, vh, vr;
  priority_encoder #(
    .WIDTH(8),
    .LSB_HIGH(1)
  ) ul (
    .clk,
    .rst_n,
    .req_i(req),
    .idx_o(il),
    .onehot_o(ol),
    .valid_o(vl)
  );
  priority_encoder #(
    .WIDTH(8),
    .LSB_HIGH(0)
  ) uh (
    .clk,
    .rst_n,
    .req_i(req),
    .idx_o(ih),
    .onehot_o(oh),
    .valid_o(vh)
  );
  priority_encoder #(
    .WIDTH(8),
    .REGISTERED(1)
  ) ur (
    .clk,
    .rst_n,
    .req_i(req),
    .idx_o(ir),
    .onehot_o(orr),
    .valid_o(vr)
  );
  int errors = 0;
  logic [7:0] prev_req = 0;
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("priority_encoder_tb.vcd");
      $dumpvars(0, priority_encoder_tb);
    end
    repeat (3) @(posedge clk);
    rst_n = 1;
    for (int r = 0; r < 256; r++) begin
      int lo, hi;
      lo = -1;
      hi = -1;
      for (int i = 0; i < 8; i++) if (r[i]) begin
        if (lo < 0) lo = i;
        hi = i;
      end
      @(posedge clk);
      #1 req = r;
      #1;
      if (vl !== (r != 0) || vh !== (r != 0)) begin
        errors++;
        $display("ERROR valid r=%h", r);
      end
      if (r != 0) begin
        if (il !== lo[2:0] || ol !== (8'd1 << lo)) begin
          errors++;
          $display("ERROR lsb r=%h idx %0d", r, il);
        end
        if (ih !== hi[2:0] || oh !== (8'd1 << hi)) begin
          errors++;
          $display("ERROR msb r=%h idx %0d", r, ih);
        end
      end else if (il !== 0 || ih !== 0 || ol !== 0) begin
        errors++;
        $display("ERROR idle outputs");
      end
      // registered variant shows previous request result
      @(posedge clk);
      #1;
      if (vr !== (r != 0)) begin
        errors++;
        $display("ERROR reg valid r=%h", r);
      end
      if (r != 0 && ir !== lo[2:0]) begin
        errors++;
        $display("ERROR reg idx r=%h", r);
      end
    end
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #500000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
