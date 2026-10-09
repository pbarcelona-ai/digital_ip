// ***************
// Filename: lvds_serializer_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for lvds_serializer (4 data lanes
//   and the clock lane). Single link: a word every 14 ns pixel clock,
//   serial clock 2 ns. Dual link: a word every second pixel clock, serial
//   clock 4 ns. (Periods chosen so the 7:1 ratio is exact at the 1 ps
//   simulation resolution, as it is for clocks from one PLL.) Random words are sent; the serial streams are cut
//   into 7-bit words aligned on the clock lane pattern 1100011 (bit 6
//   first) and every recovered word must equal the one sent, in order.
//   Prints TEST PASSED on success.
//   The test tasks are in tests/lvds_serializer_tests.sv (`included).
// Date: 2026-10-02
`timescale 1ns/1ps
module lvds_serializer_tb;
  int errors = 0;

  realtime ser_half = 1.0;
  logic pix_clk = 0, ser_clk = 0, prst_n = 0, srst_n = 0, dual = 0;
  always #7 pix_clk = ~pix_clk;
  initial begin
    #0.3;
    forever #(ser_half) ser_clk = ~ser_clk;
  end

  logic [34:0] words;
  logic stb;
  logic [4:0] ser;
  lvds_serializer #(.NL(5)) dut (
    .pix_clk,
    .pix_rst_n(prst_n),
    .words_i(words),
    .stb_i(stb),
    .ser_clk,
    .ser_rst_n(srst_n),
    .serial_o(ser)
  );

  localparam int NS = 300;
  logic [27:0] sent [NS];
  int nsent;
  bit ph;
  always @(posedge pix_clk) if (prst_n) begin
    logic [27:0] d;
    ph = dual ? ~ph : 1'b1;
    stb <= ph;
    if (ph) begin
      d = 28'($urandom);
      words <= {7'b1100011, d};
      if (nsent < NS) sent[nsent] = d;
      nsent++;
    end
  end

  // LVDS receiver: aligns on the clock lane and recovers the 28-bit words
  lvds_bfm #(.NDATA(4)) rx (
    .ser_clk,
    .lanes(ser)
  );
  initial rx.decode = 0;

  // test tasks: tests/lvds_serializer_tests.sv
  `include "lvds_serializer_tests.sv"

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("lvds_serializer_tb.vcd");
      $dumpvars(0, lvds_serializer_tb);
    end
    run(0);
    run(1);
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
