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
// Date: 2026-10-02
`timescale 1ns/1ps
module lvds_serializer_tb;
  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  realtime ser_half = 1.0;
  logic pix_clk = 0, ser_clk = 0, prst_n = 0, srst_n = 0, dual = 0;
  always #7 pix_clk = ~pix_clk;
  initial begin #0.3; forever #(ser_half) ser_clk = ~ser_clk; end

  logic [34:0] words; logic stb; logic [4:0] ser;
  lvds_serializer #(.NL(5)) dut (.pix_clk, .pix_rst_n(prst_n), .words_i(words), .stb_i(stb), .ser_clk, .ser_rst_n(srst_n), .serial_o(ser));

  localparam int NS = 300;
  logic [27:0] sent [NS]; int nsent; bit ph;
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

  logic [4:0] bits [NS * 7 + 400]; int nb;
  always @(posedge ser_clk) if (srst_n) begin bits[nb] = ser; nb++; end

  task automatic run(input bit d2);
    int off, first, k0, matched;
    dual = d2; ser_half = d2 ? 2.0 : 1.0;
    nsent = 0; nb = 0; ph = 0; prst_n = 0; srst_n = 0; stb = 0; words = '0;
    #100; prst_n = 1; srst_n = 1;
    #(NS * (d2 ? 28 : 14) - 400);
    off = -1;
    for (int i = 0; i < 60 && off < 0; i++) begin
      logic [6:0] w; for (int b = 0; b < 7; b++) w[6 - b] = bits[i + b][4];
      if (w == 7'b1100011 && bits[i + 7][4] == 1'b1 && bits[i + 6][4] == 1'b1) off = i;
    end
    check(off >= 0, "clock pattern not found");
    first = -1; matched = 0;
    for (int k = 0; off >= 0 && k < (nb - off) / 7 - 1; k++) begin
      logic [27:0] w; logic [6:0] c;
      for (int b = 0; b < 7; b++) begin
        for (int l = 0; l < 4; l++) w[7*l + 6 - b] = bits[off + 7*k + b][l];
        c[6 - b] = bits[off + 7*k + b][4];
      end
      check(c == 7'b1100011, $sformatf("clock word %0d = %b", k, c));
      if (first < 0) begin for (int j = 0; j < 10; j++) if (sent[j] == w) begin first = j; k0 = k; end end
      else if (first + (k - k0) < NS) begin
        check(w == sent[first + (k - k0)], $sformatf("%s word %0d = %h exp %h", d2 ? "dual" : "single", first + (k - k0), w, sent[first + (k - k0)]));
        matched++;
      end
    end
    check(matched > NS - 40, $sformatf("only %0d words compared", matched));
    $display("%s link rate: %0d words recovered in order on 4 lanes", d2 ? "dual" : "single", matched);
  endtask

  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("lvds_serializer_tb.vcd"); $dumpvars(0, lvds_serializer_tb); end
    run(0);
    run(1);
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
