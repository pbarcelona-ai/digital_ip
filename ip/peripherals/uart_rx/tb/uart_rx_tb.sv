// ***************
// Filename: uart_rx_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the uart_rx receiver block. A
//   serial driver sends frames in 8N1, 7E1, 8O1 and 5N1 format at 1 Mbaud
//   (x16 oversampling, 100 MHz), including back-to-back frames, a data
//   glitch on the start bit that must be rejected, a parity error, a
//   framing error (stop bit low) and bit-time skew of plus/minus 3
//   percent; the received data and error flags are compared with what was
//   sent. Prints TEST PASSED on success.
//   The test tasks are in tests/uart_rx_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module uart_rx_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic tick, en = 1, pe = 0, po = 0, rxd, valid, ferr, perr, busy;
  logic [3:0] nb = 8;
  logic [7:0] data;
  baud_generator #(.CLK_HZ(100_000_000), .BAUD(1_000_000), .OVERSAMPLE(16)) bg (
    .clk,
    .rst_n,
    .en_i(1'b1),
    .use_reg_i(1'b0),
    .inc_i(32'd0),
    .sync_i(1'b0),
    .tick_os_o(tick),
    .tick_baud_o()
  );
  uart_rx dut (
    .clk,
    .rst_n,
    .tick16_i(tick),
    .en_i(en),
    .data_bits_i(nb),
    .parity_en_i(pe),
    .parity_odd_i(po),
    .rxd_i(rxd),
    .data_o(data),
    .valid_o(valid),
    .frame_err_o(ferr),
    .parity_err_o(perr),
    .busy_o(busy)
  );
  // UART line partner (transmitter only: the DUT has no transmit output)
  uart_bfm #(.BIT_NS(1000.0)) uart (
    .txd(rxd),
    .rxd(1'b1)
  );
  int errors = 0, nrx = 0;
  logic [7:0] rx_d[$];
  logic rx_f[$], rx_p[$];
  always @(posedge clk) if (valid) begin
    rx_d.push_back(data);
    rx_f.push_back(ferr);
    rx_p.push_back(perr);
  end
  int bt = 100;                                   // clocks per bit
  int exp_n = 0;                                  // frames already checked
  // test tasks: tests/uart_rx_tests.sv
  `include "uart_rx_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("uart_rx_tb.vcd");
      $dumpvars(0, uart_rx_tb);
    end
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (50) @(posedge clk);
    nb = 8;
    pe = 0;
    frame(8'hA5, 8, 0, 0, 0, 0);
    expect_frame(8'hA5, 8, 0, 0);
    nb = 7;
    pe = 1;
    po = 0;
    frame(8'h5A, 7, 1, 0, 0, 0);
    expect_frame(8'h5A, 7, 0, 0);
    nb = 8;
    pe = 1;
    po = 1;
    frame(8'hC3, 8, 1, 1, 0, 0);
    expect_frame(8'hC3, 8, 0, 0);
    nb = 5;
    pe = 0;
    frame(8'h15, 5, 0, 0, 0, 0);
    expect_frame(8'h15, 5, 0, 0);
    // errors
    nb = 8;
    pe = 1;
    po = 0;
    frame(8'h3C, 8, 1, 0, 1, 0);
    expect_frame(8'h3C, 8, 0, 1);
    nb = 8;
    pe = 0;
    frame(8'hF0, 8, 0, 0, 0, 1);
    expect_frame(8'hF0, 8, 1, 0);
    // glitch on the start bit: 2 tick pulse must be rejected
    uart.glitch(12 * 10.0);
    repeat (2000) @(posedge clk);
    check(rx_d.size() == exp_n, "glitch accepted as a frame");
    // back-to-back frames (no idle gap)
    nb = 8;
    pe = 0;
    for (int i = 0; i < 6; i++) frame(8'h10 + i, 8, 0, 0, 0, 0);
    repeat (20) @(posedge clk);
    check(rx_d.size() == exp_n + 6, $sformatf("back-to-back received %0d", rx_d.size() - exp_n));
    for (int i = 0; i < 6 && rx_d.size() >= exp_n + 6; i++) check(rx_d[exp_n + i] == 8'h10 + i, "back-to-back data");
    exp_n = rx_d.size();
    // baud skew +/-3 %
    bt = 97;
    nb = 8;
    frame(8'h96, 8, 0, 0, 0, 0);
    expect_frame(8'h96, 8, 0, 0);
    bt = 103;
    frame(8'h69, 8, 0, 0, 0, 0);
    expect_frame(8'h69, 8, 0, 0);
    bt = 100;
    // random
    for (int n = 0; n < 30; n++) begin
      int b;
      bit p, o;
      logic [7:0] d;
      b = $urandom_range(5, 8);
      p = $urandom;
      o = $urandom;
      d = $urandom;
      nb = b;
      pe = p;
      po = o;
      frame(d, b, p, o, 0, 0);
      expect_frame(d, b, 0, 0);
    end
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #100_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
