// ***************
// Filename: quadrature_decoder_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the quadrature decoder IP. An
//   encoder model drives A/B/index. Tests forward and reverse counting
//   (x4), glitch rejection by the filter, illegal double transition error
//   count, index latch and clear, position load and the velocity AXI-
//   Stream samples. Prints TEST PASSED on success.
//   The test tasks are in tests/quadrature_decoder_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module quadrature_decoder_tb;
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
  logic a, b, z;
  logic [31:0] m_tdata;
  logic m_tvalid, m_tready = 1, m_tlast;
  quad_dec_top dut (
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
    .enc_a_i(a),
    .enc_b_i(b),
    .enc_z_i(z),
    .m_axis_tdata(m_tdata),
    .m_axis_tvalid(m_tvalid),
    .m_axis_tready(m_tready),
    .m_axis_tlast(m_tlast)
  );
  // incremental encoder driving the DUT
  quad_bfm enc (
    .clk(aclk),
    .a,
    .b,
    .z
  );
  int errors = 0;
  logic [31:0] rd;
  int vel_samples[$];
  always @(posedge aclk) if (m_tvalid && m_tready) vel_samples.push_back($signed(m_tdata));
  // test tasks: tests/quadrature_decoder_tests.sv
  `include "quadrature_decoder_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("quadrature_decoder_tb.vcd");
      $dumpvars(0, quadrature_decoder_tb);
    end
    repeat (4) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);
    bfm.base = 'h10;                                 // the map after the ID block
    test_id_block();
    test_setup();
    test_forward();
    test_reverse();
    test_glitch();
    test_illegal();
    test_index();
    test_load();
    test_velocity();

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
