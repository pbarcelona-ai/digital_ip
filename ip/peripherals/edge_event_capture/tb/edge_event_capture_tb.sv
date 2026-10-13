// ***************
// Filename: edge_event_capture_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the edge detector IP. Tests
//   rising and falling edge detection with enable masks, debounce
//   filtering of short glitches, pending flags with write-1-to-clear,
//   event counter, timestamped AXI-Stream event records, drop counter on
//   FIFO overflow and the irq output. Prints TEST PASSED on success.
//   The test tasks are in tests/edge_event_capture_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module edge_event_capture_tb;
  localparam int W = 8, TS_W = 32;
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
  logic [W-1:0] sig = 0, rise_o, fall_o;
  logic irq;
  logic [TS_W+2*W-1:0] m_tdata;
  logic m_tvalid, m_tready = 1, m_tlast;
  edge_event_capture_top #(
    .WIDTH(W),
    .FIFO_DEPTH(16)
  ) dut (
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
    .sig_i(sig),
    .rise_o,
    .fall_o,
    .irq_o(irq),
    .m_axis_tdata(m_tdata),
    .m_axis_tvalid(m_tvalid),
    .m_axis_tready(m_tready),
    .m_axis_tlast(m_tlast)
  );
  int errors = 0;
  logic [31:0] rd;
  logic [TS_W+2*W-1:0] ev_q[$], e0, e1;
  always @(posedge aclk) if (m_tvalid && m_tready) ev_q.push_back(m_tdata);
  // test tasks: tests/edge_event_capture_tests.sv
  `include "edge_event_capture_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("edge_event_capture_tb.vcd");
      $dumpvars(0, edge_event_capture_tb);
    end
    repeat (4) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);
    bfm.base = 'h10;                                 // the map after the ID block
    test_id_block();
    test_setup();
    test_edges();
    test_records();
    test_debounce();
    test_multi();
    test_overflow();

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
