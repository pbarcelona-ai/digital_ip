// ***************
// Filename: watchdog_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the watchdog IP. Tests timeout
//   reset with stretched pulse, kicks restarting the counter, key
//   protection, pre-timeout interrupt, window mode early kick violation,
//   lock bit preventing disable and status write-1-to-clear. Prints TEST
//   PASSED on success. The DUT is watchdog_top (register map watchdog_regs:
//   ID "WDOG", VERSION, DATE at 0x00-0x08, the registers from 0x10).
//   The test tasks are in tests/watchdog_tests.sv (`included).
// Date: 2026-10-12
`timescale 1ns/1ps
module watchdog_tb;
  logic aclk = 0, aresetn = 0;
  always #5 aclk = ~aclk;
  // AXI-Lite wires (names match DUT ports so .* connects the BFM)
  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  axil_bfm #(.ADDR_W(8)) bfm (
    .*
  );
  logic irq, wdt_rst;
  watchdog_top #(.RESET_CYCLES(8)) dut (
    .aclk,
    .aresetn,
    .s_axil(s_axil),
    .irq_o(irq),
    .wdt_reset_o(wdt_rst)
  );
  int errors = 0;
  logic [31:0] rd;
  // test tasks: tests/watchdog_tests.sv
  int rst_len, rst_events = 0;
  always @(posedge wdt_rst) rst_events++;
  `include "watchdog_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("watchdog_tb.vcd");
      $dumpvars(0, watchdog_tb);
    end
    repeat (4) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);
    bfm.base = 'h10;                                 // the map after the ID block
    test_id_block();
    test_setup();
    test_kicks();
    test_timeout();
    test_bad_key();
    test_window();
    test_lock();

    check(bfm.resp_errors == 0, "axi errors");
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #5_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
