// ***************
// Filename: feature_detect_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for feature_detect: the structural
//   checks (ID block, registers, beats forwarded on m_axis in order with
//   stalls of the observed stream, disable, FRAMES / done_o, edges counted,
//   RESTART timing). axis_frame_bfm sends the frames; tready of the observed
//   stream, which feature_detect only watches, is driven here. Every pixel's
//   feature bits and every register are compared with the golden model by
//   the cocotb test tb/python/feature_detect_tb.py. Prints TEST PASSED on
//   success; +vcd dumps feature_detect_tb.vcd. The test tasks are in
//   tests/feature_detect_tests.sv (`included).
// Date: 2026-10-21
`timescale 1ns/1ps
module feature_detect_tb;
  localparam int MAXW = 64, MAXH = 48, CELL_LOG2 = 2, SHIFT_MAX = 2;   // small frames: +-2 cells searched
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  int W = 64, H = 48;

  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  axis_if #(.DATA_W(24), .USER_W(1)) s_axis ();
  initial s_axis.tready = 1;
  logic done;
  logic [1:0] feat;
  int stall_pct = 0;                                 // % of clocks the observed stream is not ready
  always @(posedge clk) s_axis.tready <= ($urandom_range(99) >= stall_pct);

  axis_if #(.DATA_W(24), .USER_W(1)) m_axis ();
  assign m_axis.tready = 1'b1;
  feature_detect_top #(
    .MAXW(MAXW),
    .MAXH(MAXH),
    .CELL_LOG2(CELL_LOG2),
    .SHIFT_MAX(SHIFT_MAX)
  ) dut (
    .clk,
    .rst_n,
    .s_axis(s_axis),
    .m_axis(m_axis),
    .feat_o(feat),
    .done_o(done),
    .s_axil(s_axil)
  );
  axil_bfm #(.ADDR_W(8)) bfm (
    .aclk(clk),
    .*
  );
  axis_frame_bfm #(
    .DW(24),
    .MAXW(MAXW),
    .MAXH(MAXH)
  ) vid (
    .clk,
    .s_tdata(s_axis.tdata),
    .s_tlast(s_axis.tlast),
    .s_tuser(s_axis.tuser),
    .s_tvalid(s_axis.tvalid),
    .s_tready(s_axis.tready),
    .m_tdata(24'd0),
    .m_tlast(1'b0),
    .m_tuser(1'b0),
    .m_tvalid(1'b0),
    .m_tready()
  );
  // the accepted input beats, in order, and their forwarded copies on m_axis
  logic [25:0] fifo [$];
  int fwd_n = 0, fwd_bad = 0, dones = 0;
  bit feat_seen = 0;
  always @(posedge clk) if (rst_n) begin
    if (done) dones++;
    if (s_axis.tvalid && s_axis.tready) fifo.push_back({s_axis.tuser, s_axis.tlast, s_axis.tdata});
    if (m_axis.tvalid) begin
      fwd_n++;
      if (fifo.size() == 0 || fifo.pop_front() !== {m_axis.tuser, m_axis.tlast, m_axis.tdata}) fwd_bad++;
      if (feat != 0) feat_seen = 1;
    end
  end

  `include "feature_detect_tests.sv"

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("feature_detect_tb.vcd");
      $dumpvars(0, feature_detect_tb);
    end
    repeat (4) @(posedge clk);
    bfm.base = 'h10;                           // the map after the ID block
    rst_n = 1;
    repeat (2) @(posedge clk);
    test_id_block();
    test_registers();
    test_forward();
    test_restart();
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #50ms;
    $display("ERROR: simulation timeout");
    $display("TEST FAILED");
    $finish;
  end
endmodule
