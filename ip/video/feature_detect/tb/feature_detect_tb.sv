// ***************
// Filename: feature_detect_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for feature_detect. axis_frame_bfm
//   sends test frames on the observed stream; its tready, which
//   feature_detect only watches, is driven by the testbench (random stalls
//   where a test asks for them). The feature bits feat_o of every accepted
//   beat are captured; after each frame feature_ref (ip/video/video_tb_lib)
//   steps through the same frame with the settings and the shift
//   feature_detect used, and every pixel's edge and motion bits, EDGE_COUNT,
//   MOTION_COUNT and (after done_o) SHIFT_EST must equal the model's. Tests:
//   ID block, registers, edge patterns and thresholds, the edge fill span,
//   a moving object on a still background, RESTART, the background rate, a
//   panning background with the automatic shift, a manual shift, disable,
//   random scenes and settings with stalls. Prints TEST PASSED on success;
//   +vcd dumps feature_detect_tb.vcd. The test tasks are in
//   tests/feature_detect_tests.sv (`included).
// Date: 2026-10-14
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

  feature_detect_top #(
    .MAXW(MAXW),
    .MAXH(MAXH),
    .CELL_LOG2(CELL_LOG2),
    .SHIFT_MAX(SHIFT_MAX)
  ) dut (
    .clk,
    .rst_n,
    .s_axis(s_axis),
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
  feature_ref #(
    .MAXW(MAXW),
    .MAXH(MAXH),
    .CELL_LOG2(CELL_LOG2),
    .SHIFT_MAX(SHIFT_MAX)
  ) mdl ();

  // feature bits of every accepted beat, and the shift in effect (taken at the frame start)
  logic [1:0] cap [MAXH][MAXW];
  int cx = 0, cy = 0, used_x = 0, used_y = 0, dones = 0;
  always @(posedge clk) if (rst_n) begin
    if (done) dones++;
    if (s_axis.tvalid && s_axis.tready && dut.u_core.en) begin
      if (s_axis.tuser) begin
        cx = 0;
        cy = 0;
        used_x = int'($signed(dut.u_core.fsx));
        used_y = int'($signed(dut.u_core.fsy));
      end
      if (cy < MAXH && cx < MAXW) cap[cy][cx] = feat;
      if (s_axis.tlast) begin
        cx = 0;
        cy++;
      end else cx++;
    end
  end
  // expected settings
  int e_ctrl = 0, e_edge = 'h0008_0080, e_motion = 'h0000_2214;

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
    test_edges();
    test_edge_span();
    test_motion();
    test_restart();
    test_rate();
    test_pan_auto();
    test_manual_shift();
    test_disable();
    test_random();
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
