// ***************
// Filename: csi2_tx_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for csi2_tx, looped back into the
//   verified receiver csi2_rx. A vid_timing_gen produces frames whose pixels
//   encode (x, y, frame). Three transmitters (1, 2 and 4 lanes) send them
//   on separate byte-clock links; the PHY model raises tx_ready a random
//   0-5 clocks after each HS request. Every line received is compared byte
//   for byte with the expected RGB888 (B, G, R) or YUV422 (U, Y0, V, Y1)
//   payload; frame start / end counts, ECC and CRC errors, dropped lines and
//   engine underflows are checked. Prints TEST PASSED on success.
//   The test tasks are in tests/csi2_tx_tests.sv (`included).
// Date: 2026-10-02
`timescale 1ns/1ps
module csi2_tx_tb;
  logic pclk = 0, bclk = 0, prst_n = 0, brst_n = 0;
  always #5 pclk = ~pclk;                        // 100 MHz pixels
  always #4 bclk = ~bclk;                        // 125 MHz D-PHY byte clock
  int errors = 0;
  initial begin #5ms; $display("ERROR: simulation timeout"); $display("TEST FAILED"); $finish; end

  localparam int HA = 32, VA = 8;
  logic en; logic yuv;
  logic de, hs, vs, sof, eol, vbl, wt; logic [15:0] x, y;
  vid_timing_gen u_vtg (.clk(pclk), .rst_n(prst_n), .enable_i(1'b1), .h_active_i(16'(HA)), .h_fp_i(16'd8), .h_sync_i(16'd8),
    .h_bp_i(16'd152), .v_active_i(16'(VA)), .v_fp_i(16'd2), .v_sync_i(16'd2), .v_bp_i(16'd2), .hs_pol_i(1'b1), .vs_pol_i(1'b1),
    .lock_en_i(1'b0), .src_ready_i(1'b1), .lock_max_i(16'd0),
    .de_o(de), .hs_o(hs), .vs_o(vs), .x_o(x), .y_o(y), .sof_o(sof), .eol_o(eol), .vblank_o(vbl), .waiting_o(wt));
  int fcount = 0;                                 // source frame number (counts vsync edges)
  logic vs_q = 0;
  always @(posedge pclk) begin vs_q <= vs; if (vs && !vs_q) fcount <= fcount + 1; end
  function automatic logic [23:0] pix(input int px, input int py, input int f);
    return {8'(px * 5 + py), 8'(f), 8'(px ^ (py << 2))};          // {B, G, R}: G carries the frame
  endfunction
  wire [23:0] rgb = de ? pix(x, y, fcount) : 24'h0;

  int nframes_rx [3], nlines [3], nfe [3];
  for (genvar g = 0; g < 3; g++) begin : g_l
    localparam int NL = (g == 0) ? 1 : (g == 1) ? 2 : 4;
    logic [NL*8-1:0] ld; logic [NL-1:0] lv; logic req, rdy = 0, drop, uf; logic [31:0] fr;
    csi2_tx #(.NLANES(NL), .MAX_W(64)) dut (.pclk, .prst_n, .enable_i(en), .vs_pol_i(1'b1), .rgb_i(rgb), .de_i(de), .vs_i(vs),
      .line_drop_o(drop), .frames_o(fr), .bclk, .brst_n, .vc_i(2'd1), .yuv422_i(yuv), .lp_gap_i(16'd6),
      .lane_data_o(ld), .lane_valid_o(lv), .hs_req_o(req), .tx_ready_i(rdy), .underflow_o(uf));
    // PHY: ready a random 0-5 clocks after the request, until the request ends
    always @(posedge bclk) begin
      if (!req) rdy <= 1'b0;
      else if (!rdy && $urandom_range(5) == 0) rdy <= 1'b1;
    end
    logic [NL*8-1:0] td; logic [NL-1:0] tk; logic tl, tu, tv, fs, fe, ln, ec, ee, ce, ov;
    csi2_rx #(.NLANES(NL)) rx (.clk(bclk), .rst_n(brst_n), .lane_data_i(ld), .lane_valid_i(lv), .vc_i(2'd1), .dt_i(yuv ? 6'h1E : 6'h24),
      .m_axis_tdata(td), .m_axis_tkeep(tk), .m_axis_tlast(tl), .m_axis_tuser(tu), .m_axis_tvalid(tv), .m_axis_tready(1'b1),
      .frame_start_o(fs), .frame_end_o(fe), .line_o(ln), .ecc_corrected_o(ec), .ecc_error_o(ee), .crc_error_o(ce), .overflow_o(ov));
    byte unsigned cur [256]; int n = 0, ly = 0;
    always @(posedge pclk) if (prst_n) begin
      check(!drop, $sformatf("%0d lanes: line dropped", NL));
    end
    always @(posedge bclk) if (brst_n) begin
      check(!uf && !ee && !ec && !ce && !ov, $sformatf("%0d lanes: underflow %b ecc %b/%b crc %b ovf %b", NL, uf, ec, ee, ce, ov));
      if (fs) begin nframes_rx[g]++; ly = 0; end
      if (fe) nfe[g]++;
      if (tv) begin
        for (int i = 0; i < NL; i++) if (tk[i]) begin cur[n] = td[8*i +: 8]; n++; end
        if (tl) begin
          int f, exp_n; logic [7:0] e;
          f = cur[1];                                // G (RGB) or Y0 (YUV) of pixel 0 = frame number
          exp_n = yuv ? 2 * HA : 3 * HA;
          check(n == exp_n, $sformatf("%0d lanes: line %0d has %0d bytes, exp %0d", NL, ly, n, exp_n));
          for (int i = 0; i < n && i < exp_n; i++) begin
            int px; logic [23:0] p0, p1;
            if (yuv) begin
              px = (i / 4) * 2; p0 = pix(px, ly, f); p1 = pix(px + 1, ly, f);
              case (i % 4)
                0: e = 8'((int'(p0[23:16]) + int'(p1[23:16]) + 1) >> 1);
                1: e = p0[15:8];
                2: e = 8'((int'(p0[7:0]) + int'(p1[7:0]) + 1) >> 1);
                default: e = p1[15:8];
              endcase
            end else begin
              p0 = pix(i / 3, ly, f);
              e = (i % 3 == 0) ? p0[23:16] : (i % 3 == 1) ? p0[15:8] : p0[7:0];
            end
            if (cur[i] != e) begin check(0, $sformatf("%0d lanes: frame %0d line %0d byte %0d = %02h exp %02h", NL, f, ly, i, cur[i], e)); break; end
          end
          n = 0; ly++; nlines[g]++;
        end
      end
    end
  end

  // test tasks: tests/csi2_tx_tests.sv
  `include "csi2_tx_tests.sv"

  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("csi2_tx_tb.vcd"); $dumpvars(0, csi2_tx_tb); end
    en = 0; yuv = 0;
    repeat (5) @(posedge pclk); prst_n = 1; brst_n = 1;
    run(0, 3);
    run(1, 3);
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
