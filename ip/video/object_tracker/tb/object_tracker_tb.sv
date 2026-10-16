// ***************
// Filename: object_tracker_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for object_tracker. axis_frame_bfm
//   sends test images on the observed stream; the stream's tready, which
//   object_tracker only watches, is driven by the testbench (random stalls
//   where a test asks for them). After every frame the results (COUNT,
//   BOX_X, BOX_Y, SUM_X, SUM_Y, FRAMES) are compared with track_ref's
//   measurement model for the window and settings the testbench expects
//   for that frame (window taken at the frame start). Tests: registers,
//   dark and bright objects, search window (also changed in the middle of
//   a frame), the run filter, an empty frame, disable, STATUS, random
//   images and settings with stalls, the colour mode (skin tone, saturated
//   paint, SAT_MIN), the run-width band (RUN.MIN_W / MAX_W), the scratch
//   words, random colour scenes, blobs, and the two terms: feat_i is the
//   pixel's own LSBs (edge = B[0], motion = G[0]) so the model sees the same
//   features (CTRL.FEAT_A, CTRL.TERM_B, RUN_B). Prints TEST PASSED on success; +vcd
//   dumps object_tracker_tb.vcd. The test tasks are in
//   tests/object_tracker_tests.sv (`included).
// Date: 2026-10-15
`timescale 1ns/1ps
module object_tracker_tb;
  localparam int MAXW = 64, MAXH = 48;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  int W = 48, H = 36;

  axil_if #(.ADDR_W(9), .DATA_W(32)) s_axil ();
  axis_if #(.DATA_W(24), .USER_W(1)) s_axis ();
  initial s_axis.tready = 1;
  logic done;
  int stall_pct = 0;                                 // % of clocks the observed stream is not ready
  bit feat_on = 0;                                   // feat_i driven (from the pixel's LSBs)
  always @(posedge clk) s_axis.tready <= ($urandom_range(99) >= stall_pct);

  object_tracker_top dut (
    .clk,
    .rst_n,
    .s_axis(s_axis),
    .feat_i(feat_on ? {s_axis.tdata[8], s_axis.tdata[16]} : 2'b00),
    .done_o(done),
    .s_axil(s_axil)
  );
  axil_bfm #(.ADDR_W(9)) bfm (
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
  track_ref #(
    .MAXW(MAXW),
    .MAXH(MAXH)
  ) mdl ();

  int dones = 0;                                     // done_o pulses
  always @(posedge clk) if (rst_n && done) dones++;
  // expected settings: window taken at the frame start (e_win), the rest live
  int e_win [4];
  int e_thr = 128, e_dark = 1, e_run = 0, e_ctrl = 0;
  int e_runw = 0, e_yr = 'hFF00, e_cbr = 'hFF00, e_crr = 'hFF00, e_sat = 0;   // RUN, colour ranges, SAT_MIN
  bit e_en = 0;

  `include "object_tracker_tests.sv"

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("object_tracker_tb.vcd");
      $dumpvars(0, object_tracker_tb);
    end
    repeat (4) @(posedge clk);
    bfm.base = 'h10;                           // the map after the ID block
    rst_n = 1;
    repeat (2) @(posedge clk);
    test_id_block();
    test_registers();
    test_dark_object();
    test_bright_object();
    test_window();
    test_run_filter();
    test_empty();
    test_disable();
    test_status();
    test_random();
    test_colour();
    test_run_band();
    test_scratch();
    test_random_colour();
    test_blobs();
    test_terms();
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #20ms;
    $display("ERROR: timeout");
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
