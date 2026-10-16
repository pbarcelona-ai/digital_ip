// ***************
// Filename: intc_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the interrupt controller IP.
//   Tests level sources, edge sources with write-1-to-clear, active-low
//   polarity, enable masking, software interrupt set and lowest-index
//   priority vector. Prints TEST PASSED on success.
//   The test tasks are in tests/intc_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module intc_tb;
  logic aclk = 0, aresetn = 0;
  always #5 aclk = ~aclk;
  // AXI-Lite wires (names match DUT ports so .* connects the BFM)
  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  axil_bfm #(.ADDR_W(8)) bfm (
    .*
  );
  logic [15:0] irq_i = 0;
  logic irq;
  intc_top #(.NUM_IRQ(16)) dut (
    .aclk,
    .aresetn,
    .s_axil(s_axil),
    .irq_i,
    .irq_o(irq)
  );
  int errors = 0;
  logic [31:0] rd;
  // test tasks: tests/intc_tests.sv
  `include "intc_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("intc_tb.vcd");
      $dumpvars(0, intc_tb);
    end
    repeat (4) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);
    bfm.base = 'h10;                                 // the map after the ID block
    test_id_block();
    test_level();
    test_priority();
    test_edge();
    test_active_low();
    test_mask();
    test_soft_set();

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
