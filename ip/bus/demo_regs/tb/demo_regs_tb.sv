// ***************
// Filename: demo_regs_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for demo_regs, the register block
//   produced by scripts/regmap_gen.py from examples/regmap/demo_regs.json.
//   Verifies reset values, RW read/write with byte strobes, RO reads of
//   the hardware input and error response on write, W1C set by hardware
//   and cleared by software, W1S set by software and cleared by hardware,
//   the per-register write pulses and the error response for an address
//   beyond the map. Prints TEST PASSED on success.
//   The test tasks are in tests/demo_regs_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module demo_regs_tb;
  logic aclk = 0, aresetn = 0; always #5 aclk = ~aclk;
  logic [4:0]  s_axil_awaddr, s_axil_araddr; logic s_axil_awvalid, s_axil_awready; logic [31:0] s_axil_wdata, s_axil_rdata; logic [3:0] s_axil_wstrb;
  logic s_axil_wvalid, s_axil_wready, s_axil_bvalid, s_axil_bready; logic [1:0] s_axil_bresp, s_axil_rresp; logic s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  axil_bfm #(.ADDR_W(5)) bfm (.*);
  logic [31:0] id_i = 32'hC0DE_0001, count_i = 32'd0, status_set_i = 0, trig_clr_i = 0; logic [31:0] ctrl_o, status_o, thresh_o, trig_o;
  logic id_wr_o, ctrl_wr_o, status_wr_o, thresh_wr_o, count_wr_o, trig_wr_o;
  demo_regs dut (.aclk, .aresetn, .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready, .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready, .s_axil_bresp, .s_axil_bvalid, .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready, .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .id_i, .id_wr_o, .ctrl_o, .ctrl_wr_o, .status_o, .status_set_i, .status_wr_o, .thresh_o, .thresh_wr_o, .count_i, .count_wr_o, .trig_o, .trig_clr_i, .trig_wr_o);
  int errors = 0, pulses = 0; logic [31:0] rd;
  // test tasks: tests/demo_regs_tests.sv
  `include "demo_regs_tests.sv"
  always @(posedge aclk) if (ctrl_wr_o) pulses++;
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("demo_regs_tb.vcd"); $dumpvars(0, demo_regs_tb); end
    repeat (4) @(posedge aclk); aresetn = 1; repeat (2) @(posedge aclk);
    bfm.read(5'h04, rd); check(rd == 32'h10, "CTRL reset"); bfm.read(5'h0C, rd); check(rd == 32'h100, "THRESH reset");
    bfm.read(5'h00, rd); check(rd == 32'hC0DE0001, "ID read");
    count_i = 32'd77; bfm.read(5'h10, rd); check(rd == 77, "COUNT read");
    bfm.write(5'h04, 32'hA5A5_1235); bfm.read(5'h04, rd); check(rd == 32'hA5A51235 && ctrl_o == 32'hA5A51235, "CTRL write"); check(pulses == 1, "write pulse");
    bfm.write_strb(5'h04, 32'h0000_00FF, 4'b0001); bfm.read(5'h04, rd); check(rd == 32'hA5A512FF, $sformatf("strobe write %h", rd));
    bfm.write(5'h00, 32'h1); check(bfm.last_resp != 2'b00, "write to RO must fail");
    // W1C
    @(posedge aclk); #1 status_set_i = 32'h3; @(posedge aclk); #1 status_set_i = 0; bfm.read(5'h08, rd); check(rd == 3, "STATUS set by hw");
    bfm.write(5'h08, 32'h1); bfm.read(5'h08, rd); check(rd == 2, "W1C clear bit 0"); check(status_o == 2, "status_o");
    bfm.write(5'h08, 32'h0); bfm.read(5'h08, rd); check(rd == 2, "writing 0 must not clear");
    bfm.write(5'h08, 32'h2); bfm.read(5'h08, rd); check(rd == 0, "W1C clear bit 1");
    // W1S
    bfm.write(5'h14, 32'h1); bfm.read(5'h14, rd); check(rd == 1 && trig_o == 1, "W1S set");
    bfm.write(5'h14, 32'h0); bfm.read(5'h14, rd); check(rd == 1, "W1S write 0 keeps");
    @(posedge aclk); #1 trig_clr_i = 32'h1; @(posedge aclk); #1 trig_clr_i = 0; bfm.read(5'h14, rd); check(rd == 0, "W1S cleared by hw");
    // out of range
    bfm.read(5'h1C, rd); check(bfm.last_resp != 2'b00, "read beyond map must fail");
    bfm.write(5'h1C, 32'h1); check(bfm.last_resp != 2'b00, "write beyond map must fail");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #2_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
