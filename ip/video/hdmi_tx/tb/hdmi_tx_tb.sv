// ***************
// Filename: hdmi_tx_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for hdmi_tx. A vid_timing_gen
//   drives a small mode whose pixels are a function of (x, y, frame); the
//   TMDS output goes to hdmi_bfm, which decodes it independently.
//   DVI mode: frames must arrive pixel-exact with correct geometry and no
//   HDMI-only symbols. HDMI mode (both sync polarities): every line must
//   have its preamble and guard band, one AVI InfoFrame data island per
//   frame with correct ECC and checksum, and the InfoFrame fields must
//   match the configuration (RGB full range and YCbCr 4:4:4 BT.709).
//   Prints TEST PASSED on success.
//   The test tasks are in tests/hdmi_tx_tests.sv (`included).
// Date: 2026-10-01
`timescale 1ns/1ps
module hdmi_tx_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;

  localparam int HA = 48, VA = 10;
  logic en, pol, mode;
  logic [1:0] ay, ac, am, aq;
  logic [6:0] vic;
  logic de, hs, vs, sof, eol, vbl, wt;
  logic [15:0] x, y;
  vid_timing_gen u_vtg (
    .clk,
    .rst_n,
    .enable_i(en),
    .h_active_i(16'(HA)),
    .h_fp_i(16'd6),
    .h_sync_i(16'd10),
    .h_bp_i(16'd70),
    .v_active_i(16'(VA)),
    .v_fp_i(16'd2),
    .v_sync_i(16'd2),
    .v_bp_i(16'd3),
    .hs_pol_i(pol),
    .vs_pol_i(pol),
    .lock_en_i(1'b0),
    .src_ready_i(1'b1),
    .lock_max_i(16'd0),
    .de_o(de),
    .hs_o(hs),
    .vs_o(vs),
    .x_o(x),
    .y_o(y),
    .sof_o(sof),
    .eol_o(eol),
    .vblank_o(vbl),
    .waiting_o(wt)
  );

  int fnum = 0;
  function automatic logic [23:0] pix(input int px, input int py, input int f);
    return {8'(px * 5 + f), 8'(py * 23 + px), 8'(px ^ (py << 3) ^ (f * 77))};
  endfunction
  always @(posedge clk) if (sof) fnum <= fnum + 1;
  wire [23:0] rgb = de ? pix(x, y, sof ? fnum + 1 : fnum) : 24'h0;

  logic [9:0] t0, t1, t2, tc;
  hdmi_tx dut (
    .clk,
    .rst_n,
    .hdmi_mode_i(mode),
    .vs_pol_i(pol),
    .avi_y_i(ay),
    .avi_c_i(ac),
    .avi_m_i(am),
    .avi_vic_i(vic),
    .avi_q_i(aq),
    .rgb_i(rgb),
    .de_i(de),
    .hs_i(hs),
    .vs_i(vs),
    .tmds0_o(t0),
    .tmds1_o(t1),
    .tmds2_o(t2),
    .tmds_clk_o(tc)
  );
  logic sink_en = 0;
  hdmi_bfm #(.MAXW(64), .MAXH(16)) sink (
    .clk,
    .en(sink_en),
    .ch0(t0),
    .ch1(t1),
    .ch2(t2)
  );

  // test tasks: tests/hdmi_tx_tests.sv
  `include "hdmi_tx_tests.sv"

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("hdmi_tx_tb.vcd");
      $dumpvars(0, hdmi_tx_tb);
    end
    en = 0;
    mode = 0;
    pol = 1;
    ay = 0;
    ac = 0;
    am = 2'd2;
    aq = 2'd2;
    vic = 7'd16;
    repeat (3) @(posedge clk);
    rst_n = 1;

    // ---- DVI
    start(0, 1);
    frames(3);
    check(sink.islands == 0, "data island in DVI mode");
    $display("DVI: 3 frames %0dx%0d pixel-exact, no HDMI symbols", HA, VA);

    // ---- HDMI, RGB full range, positive syncs
    ay = 0;
    ac = 0;
    aq = 2'd2;
    vic = 7'd16;
    am = 2'd2;
    start(1, 1);
    frames(3);
    check(sink.avi_frames >= 3, $sformatf("%0d AVI InfoFrames in 3 frames", sink.avi_frames));
    check(sink.avi_hb[0] == 8'h82 && sink.avi_hb[1] == 8'h02 && sink.avi_hb[2] == 8'h0D, "AVI header");
    check(sink.avi_pb[1][6:5] == 2'd0 && sink.avi_pb[3][3:2] == 2'd2 && sink.avi_pb[4] == 8'd16 && sink.avi_pb[2][5:4] == 2'd2,
          $sformatf("AVI fields: PB1 %02h PB2 %02h PB3 %02h PB4 %02h", sink.avi_pb[1], sink.avi_pb[2], sink.avi_pb[3], sink.avi_pb[4]));
    $display("HDMI (RGB full range, VIC 16, positive syncs): 3 frames, %0d data islands, AVI ok", sink.islands);

    // ---- HDMI, YCbCr 4:4:4 BT.709, negative syncs
    ay = 2'd2;
    ac = 2'd2;
    aq = 2'd0;
    vic = 7'd4;
    am = 2'd2;
    start(1, 0);
    frames(3);
    check(sink.avi_frames >= 3, $sformatf("%0d AVI InfoFrames in 3 frames", sink.avi_frames));
    check(sink.avi_pb[1][6:5] == 2'd2 && sink.avi_pb[2][7:6] == 2'd2 && sink.avi_pb[4] == 8'd4,
          $sformatf("AVI fields: PB1 %02h PB2 %02h PB4 %02h", sink.avi_pb[1], sink.avi_pb[2], sink.avi_pb[4]));
    $display("HDMI (YCbCr 4:4:4 BT.709, VIC 4, negative syncs): 3 frames, %0d data islands, AVI ok", sink.islands);

    errors += sink.errors;
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors, %0d from the sink)", errors, sink.errors);
    $finish;
  end
endmodule
