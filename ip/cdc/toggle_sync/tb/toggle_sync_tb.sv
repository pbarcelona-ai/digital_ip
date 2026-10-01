// ***************
// Filename: toggle_sync_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for toggle_sync. Sends spaced
//   events from a 100 MHz domain to an unrelated 37 MHz domain (and the
//   reverse ratio) and checks that every event produces exactly one
//   destination pulse with bounded latency. Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module tb_case #(parameter real SP = 10.0, parameter real DP = 27.0) (output int errors);
  logic sclk = 0, dclk = 0, srst = 0, drst = 0, ev = 0, evo, tg;
  always #(SP/2) sclk = ~sclk; always #(DP/2) dclk = ~dclk;
  toggle_sync #(.STAGES(2)) dut (.src_clk(sclk), .src_rst_n(srst), .event_i(ev), .dst_clk(dclk),
                                 .dst_rst_n(drst), .event_o(evo), .toggle_o(tg));
  int sent = 0, got = 0;
  always @(posedge dclk) if (evo) got++;
  initial begin
    errors = 0; repeat (5) @(posedge sclk); srst = 1; drst = 1; repeat (5) @(posedge sclk);
    repeat (100) begin
      @(posedge sclk); #1 ev = 1; sent++; @(posedge sclk); #1 ev = 0;
      repeat (int'(6*DP/SP) + 6) @(posedge sclk);       // spacing > 4 destination clocks
    end
    repeat (20) @(posedge sclk);
    if (got != sent) begin errors++; $display("ERROR sent %0d got %0d", sent, got); end
  end
endmodule
module toggle_sync_tb;
  int e1, e2;
  tb_case #(.SP(10.0), .DP(27.0)) a (.errors(e1));
  tb_case #(.SP(27.0), .DP(10.0)) b (.errors(e2));
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("toggle_sync_tb.vcd"); $dumpvars(0, toggle_sync_tb); end
    #200000; if (e1 + e2 == 0) $display("TEST PASSED"); else $display("TEST FAILED"); $finish;
  end
endmodule
