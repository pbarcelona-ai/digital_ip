// ***************
// Filename: crc32_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for crc32. Checks the standard
//   check value 0xCBF43926 for the string 123456789 fed byte by byte and
//   as 32-bit words with a partial last word, and compares 300 random
//   messages (random length, byte and word feeds) with a bit-serial
//   reference model, including init and mid-stream idle cycles. Prints
//   TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module crc32_tb;
  localparam int W = 32;
  localparam logic [W-1:0] POLY = 32'h04C11DB7, INIT = 32'hFFFFFFFF, XO = 32'hFFFFFFFF;
  localparam bit RI = 1'b1, RO = 1'b1;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  logic init = 0, v8 = 0, v32 = 0; logic [7:0] d8 = 0; logic [31:0] d32 = 0; logic [3:0] k32 = 4'hF; logic [W-1:0] c8, c32;
  crc32 #(.DATA_W(8)) u8 (.clk, .rst_n, .init_i(init), .valid_i(v8), .data_i(d8), .keep_i(1'b1), .crc_o(c8));
  crc32 #(.DATA_W(32)) u32 (.clk, .rst_n, .init_i(init), .valid_i(v32), .data_i(d32), .keep_i(k32), .crc_o(c32));
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
  task automatic feed();
    int n, idx; n = msg.size();
    @(posedge clk); #1 init = 1; @(posedge clk); #1 init = 0;
    for (int i = 0; i < n; i++) begin
      @(posedge clk); #1 v8 = 1; d8 = msg[i];
      if ($urandom_range(0, 5) == 0) begin @(posedge clk); #1 v8 = 0; end       // idle gap
    end
    @(posedge clk); #1 v8 = 0;
    idx = 0;
    while (idx < n) begin
      logic [31:0] w32; logic [3:0] kp; w32 = 0; kp = 0;
      for (int b = 0; b < 4; b++) if (idx + b < n) begin w32[b*8 +: 8] = msg[idx + b]; kp[b] = 1; end
      @(posedge clk); #1 v32 = 1; d32 = w32; k32 = kp; idx += 4;
    end
    @(posedge clk); #1 v32 = 0; @(posedge clk); #1;
  endtask
  logic [W-1:0] exp;
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("crc32_tb.vcd"); $dumpvars(0, crc32_tb); end
    repeat (3) @(posedge clk); rst_n = 1;
    // the 32-bit instance needs its own init: feed() inits both
    msg.delete(); begin string s; s = "123456789"; for (int i = 0; i < s.len(); i++) msg.push_back(s[i]); end
    feed();
    if (c8 !== 32'hCBF43926) begin errors++; $display("ERROR check value 8-bit: %h", c8); end
    if (c32 !== 32'hCBF43926) begin errors++; $display("ERROR check value 32-bit: %h", c32); end
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
