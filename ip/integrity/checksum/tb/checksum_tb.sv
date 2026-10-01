// ***************
// Filename: checksum_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for checksum. Verifies the RFC 1071
//   example (sum 0xddf2, checksum 0x220d), an odd-length Internet
//   checksum, Fletcher-16 of abcde (0xC8F0) and abcdef (0x2057), the 8-bit
//   sum, the ok_o self-verification flag for each mode (message plus its
//   own checksum), and 300 random messages against a behavioral model.
//   Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module cs_case #(parameter int MODE = 1) (input logic clk, input logic rst_n, output int errors, output bit ready);
  logic init = 0, v = 0; logic [7:0] b = 0; logic [15:0] c; logic ok;
  checksum #(.MODE(MODE)) dut (.clk, .rst_n, .init_i(init), .valid_i(v), .byte_i(b), .checksum_o(c), .ok_o(ok));
  byte msg[$];
  task automatic run();
    @(posedge clk); #1 init = 1; @(posedge clk); #1 init = 0;
    for (int i = 0; i < msg.size(); i++) begin @(posedge clk); #1 v = 1; b = msg[i]; end
    @(posedge clk); #1 v = 0; @(posedge clk); #1;
  endtask
  function automatic logic [15:0] model();
    int s; int f1, f2; int hi;
    s = 0; f1 = 0; f2 = 0;
    for (int i = 0; i < msg.size(); i++) begin
      s += (int'(msg[i]) & 255); f1 = (f1 + (int'(msg[i]) & 255)) % 255; f2 = (f2 + f1) % 255;
    end
    if (MODE == 0) return 16'((-s) & 255);
    if (MODE == 2) return {f2[7:0], f1[7:0]};
    s = 0;
    for (int i = 0; i < msg.size(); i += 2) s += ((int'(msg[i]) & 255) << 8) + ((i + 1 < msg.size()) ? (int'(msg[i+1]) & 255) : 0);
    while (s >> 16) s = (s & 16'hFFFF) + (s >> 16);
    return 16'(~s);
  endfunction
  task automatic check(input bit c_, input string m); if (!c_) begin errors++; $display("ERROR mode %0d: %s", MODE, m); end endtask
  initial begin
    errors = 0; ready = 0; wait (rst_n); repeat (2) @(posedge clk);
    if (MODE == 1) begin
      msg = '{8'h00, 8'h01, 8'hf2, 8'h03, 8'hf4, 8'hf5, 8'hf6, 8'hf7}; run(); check(c == 16'h220d, $sformatf("RFC1071 example %h", c));
      msg = '{8'h45, 8'h00, 8'h00, 8'h73, 8'h00, 8'h00, 8'h40, 8'h00, 8'h40, 8'h11, 8'h00, 8'h00, 8'hc0, 8'ha8, 8'h00, 8'h01, 8'hc0, 8'ha8, 8'h00, 8'hc7};
      run(); check(c == 16'hb861, $sformatf("IPv4 header example %h", c));
    end
    if (MODE == 2) begin
      msg = '{"a","b","c","d","e"}; run(); check(c == 16'hC8F0, $sformatf("abcde %h", c));
      msg = '{"a","b","c","d","e","f"}; run(); check(c == 16'h2057, $sformatf("abcdef %h", c));
    end
    if (MODE == 0) begin msg = '{8'h01, 8'h02, 8'h03}; run(); check(c == 16'h00FA, $sformatf("sum8 %h", c)); end
    for (int n = 0; n < 300; n++) begin
      msg.delete(); for (int i = 0; i < $urandom_range(1, 33); i++) msg.push_back($urandom);
      run(); check(c === model(), $sformatf("random msg %0d len %0d: %h exp %h", n, msg.size(), c, model()));
      // self verification: append the checksum
      begin logic [15:0] cs; cs = c;
        if (MODE == 0) msg.push_back(cs[7:0]);
        else if (MODE == 1) begin if (msg.size() % 2) msg.push_back(8'h00); msg.push_back(cs[15:8]); msg.push_back(cs[7:0]); end
        else begin msg.push_back(cs[15:8]); msg.push_back(cs[7:0]); end
        if (MODE != 2) begin run(); check(ok, $sformatf("ok_o after appending checksum (len %0d)", msg.size())); end
      end
    end
    ready = 1;
  end
endmodule
module checksum_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk; int e0, e1, e2; bit r0, r1, r2;
  cs_case #(0) a (clk, rst_n, e0, r0); cs_case #(1) b (clk, rst_n, e1, r1); cs_case #(2) c (clk, rst_n, e2, r2);
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("checksum_tb.vcd"); $dumpvars(0, checksum_tb); end
    repeat (3) @(posedge clk); rst_n = 1; wait (r0 && r1 && r2); #20;
    if (e0 + e1 + e2 == 0) $display("TEST PASSED"); else $display("TEST FAILED"); $finish;
  end
  initial begin #100000000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
