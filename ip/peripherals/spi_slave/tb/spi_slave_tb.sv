// ***************
// Filename: spi_slave_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for spi_slave. A behavioral SPI
//   master exercises all four modes (CPOL/CPHA) with 8-bit MSB-first
//   words, a 12-bit LSB-first configuration and a 16-bit word, with two or
//   three back-to-back words per chip-select frame; received words,
//   transmitted words (read back over MISO), rx_valid/tx_ready timing,
//   underrun on an empty transmit queue, and the frame error caused by
//   dropping cs_n mid-word are all checked. Prints TEST PASSED on success.
//   The test tasks are in tests/spi_slave_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module spi_case #(parameter int NB = 8, parameter bit CPOL = 0, parameter bit CPHA = 0, parameter bit LSB = 0, parameter int HALF = 6) (input logic clk, input logic rst_n, output int errors, output bit done);
  logic sclk, cs_n, mosi, miso, oe; logic [NB-1:0] txd, rxd; logic txv, txr, rxv, act, fe, ferr, under;
  spi_slave #(.WORD_BITS(NB), .CPOL(CPOL), .CPHA(CPHA), .LSB_FIRST(LSB)) dut (.clk, .rst_n, .sclk_i(sclk), .cs_n_i(cs_n), .mosi_i(mosi), .miso_o(miso), .miso_oe_o(oe),
    .tx_data_i(txd), .tx_valid_i(txv), .tx_ready_o(txr), .rx_data_o(rxd), .rx_valid_o(rxv), .active_o(act), .frame_end_o(fe), .frame_err_o(ferr), .underrun_o(under));
  logic [NB-1:0] rx_log[$]; int frame_errs = 0, unders = 0, taken = 0;
  always @(posedge clk) begin if (rxv) rx_log.push_back(rxd); if (ferr) frame_errs++; if (under) unders++; if (txr) taken++; end
  // slave transmit queue: present the next word whenever available
  logic [NB-1:0] txq[$];
  always @(posedge clk) begin txv <= (txq.size() > 0); if (txq.size() > 0) txd <= txq[0]; if (txr && txq.size() > 0) void'(txq.pop_front()); end
  function automatic logic bit_of(input logic [NB-1:0] w, input int k); return LSB ? w[k] : w[NB-1-k]; endfunction
  // test tasks: tests/spi_slave_tests.sv
  `include "spi_slave_tests.sv"
  logic [NB-1:0] mi, mo [3], st [3];
  initial begin
    errors = 0; done = 0; sclk = CPOL; cs_n = 1; mosi = 0; txv = 0; txd = 0;
    wait (rst_n); repeat (10) @(posedge clk);
    for (int fr = 0; fr < 20; fr++) begin
      int nw; nw = $urandom_range(1, 3);
      rx_log.delete();
      for (int i = 0; i < nw; i++) begin mo[i] = $urandom; st[i] = $urandom; txq.push_back(st[i]); end
      repeat (5) @(posedge clk); cs_n = 0; mosi = 0;
      repeat (8) @(posedge clk);
      for (int i = 0; i < nw; i++) begin
        word(mo[i], mi, i == 0);
        check(mi === st[i], $sformatf("frame %0d word %0d: MISO %h expected %h", fr, i, mi, st[i]));
      end
      repeat (8) @(posedge clk); cs_n = 1; sclk = CPOL; repeat (8) @(posedge clk);
      check(rx_log.size() == nw, $sformatf("frame %0d: %0d words received, expected %0d", fr, rx_log.size(), nw));
      for (int i = 0; i < rx_log.size() && i < nw; i++) check(rx_log[i] === mo[i], $sformatf("frame %0d word %0d: MOSI %h expected %h", fr, i, rx_log[i], mo[i]));
    end
    check(frame_errs == 0, "unexpected frame error");
    // underrun: no tx word offered
    unders = 0; repeat (5) @(posedge clk); cs_n = 0; repeat (8) @(posedge clk);
    word(8'hA5 & {NB{1'b1}}, mi, 1); check(mi === 0, "zeros expected when tx queue empty"); repeat (8) @(posedge clk); cs_n = 1; sclk = CPOL; repeat (8) @(posedge clk);
    check(unders >= 1, "underrun not flagged");
    // frame error: drop cs mid word
    frame_errs = 0; repeat (5) @(posedge clk); cs_n = 0; mosi = 1; repeat (8) @(posedge clk);
    for (int k = 0; k < 3; k++) begin half(); sclk = ~CPOL; half(); sclk = CPOL; end
    repeat (8) @(posedge clk); cs_n = 1; repeat (10) @(posedge clk);
    check(frame_errs == 1, $sformatf("frame error count %0d", frame_errs));
    done = 1;
  end
endmodule
module spi_slave_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  int e0, e1, e2, e3, e4, e5; bit d0, d1, d2, d3, d4, d5;
  spi_case #(8, 0, 0, 0) m0 (clk, rst_n, e0, d0);
  spi_case #(8, 0, 1, 0) m1 (clk, rst_n, e1, d1);
  spi_case #(8, 1, 0, 0) m2 (clk, rst_n, e2, d2);
  spi_case #(8, 1, 1, 0) m3 (clk, rst_n, e3, d3);
  spi_case #(12, 0, 1, 1) m4 (clk, rst_n, e4, d4);
  spi_case #(16, 1, 0, 0, 8) m5 (clk, rst_n, e5, d5);
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("spi_slave_tb.vcd"); $dumpvars(0, spi_slave_tb); end
    repeat (4) @(posedge clk); rst_n = 1;
    wait (d0 && d1 && d2 && d3 && d4 && d5); repeat (5) @(posedge clk);
    if (e0 + e1 + e2 + e3 + e4 + e5 == 0) $display("TEST PASSED"); else $display("TEST FAILED");
    $finish;
  end
  initial begin #50000000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
