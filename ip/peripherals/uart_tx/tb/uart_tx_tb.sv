// ***************
// Filename: uart_tx_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the uart_tx transmitter block.
//   A 1 Mbaud x16 tick generator feeds the transmitter at 100 MHz; the
//   serial line is sampled at bit centres for 8N1, 7E1, 8O2 and 5N1 frames
//   and checked for start bit, LSB-first data, parity, stop bits and back-
//   to-back operation, plus tready flow control and the disabled state.
//   Prints TEST PASSED on success.
//   The test tasks are in tests/uart_tx_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module uart_tx_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  logic tick, en = 1, pe = 0, po = 0, s2 = 0, tv = 0, tr, txd, busy; logic [3:0] nb = 8; logic [7:0] td = 0;
  baud_generator #(.CLK_HZ(100_000_000), .BAUD(1_000_000), .OVERSAMPLE(16)) bg (.clk, .rst_n, .en_i(1'b1), .use_reg_i(1'b0), .inc_i(32'd0), .sync_i(1'b0), .tick_os_o(tick), .tick_baud_o());
  uart_tx dut (.clk, .rst_n, .tick16_i(tick), .en_i(en), .data_bits_i(nb), .parity_en_i(pe), .parity_odd_i(po), .stop2_i(s2), .s_tdata(td), .s_tvalid(tv), .s_tready(tr), .txd_o(txd), .busy_o(busy));
  int errors = 0;
  // test tasks: tests/uart_tx_tests.sv
  `include "uart_tx_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("uart_tx_tb.vcd"); $dumpvars(0, uart_tx_tb); end
    repeat (4) @(posedge clk); rst_n = 1; repeat (20) @(posedge clk); check(txd == 1 && !busy, "idle high");
    send_and_check(8'hA5, 8, 0, 0, 0);
    send_and_check(8'h5A, 7, 1, 0, 0);
    send_and_check(8'hC3, 8, 1, 1, 1);
    send_and_check(8'h15, 5, 0, 0, 0);
    for (int n = 0; n < 8; n++) send_and_check($urandom, $urandom_range(5, 8), $urandom, $urandom, $urandom);
    // disabled: no start bit generated, no ready
    en = 0; @(posedge clk); #1 td = 8'hFF; tv = 1; repeat (300) @(posedge clk); #1 check(txd == 1, "line moved while disabled"); tv = 0; en = 1;
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #50_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
