// ***************
// Filename: vid_timing_gen_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for vid_timing_gen. For two modes
//   (positive and negative sync polarity) it measures every line and frame:
//   total line length, active pixels and their x / y, hsync start and width,
//   vsync start line, width in lines and its alignment with the hsync
//   leading edge, active lines, sof / eol / vblank. Genlock: with
//   src_ready low, the frame must be extended by exactly lock_max lines
//   (waiting high on them); with src_ready going high during the wait, the
//   next frame must start at the end of that line. Prints TEST PASSED on
//   success.
//   The test tasks are in tests/vid_timing_gen_tests.sv (`included).
// Date: 2026-10-01
`timescale 1ns/1ps
module vid_timing_gen_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  int errors = 0;

  logic en; logic [15:0] ha, hf, hs, hb, va, vf, vs, vb, lmax; logic hp, vp, lk, rdy;
  logic de, hso, vso, sof, eol, vbl, wt; logic [15:0] x, y;
  vid_timing_gen dut (.clk, .rst_n, .enable_i(en), .h_active_i(ha), .h_fp_i(hf), .h_sync_i(hs), .h_bp_i(hb),
    .v_active_i(va), .v_fp_i(vf), .v_sync_i(vs), .v_bp_i(vb), .hs_pol_i(hp), .vs_pol_i(vp),
    .lock_en_i(lk), .src_ready_i(rdy), .lock_max_i(lmax),
    .de_o(de), .hs_o(hso), .vs_o(vso), .x_o(x), .y_o(y), .sof_o(sof), .eol_o(eol), .vblank_o(vbl), .waiting_o(wt));

  // test tasks: tests/vid_timing_gen_tests.sv
  `include "vid_timing_gen_tests.sv"

  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("vid_timing_gen_tb.vcd"); $dumpvars(0, vid_timing_gen_tb); end
    en = 0; lk = 0; rdy = 1; lmax = 0;
    ha = 40; hf = 5; hs = 7; hb = 13; va = 12; vf = 2; vs = 3; vb = 4; hp = 1; vp = 1;
    repeat (3) @(posedge clk); rst_n = 1; @(posedge clk); en = 1;
    measure_frame(0); measure_frame(0);
    $display("mode 1 (40x12, positive syncs): 2 frames");
    // Second mode, negative polarity, changed while a frame runs: it must
    // only apply from the next frame start, so skip the frame in progress
    ha = 64; hf = 16; hs = 12; hb = 30; va = 8; vf = 3; vs = 5; vb = 1; hp = 0; vp = 0;
    @(posedge clk); while (!sof) @(posedge clk);
    measure_frame(0);
    measure_frame(0);
    $display("mode 2 (64x8, negative syncs, vbp = 1): 2 frames");
    // Genlock: source never ready -> the frame in progress ends with exactly lmax extra lines
    lk = 1; rdy = 0; lmax = 5;
    measure_frame(5);
    // Source becomes ready after 2 extra lines
    fork
      measure_frame(2);
      begin
        while (!(wt)) @(posedge clk);
        repeat ((ha + hf + hs + hb) + 3) @(posedge clk);   // into the second extra line
        rdy = 1;
      end
    join
    $display("genlock: timeout after lock_max lines, and release when the source is ready");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
