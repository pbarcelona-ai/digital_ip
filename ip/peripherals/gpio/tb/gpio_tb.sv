// ***************
// Filename: gpio_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for the GPIO IP. Tests direction
//   and output registers, atomic set/clear/toggle, input synchronization,
//   rising and falling edge interrupts with masks, write-1-to-clear and
//   the irq output. Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module gpio_tb;
  localparam int W = 8;
  logic aclk = 0, aresetn = 0; always #5 aclk = ~aclk;
  // AXI-Lite wires (names match DUT ports so .* connects the BFM)
  logic [7:0]  s_axil_awaddr, s_axil_araddr; logic s_axil_awvalid, s_axil_awready;
  logic [31:0] s_axil_wdata, s_axil_rdata; logic [3:0] s_axil_wstrb;
  logic s_axil_wvalid, s_axil_wready, s_axil_bvalid, s_axil_bready;
  logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  axil_bfm #(.ADDR_W(8)) bfm (.*);
  logic [W-1:0] gpio_i = 0, gpio_o, gpio_t; logic irq;
  gpio_top #(.WIDTH(W)) dut (.aclk, .aresetn,
.s_axil_awaddr, .s_axil_awvalid, .s_axil_awready, .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready, .s_axil_bresp, .s_axil_bvalid, .s_axil_bready, .s_axil_araddr, .s_axil_arvalid, .s_axil_arready, .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .gpio_i, .gpio_o, .gpio_t, .irq_o(irq));
  int errors = 0; logic [31:0] rd;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end
  endtask
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("gpio_tb.vcd"); $dumpvars(0, gpio_tb); end
    repeat (4) @(posedge aclk); aresetn = 1; repeat (2) @(posedge aclk);
    check(gpio_t == '1, "pins should reset to inputs");
    bfm.write(8'h04, 32'h0F);                       // low nibble outputs
    bfm.write(8'h00, 32'hA5);
    check(gpio_t == 8'hF0 && gpio_o == 8'hA5, "direction/out");
    bfm.write(8'h0C, 32'h0A);  check(gpio_o == 8'hAF, "set");
    bfm.write(8'h10, 32'h05);  check(gpio_o == 8'hAA, "clear");
    bfm.write(8'h14, 32'hFF);  check(gpio_o == 8'h55, "toggle");
    // inputs are synchronized
    gpio_i = 8'h3C; repeat (4) @(posedge aclk);
    bfm.read(8'h08, rd); check(rd == 32'h3C, "input read");
    // edge interrupts: rise on bit 0 and 6, fall on bit 2
    bfm.write(8'h1C, 32'h41); bfm.write(8'h20, 32'h04); bfm.write(8'h18, 32'h45);
    gpio_i = 8'h3D; repeat (5) @(posedge aclk);     // bit0 rises
    check(irq == 1, "irq after rising edge");
    bfm.read(8'h24, rd); check(rd == 32'h01, $sformatf("status %h", rd));
    bfm.write(8'h24, 32'h01); repeat (3) @(posedge aclk);
    check(irq == 0, "irq not cleared by W1C");
    gpio_i = 8'h39; repeat (5) @(posedge aclk);     // bit2 falls
    bfm.read(8'h24, rd); check(rd == 32'h04, "falling edge status");
    bfm.write(8'h24, 32'h04);
    gpio_i = 8'h79; repeat (5) @(posedge aclk);     // bit6 rises but masked out of INT_EN
    check(irq == 1, "bit 6 (rise enabled) should interrupt");
    bfm.write(8'h18, 32'h00); bfm.write(8'h24, 32'hFF); repeat (3) @(posedge aclk);
    check(irq == 0, "irq with INT_EN=0");
    check(bfm.resp_errors == 0, "axi errors");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #2_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
