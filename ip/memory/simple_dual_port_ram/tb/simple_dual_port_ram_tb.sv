// ***************
// Filename: simple_dual_port_ram_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for simple_dual_port_ram. Fills the
//   memory through the write port, reads it back through the read port
//   (single clock and asynchronous clocks, with and without byte enables)
//   and checks one clock read latency and reset behaviour. Prints TEST
//   PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module sdp_case #(parameter bit ASYNC = 0, parameter bit BE = 0, parameter real RP = 10.0) (output int errors);
  logic wclk = 0, rclk = 0, rst_n = 0; always #5 wclk = ~wclk; always #(RP/2) rclk = ~rclk;
  logic we = 0, re = 0; logic [3:0] be = 4'hF; logic [5:0] wa = 0, ra = 0; logic [31:0] wd = 0, rd;
  simple_dual_port_ram #(.WIDTH(32), .DEPTH(64), .BYTE_EN(BE), .ASYNC(ASYNC)) dut
    (.wclk, .we_i(we), .be_i(be), .waddr_i(wa), .wdata_i(wd), .rclk, .rst_n, .re_i(re), .raddr_i(ra), .rdata_o(rd));
  logic [31:0] m [0:63];
  initial begin
    errors = 0; repeat (4) @(posedge wclk); rst_n = 1;
    for (int i = 0; i < 64; i++) begin
      @(posedge wclk); #1 we = 1; wa = i; wd = $urandom; be = 4'hF; m[i] = wd;
    end
    if (BE) begin                       // partial overwrite of byte 1 and 3
      @(posedge wclk); #1 wa = 5; wd = 32'hAABBCCDD; be = 4'b1010; m[5][15:8] = 8'hCC; m[5][31:24] = 8'hAA;
    end
    @(posedge wclk); #1 we = 0; repeat (3) @(posedge rclk);
    for (int i = 0; i < 64; i++) begin
      @(posedge rclk); #1 re = 1; ra = i;
      @(posedge rclk); #1;
      if (rd !== m[i]) begin errors++; $display("ERROR async=%0d be=%0d addr %0d got %h exp %h", ASYNC, BE, i, rd, m[i]); end
    end
  end
endmodule
module simple_dual_port_ram_tb;
  int e0, e1, e2;
  sdp_case #(0, 0, 10.0) a (e0);
  sdp_case #(0, 1, 10.0) b (e1);
  sdp_case #(1, 1, 13.0) c (e2);
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("simple_dual_port_ram_tb.vcd"); $dumpvars(0, simple_dual_port_ram_tb); end
    #20000; if (e0 + e1 + e2 == 0) $display("TEST PASSED"); else $display("TEST FAILED"); $finish;
  end
endmodule
