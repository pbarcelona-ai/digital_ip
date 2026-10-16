// ***************
// Filename: gpio_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the GPIO IP. Tests direction
//   and output registers, atomic set/clear/toggle, input synchronization,
//   rising and falling edge interrupts with masks, write-1-to-clear and
//   the irq output, and the ID block (ID "GPIO", VERSION, DATE at 0x00-0x08;
//   the register map from 0x10: bfm.base). Prints TEST PASSED on success.
//   The DUT is gpio_top (register map gpio_regs + logic gpio).
//   The test tasks are in tests/gpio_tests.sv (`included).
// Date: 2026-10-12
`timescale 1ns/1ps
module gpio_tb;
  localparam int W = 8;
  logic aclk = 0, aresetn = 0;
  always #5 aclk = ~aclk;
  // AXI-Lite wires (names match DUT ports so .* connects the BFM)
  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  axil_bfm #(.ADDR_W(8)) bfm (
    .*
  );
  logic [W-1:0] gpio_i = 0, gpio_o, gpio_t;
  logic irq;
  gpio_top #(.WIDTH(W)) dut (
    .aclk,
    .aresetn,
    .s_axil(s_axil),
    .gpio_i,
    .gpio_o,
    .gpio_t,
    .irq_o(irq)
  );
  int errors = 0;
  logic [31:0] rd;
  // test tasks: tests/gpio_tests.sv
  `include "gpio_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("gpio_tb.vcd");
      $dumpvars(0, gpio_tb);
    end
    repeat (4) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);
    bfm.base = 'h10;                                 // the map after the ID block
    test_id_block();
    test_reset();
    test_output();
    test_input();
    test_edge_irq();
    test_ro_write();
    check(bfm.resp_errors == 0, "axi errors");
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #2_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
