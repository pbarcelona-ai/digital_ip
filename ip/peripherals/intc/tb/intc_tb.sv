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
  logic [7:0]  s_axil_awaddr, s_axil_araddr;
  logic s_axil_awvalid, s_axil_awready;
  logic [31:0] s_axil_wdata, s_axil_rdata;
  logic [3:0] s_axil_wstrb;
  logic s_axil_wvalid, s_axil_wready, s_axil_bvalid, s_axil_bready;
  logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  axil_bfm #(.ADDR_W(8)) bfm (.*);
  logic [15:0] irq_i = 0;
  logic irq;
  intc_top #(.NUM_IRQ(16)) dut (
    .aclk,
    .aresetn,
    .s_axil_awaddr,
    .s_axil_awvalid,
    .s_axil_awready,
    .s_axil_wdata,
    .s_axil_wstrb,
    .s_axil_wvalid,
    .s_axil_wready,
    .s_axil_bresp,
    .s_axil_bvalid,
    .s_axil_bready,
    .s_axil_araddr,
    .s_axil_arvalid,
    .s_axil_arready,
    .s_axil_rdata,
    .s_axil_rresp,
    .s_axil_rvalid,
    .s_axil_rready,
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
