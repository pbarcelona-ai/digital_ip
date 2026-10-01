// ***************
// Filename: intc_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the interrupt controller IP.
//   Tests level sources, edge sources with write-1-to-clear, active-low
//   polarity, enable masking, software interrupt set and lowest-index
//   priority vector. Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module intc_tb;
  logic aclk = 0, aresetn = 0; always #5 aclk = ~aclk;
  // AXI-Lite wires (names match DUT ports so .* connects the BFM)
  logic [7:0]  s_axil_awaddr, s_axil_araddr; logic s_axil_awvalid, s_axil_awready;
  logic [31:0] s_axil_wdata, s_axil_rdata; logic [3:0] s_axil_wstrb;
  logic s_axil_wvalid, s_axil_wready, s_axil_bvalid, s_axil_bready;
  logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  axil_bfm #(.ADDR_W(8)) bfm (.*);
  logic [15:0] irq_i = 0; logic irq;
  intc_top #(.NUM_IRQ(16)) dut (.aclk, .aresetn,
.s_axil_awaddr, .s_axil_awvalid, .s_axil_awready, .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready, .s_axil_bresp, .s_axil_bvalid, .s_axil_bready, .s_axil_araddr, .s_axil_arvalid, .s_axil_arready, .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .irq_i, .irq_o(irq));
  int errors = 0; logic [31:0] rd;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end
  endtask
  task automatic settle(); repeat (6) @(posedge aclk); endtask
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("intc_tb.vcd"); $dumpvars(0, intc_tb); end
    repeat (4) @(posedge aclk); aresetn = 1; repeat (2) @(posedge aclk);
    // level source 5, enabled
    bfm.write(8'h00, 32'h0FFF);
    irq_i[5] = 1; settle();
    check(irq == 1, "level irq"); bfm.read(8'h14, rd);
    check(rd[31] && rd[4:0] == 5, $sformatf("vector %h", rd));
    irq_i[5] = 0; settle(); check(irq == 0, "level irq should drop with source");
    // priority: sources 9 and 3 -> 3 wins
    irq_i[9] = 1; irq_i[3] = 1; settle();
    bfm.read(8'h14, rd); check(rd[4:0] == 3, "priority lowest index");
    irq_i = 0; settle();
    // edge source 7: pulse latches until cleared
    bfm.write(8'h04, 32'h0080);
    irq_i[7] = 1; settle(); irq_i[7] = 0; settle();
    check(irq == 1, "edge latch should hold"); bfm.read(8'h0C, rd);
    check(rd[7] == 1, "pending bit 7");
    bfm.write(8'h0C, 32'h0080); settle(); check(irq == 0, "W1C edge clear");
    // active-low source 2 (level)
    bfm.write(8'h08, 32'h0004); settle();
    check(irq == 1, "active-low: input low is asserted");
    irq_i[2] = 1; settle(); check(irq == 0, "active-low deasserted when input high");
    irq_i[2] = 0; bfm.write(8'h08, 32'h0000); settle();
    // masking
    irq_i[14] = 1; settle(); check(irq == 0, "source 14 not enabled");
    bfm.write(8'h00, 32'h4000); settle(); check(irq == 1, "enable 14");
    irq_i[14] = 0; bfm.write(8'h00, 32'h0FFF);
    // software interrupt on edge source 7
    settle(); bfm.write(8'h10, 32'h0080); settle();
    check(irq == 1, "software set"); bfm.write(8'h0C, 32'h0080); settle();
    check(irq == 0, "software clear");
    check(bfm.resp_errors == 0, "axi errors");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #2_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
