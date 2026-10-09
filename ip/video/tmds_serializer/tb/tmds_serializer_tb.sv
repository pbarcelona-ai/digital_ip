// ***************
// Filename: tmds_serializer_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for tmds_serializer. Pixel clock
//   10 ns, serial clock 1 ns, with the serial clock shifted by three
//   different amounts between runs. Random symbols are sent on the three channels; the serial
//   streams are cut into 10-bit words aligned on the clock channel pattern
//   (0000011111, sent LSB first) and every recovered symbol must equal the
//   one sent, in order. Prints TEST PASSED on success.
//   The test tasks are in tests/tmds_serializer_tests.sv (`included).
// Date: 2026-10-01
`timescale 1ns/1ps
module tmds_serializer_tb;
  int errors = 0;

  real shift_req = 0.0;                          // extra delay inserted once: moves the serial phase
  logic pix_clk = 0, ser_clk = 0, prst_n = 0, srst_n = 0;
  always #5 pix_clk = ~pix_clk;
  initial forever begin
    if (shift_req > 0.0) begin #(shift_req); shift_req = 0.0; end
    #0.5 ser_clk = ~ser_clk;
  end

  logic [9:0] s0, s1, s2; logic [3:0] ser;
  tmds_serializer dut (.pix_clk, .pix_rst_n(prst_n), .tmds0_i(s0), .tmds1_i(s1), .tmds2_i(s2), .tmds_clk_i(10'b0000011111),
    .ser_clk, .ser_rst_n(srst_n), .serial_o(ser));

  // Sent symbols
  localparam int NS = 400;
  logic [29:0] sent [NS]; int nsent = 0;
  always @(posedge pix_clk) if (prst_n) begin
    logic [29:0] v; v = {10'($urandom), 10'($urandom), 10'($urandom)};
    s0 <= v[9:0]; s1 <= v[19:10]; s2 <= v[29:20];
    if (nsent < NS) sent[nsent] = v;
    nsent++;
  end

  // Serial capture
  logic [3:0] bits [NS*10 + 200]; int nb = 0;
  always @(posedge ser_clk) if (srst_n) begin bits[nb] = ser; nb++; end

  // test tasks: tests/tmds_serializer_tests.sv
  `include "tmds_serializer_tests.sv"

  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("tmds_serializer_tb.vcd"); $dumpvars(0, tmds_serializer_tb); end
    run(0.0);
    run(0.3);
    run(0.77);
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
