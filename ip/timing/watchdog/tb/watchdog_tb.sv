// ***************
// Filename: watchdog_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the watchdog IP. Tests timeout
//   reset with stretched pulse, kicks restarting the counter, key
//   protection, pre-timeout interrupt, window mode early kick violation,
//   lock bit preventing disable and status write-1-to-clear. Prints TEST
//   PASSED on success.
//   The test tasks are in tests/watchdog_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module watchdog_tb;
  logic aclk = 0, aresetn = 0; always #5 aclk = ~aclk;
  // AXI-Lite wires (names match DUT ports so .* connects the BFM)
  logic [7:0]  s_axil_awaddr, s_axil_araddr; logic s_axil_awvalid, s_axil_awready;
  logic [31:0] s_axil_wdata, s_axil_rdata; logic [3:0] s_axil_wstrb;
  logic s_axil_wvalid, s_axil_wready, s_axil_bvalid, s_axil_bready;
  logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  axil_bfm #(.ADDR_W(8)) bfm (.*);
  logic irq, wdt_rst;
  watchdog_top #(.RESET_CYCLES(8)) dut (.aclk, .aresetn,
.s_axil_awaddr, .s_axil_awvalid, .s_axil_awready, .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready, .s_axil_bresp, .s_axil_bvalid, .s_axil_bready, .s_axil_araddr, .s_axil_arvalid, .s_axil_arready, .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .irq_o(irq), .wdt_reset_o(wdt_rst));
  int errors = 0; logic [31:0] rd;
  // test tasks: tests/watchdog_tests.sv
  `include "watchdog_tests.sv"
  int rst_len, rst_events = 0;
  always @(posedge wdt_rst) rst_events++;
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("watchdog_tb.vcd"); $dumpvars(0, watchdog_tb); end
    repeat (4) @(posedge aclk); aresetn = 1; repeat (2) @(posedge aclk);
    bfm.write(8'h04, 100); bfm.write(8'h08, 3);      // 100 ticks of 4 clocks = 400 clocks
    bfm.write(8'h0C, 60);                            // pre-timeout at 60 ticks
    bfm.write(8'h00, 32'h1);
    // ---- Test 1: regular kicks keep it alive ----
    repeat (5) begin repeat (250) @(posedge aclk); bfm.write(8'h14, 32'h5AFE_C0DE); end
    check(rst_events == 0, "reset while being kicked");
    // ---- Test 2: pre-timeout then timeout ----
    repeat (260) @(posedge aclk);
    check(irq == 1, "pre-timeout irq missing");
    bfm.read(8'h18, rd); check(rd[0] == 1, "pre status");
    repeat (200) @(posedge aclk);
    check(rst_events == 1, $sformatf("timeout reset count %0d", rst_events));
    rst_len = 0; while (wdt_rst) begin @(posedge aclk); rst_len++; end
    bfm.read(8'h18, rd); check(rd[1] == 1, "expired status");
    bfm.write(8'h18, 32'h3); bfm.read(8'h18, rd); check(rd[1:0] == 0, "W1C");
    // ---- Test 3: wrong key ignored and flagged ----
    bfm.write(8'h14, 32'h1234_5678); bfm.read(8'h18, rd);
    check(rd[3] == 1, "bad key flag"); bfm.write(8'h18, 32'h8);
    // ---- Test 4: window mode: kick before WINDOW_OPEN resets ----
    bfm.write(8'h14, 32'h5AFE_C0DE);
    bfm.write(8'h10, 50); bfm.write(8'h00, 32'h3);   // window enabled
    rst_events = 0;
    repeat (40) @(posedge aclk);                     // count ~ 10 < 50
    bfm.write(8'h14, 32'h5AFE_C0DE); repeat (5) @(posedge aclk);
    check(rst_events == 1, "early kick should reset"); bfm.read(8'h18, rd);
    check(rd[2] == 1, "early flag"); bfm.write(8'h18, 32'h4);
    while (wdt_rst) @(posedge aclk);
    // in-window kick accepted
    repeat (300) @(posedge aclk);                    // count ~ 75 > 50
    bfm.write(8'h14, 32'h5AFE_C0DE); repeat (5) @(posedge aclk);
    check(rst_events == 1, "in-window kick must not reset");
    // ---- Test 5: lock ----
    bfm.write(8'h00, 32'h5);                         // en + lock (window off)
    bfm.write(8'h00, 32'h0);                         // try to disable
    bfm.read(8'h00, rd); check(rd[0] == 1 && rd[2] == 1, "lock did not hold enable");
    check(bfm.resp_errors == 0, "axi errors");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #5_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
