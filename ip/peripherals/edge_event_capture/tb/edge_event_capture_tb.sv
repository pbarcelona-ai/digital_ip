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
  edge_event_capture_top #(.WIDTH(W), .FIFO_DEPTH(16)) dut (
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
  // test tasks: tests/edge_event_capture_tests.sv
  `include "edge_event_capture_tests.sv"
  logic [TS_W+2*W-1:0] ev_q[$], e0, e1;
  always @(posedge aclk) if (m_tvalid && m_tready) ev_q.push_back(m_tdata);
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("edge_event_capture_tb.vcd");
      $dumpvars(0, edge_event_capture_tb);
    end
    repeat (4) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);
    bfm.write(8'h04, 32'h0F); // rise: 0-3, fall: 4-7
    bfm.write(8'h08, 32'hF0);
    bfm.write(8'h24, 32'hFF);
    // ---- Test 1: basic rise/fall, masks ----
    sig[1] = 1;
    repeat (6) @(posedge aclk);
    bfm.read(8'h10, rd);
    check(rd == 32'h02, $sformatf("rise pend %h", rd));
    sig[5] = 1; // rise on masked (fall-only) channel
    repeat (6) @(posedge aclk);
    bfm.read(8'h10, rd);
    check(rd == 32'h02, "channel 5 rise must be masked");
    sig[5] = 0;
    repeat (6) @(posedge aclk);
    bfm.read(8'h14, rd);
    check(rd == 32'h20, $sformatf("fall pend %h", rd));
    check(irq == 1, "irq");
    bfm.write(8'h10, 32'hFF);
    bfm.write(8'h14, 32'hFF);
    repeat (3) @(posedge aclk);
    check(irq == 0, "irq should clear");
    bfm.read(8'h10, rd);
    check(rd == 0, "W1C rise");
    bfm.read(8'h18, rd);
    check(rd == 2, $sformatf("event count %0d", rd));
    // ---- Test 2: event records ----
    check(ev_q.size() == 2, $sformatf("records %0d", ev_q.size()));
    if (ev_q.size() == 2) begin
      e0 = ev_q[0];
      e1 = ev_q[1];
      check(e0[W-1:0] == 8'h02 && e0[2*W-1:W] == 0, "record 0 flags");
      check(e1[W-1:0] == 0 && e1[2*W-1:W] == 8'h20, "record 1 flags");
      check(e1[TS_W+2*W-1:2*W] > e0[TS_W+2*W-1:2*W], "timestamps must increase");
    end
    // ---- Test 3: debounce 8 clocks rejects a 4 clock glitch ----
    bfm.write(8'h0C, 8);
    ev_q.delete();
    sig[2] = 1;
    repeat (4) @(posedge aclk);
    sig[2] = 0;
    repeat (20) @(posedge aclk);
    bfm.read(8'h10, rd);
    check(rd == 0, "glitch should be filtered");
    sig[2] = 1;
    repeat (30) @(posedge aclk);
    bfm.read(8'h10, rd);
    check(rd == 32'h04, "stable input should pass debounce");
    // ---- Test 4: simultaneous multi-channel edges in one record ----
    bfm.write(8'h0C, 0);
    bfm.write(8'h10, 32'hFF);
    ev_q.delete();
    sig[0] = 1; // ~7-cycle capture latency + margin
    sig[3] = 1;
    sig[7] = 0;
    repeat (12) @(posedge aclk);
    e0 = ev_q[0];
    check(ev_q.size() >= 1 && e0[W-1:0] == 8'h09, "combined rise flags");
    // ---- Test 5: FIFO overflow counts drops ----
    m_tready = 0;
    bfm.write(8'h0C, 0);
    repeat (40) begin
      sig[6] = ~sig[6];
      repeat (4) @(posedge aclk);
    end
    bfm.read(8'h20, rd);
    check(rd > 0, "drops expected with stalled stream");
    m_tready = 1;
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
