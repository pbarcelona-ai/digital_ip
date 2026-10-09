// ***************
// Filename: crc16_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for crc16. Checks the standard
//   check value 0x29B1 for the string 123456789 fed byte by byte and as
//   32-bit words with a partial last word, and compares 300 random
//   messages (random length, byte and word feeds) with a bit-serial
//   reference model, including init and mid-stream idle cycles. Prints
//   TEST PASSED on success.
//   The test tasks are in tests/crc16_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module crc16_tb;
  localparam int W = 16;
  localparam logic [W-1:0] POLY = 16'h1021, INIT = 16'hFFFF, XO = 16'h0000;
  localparam bit RI = 1'b0, RO = 1'b0;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  logic init = 0, v8 = 0, v32 = 0; logic [7:0] d8 = 0; logic [31:0] d32 = 0; logic [3:0] k32 = 4'hF; logic [W-1:0] c8, c32;
  crc16 #(.DATA_W(8)) u8 (.clk, .rst_n, .init_i(init), .valid_i(v8), .data_i(d8), .keep_i(1'b1), .crc_o(c8));
  crc16 #(.DATA_W(32)) u32 (.clk, .rst_n, .init_i(init), .valid_i(v32), .data_i(d32), .keep_i(k32), .crc_o(c32));
  int errors = 0; byte msg[$];
  function automatic logic [W-1:0] model();
    logic [W-1:0] r, out; logic [7:0] b; logic fb;
    r = INIT;
    for (int k = 0; k < msg.size(); k++) begin
      b = msg[k];
      for (int i = 0; i < 8; i++) begin
        fb = r[W-1] ^ (RI ? b[i] : b[7-i]);
        r = {r[W-2:0], 1'b0}; if (fb) r = r ^ POLY;
      end
    end
    for (int i = 0; i < W; i++) out[i] = RO ? r[W-1-i] : r[i];
    return out ^ XO;
  endfunction
  // test tasks: tests/crc16_tests.sv
  `include "crc16_tests.sv"
  logic [W-1:0] exp;
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("crc16_tb.vcd"); $dumpvars(0, crc16_tb); end
    repeat (3) @(posedge clk); rst_n = 1;
    // the 32-bit instance needs its own init: feed() inits both
    msg.delete(); begin string s; s = "123456789"; for (int i = 0; i < s.len(); i++) msg.push_back(s[i]); end
    feed();
    if (c8 !== 16'h29B1) begin errors++; $display("ERROR check value 8-bit: %h", c8); end
    if (c32 !== 16'h29B1) begin errors++; $display("ERROR check value 32-bit: %h", c32); end
    for (int n = 0; n < 300; n++) begin
      msg.delete(); for (int i = 0; i < $urandom_range(1, 40); i++) msg.push_back($urandom);
      feed(); exp = model();
      if (c8 !== exp || c32 !== exp) begin errors++; $display("ERROR msg %0d len %0d: %h %h exp %h", n, msg.size(), c8, c32, exp); end
    end
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #50000000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
