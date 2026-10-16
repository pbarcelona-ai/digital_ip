// ***************
// Filename: hdmi_sink_model.sv
// Author: FPGA Cores 4 U
// Description: Testbench DVI / HDMI receiver model working on parallel TMDS
//   symbols (one 10-bit symbol per channel per pixel clock). Decodes every
//   symbol independently of the transmitter RTL (control tokens, 8b/10b
//   video, TERC4, guard bands), rebuilds hsync / vsync, and captures the
//   active pixels of each frame into frame[] (pixel {ch0, ch1, ch2} =
//   {B, G, R}). Guard bands are only recognised outside video periods (a
//   video pixel may encode to the same symbols). Checks while running:
//     - every symbol is legal for its period;
//     - hdmi = 1: every video period follows exactly 8 video-preamble
//       clocks and 2 video guard band clocks; every data island has 8
//       island-preamble clocks, 2 leading and 2 trailing guard band clocks
//       around 32 TERC4 packet clocks; header / sub-packet BCH ECC and the
//       InfoFrame checksum are verified and the last AVI InfoFrame is kept
//       in avi_hb / avi_pb;
//     - hdmi = 0 (DVI): no preamble, guard band or TERC4 symbol at all.
//   A frame ends at the vsync edge into vs_active (set by the testbench);
//   lines / line_len then describe it and frames counts it.
// Date: 2026-10-01
`timescale 1ns/1ps
module hdmi_sink_model #(
  parameter int MAXW = 256,
  parameter int MAXH = 128
) (
  input logic       clk,
  input logic       en,
  input logic [9:0] ch0,
  input logic [9:0] ch1,
  input logic [9:0] ch2
);
  bit hdmi = 0, vs_active = 1;                    // set by the testbench
  int errors = 0, frames = 0, islands = 0, avi_frames = 0;
  int lines = 0, line_len = 0;                    // geometry of the last frame
  logic [23:0] frame [MAXH][MAXW];
  logic [7:0] avi_hb [3]; logic [7:0] avi_pb [28];
  logic hs = 0, vs = 0;

  task automatic err(input string m);
    errors++; if (errors < 20) $display("ERROR @%0t sink: %s", $time, m);
  endtask

  function automatic int ctrl_val(input logic [9:0] q);           // -1 if not a control token
    case (q)
      10'b1101010100: return 0; 10'b0010101011: return 1;
      10'b0101010100: return 2; 10'b1010101011: return 3;
      default: return -1;
    endcase
  endfunction
  function automatic int terc4_val(input logic [9:0] q);          // -1 if not a TERC4 symbol
    case (q)
      10'b1010011100: return 0;  10'b1001100011: return 1;  10'b1011100100: return 2;  10'b1011100010: return 3;
      10'b0101110001: return 4;  10'b0100011110: return 5;  10'b0110001110: return 6;  10'b0100111100: return 7;
      10'b1011001100: return 8;  10'b0100111001: return 9;  10'b0110011100: return 10; 10'b1011000110: return 11;
      10'b1010001110: return 12; 10'b1001110001: return 13; 10'b0101100011: return 14; 10'b1011000011: return 15;
      default: return -1;
    endcase
  endfunction
  function automatic logic [7:0] video_val(input logic [9:0] q);  // DVI 8b/10b decode
    logic [7:0] d, m; m = q[9] ? ~q[7:0] : q[7:0];
    d[0] = m[0];
    for (int i = 1; i < 8; i++) d[i] = q[8] ? (m[i] ^ m[i-1]) : ~(m[i] ^ m[i-1]);
    return d;
  endfunction
  function automatic logic [7:0] bch(input logic [63:0] d, input int nbits);
    logic [7:0] e; e = 0;
    for (int i = 0; i < nbits; i++) e = (e >> 1) ^ ((e[0] ^ d[i]) ? 8'b1000_0011 : 8'd0);
    return e;
  endfunction

  localparam int S_CTRL = 0, S_VGB = 1, S_VIDEO = 2, S_ISL = 3;
  localparam int P_NONE = 0, P_VID = 1, P_ISL = 2;
  int state = S_CTRL, pre_kind = P_NONE, pre_cnt = 0, gb = 0, ipos = 0, lgb = 0, tgb = 0, x = 0, y = 0;
  logic [31:0] ihdr; logic [63:0] isp [4];
  logic vs_q = 0;

  localparam logic [9:0] VGB02 = 10'b1011001100, GB1 = 10'b0100110011;

  always @(posedge clk) if (en) begin
    int c0, c1, c2, t0, t1, t2, kind;
    c0 = ctrl_val(ch0); c1 = ctrl_val(ch1); c2 = ctrl_val(ch2);
    t0 = terc4_val(ch0); t1 = terc4_val(ch1); t2 = terc4_val(ch2);

    if (c0 >= 0 && c1 >= 0 && c2 >= 0) begin                         // ---- control period
      if (state == S_ISL) err("data island interrupted by a control period");
      if (state == S_VGB) err("video guard band not followed by video");
      if (state == S_VIDEO) begin line_len = x; x = 0; y++; end      // end of an active line
      hs = c0[0]; vs = c0[1];
      kind = (c1 == 1 && c2 == 0) ? P_VID : (c1 == 1 && c2 == 1) ? P_ISL : P_NONE;
      if (!(c1 == 0 && c2 == 0) && kind == P_NONE) err($sformatf("unexpected CTL bits %0d %0d", c1, c2));
      if (kind != P_NONE && !hdmi) err("preamble in DVI mode");
      pre_cnt = (kind != P_NONE && kind == pre_kind) ? pre_cnt + 1 : (kind != P_NONE ? 1 : 0);
      pre_kind = kind; state = S_CTRL; gb = 0;
    end else if (state != S_ISL && state != S_VIDEO && ch0 == VGB02 && ch1 == GB1 && ch2 == VGB02) begin  // video guard band
      if (!hdmi) err("guard band in DVI mode");
      if (state == S_CTRL && !(pre_kind == P_VID && pre_cnt == 8)) err($sformatf("video guard band after %0d preamble clocks", pre_cnt));
      gb++; if (gb > 2) err("video guard band longer than 2 clocks");
      state = S_VGB; pre_kind = P_NONE; pre_cnt = 0;
    end else if (state != S_VIDEO && ch1 == GB1 && ch2 == GB1 && t0 >= 0) begin         // ---- island guard band
      if (!hdmi) err("data island in DVI mode");
      if ((t0 >> 2) != 3) err("island guard band: channel 0 bits 3:2 must be 11");
      hs = t0 & 1; vs = (t0 >> 1) & 1;
      if (state == S_CTRL) begin
        if (!(pre_kind == P_ISL && pre_cnt == 8)) err($sformatf("island guard band after %0d preamble clocks", pre_cnt));
        state = S_ISL; ipos = 0; lgb = 1; tgb = 0;
      end else if (state == S_ISL && ipos == 0 && lgb == 1) lgb = 2;
      else if (state == S_ISL && ipos == 32) begin
        tgb++;
        if (tgb == 2) begin islands++; check_packet(); state = S_CTRL; end
      end else err("misplaced island guard band");
      pre_kind = P_NONE; pre_cnt = 0;
    end else if (state == S_ISL && t0 >= 0 && t1 >= 0 && t2 >= 0) begin               // ---- island packet
      if (lgb != 2 || ipos >= 32) err($sformatf("island packet clock out of place (lgb %0d pos %0d)", lgb, ipos));
      else begin
        hs = t0 & 1; vs = (t0 >> 1) & 1;
        ihdr[ipos] = (t0 >> 2) & 1;
        if (((t0 >> 3) & 1) != (ipos != 0)) err("island channel 0 bit 3 wrong");
        for (int k = 0; k < 4; k++) begin isp[k][2*ipos] = (t1 >> k) & 1; isp[k][2*ipos + 1] = (t2 >> k) & 1; end
        ipos++;
      end
    end else begin                                                                     // ---- video data
      if (state == S_ISL) err("video symbol inside a data island");
      if (state == S_CTRL && hdmi) err("video period without guard band");
      if (state == S_VGB && gb != 2) err($sformatf("video after a %0d-clock guard band", gb));
      if (x < MAXW && y < MAXH) frame[y][x] = {video_val(ch0), video_val(ch1), video_val(ch2)};
      x++; state = S_VIDEO; gb = 0; pre_kind = P_NONE; pre_cnt = 0;
    end

    if (vs == vs_active && vs_q != vs_active) begin                  // frame boundary
      if (y > 0) begin lines = y; frames++; end
      x = 0; y = 0;
    end
    vs_q = vs;
  end

  task automatic check_packet();
    logic [7:0] sum, e;
    e = bch({40'd0, ihdr[23:0]}, 24);
    if (ihdr[31:24] != e) err($sformatf("packet header ECC %02h exp %02h", ihdr[31:24], e));
    for (int k = 0; k < 4; k++) begin
      e = bch({8'd0, isp[k][55:0]}, 56);
      if (isp[k][63:56] != e) err($sformatf("sub-packet %0d ECC %02h exp %02h", k, isp[k][63:56], e));
    end
    if (ihdr[7:0] == 8'h82) begin                                    // AVI InfoFrame
      avi_hb[0] = ihdr[7:0]; avi_hb[1] = ihdr[15:8]; avi_hb[2] = ihdr[23:16];
      for (int k = 0; k < 4; k++) for (int b = 0; b < 7; b++) avi_pb[7*k + b] = isp[k][8*b +: 8];
      sum = avi_hb[0] + avi_hb[1] + avi_hb[2];
      for (int i = 0; i <= avi_hb[2] && i < 28; i++) sum += avi_pb[i];
      if (sum != 0) err($sformatf("AVI InfoFrame checksum: bytes sum to %02h", sum));
      avi_frames++;
    end
  endtask
endmodule
