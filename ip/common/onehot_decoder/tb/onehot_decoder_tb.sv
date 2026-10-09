// ***************
// Filename: onehot_decoder_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for onehot_decoder. Checks every
//   select value with enable on and off for a non power-of-two width (6,
//   so selects 6 and 7 are out of range) in combinational and registered
//   form. Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module onehot_decoder_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic en = 0;
  logic [2:0] sel = 0;
  logic [5:0] oc, orr;
  logic ec, er;
  onehot_decoder #(.WIDTH(6)) uc (
    .clk,
    .rst_n,
    .en_i(en),
    .sel_i(sel),
    .onehot_o(oc),
    .err_o(ec)
  );
  onehot_decoder #(.WIDTH(6), .REGISTERED(1)) ur (
    .clk,
    .rst_n,
    .en_i(en),
    .sel_i(sel),
    .onehot_o(orr),
    .err_o(er)
  );
  int errors = 0;
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("onehot_decoder_tb.vcd");
      $dumpvars(0, onehot_decoder_tb);
    end
    repeat (3) @(posedge clk);
    rst_n = 1;
    for (int e = 0; e < 2; e++) for (int s = 0; s < 8; s++) begin
      @(posedge clk);
      #1 en = e;
      sel = s;
      #1;
      if (oc !== ((e && s < 6) ? 6'd1 << s : 6'd0) || ec !== (e && s >= 6)) begin
        errors++;
        $display("ERROR comb en=%0d sel=%0d oc=%b ec=%b", e, s, oc, ec);
      end
      @(posedge clk);
      #1;
      if (orr !== oc || er !== ec) begin
        errors++;
        $display("ERROR registered en=%0d sel=%0d", e, s);
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
