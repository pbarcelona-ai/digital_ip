// ***************
// Filename: hdmi_tx.sv
// Author: FPGA Cores 4 U
// Description: DVI / HDMI transmitter, TMDS link layer. Version 1.0.0.
//   Encodes 24-bit video with its de / hsync / vsync into three 10-bit
//   TMDS symbol streams (channel 0 blue + syncs, 1 green, 2 red) plus the
//   TMDS clock pattern, for a 10:1 serializer (tmds_serializer or vendor
//   OSERDES) and differential output buffers.
//   hdmi_mode_i = 0 (DVI): video and control periods only.
//   hdmi_mode_i = 1 (HDMI): additionally
//     - before every active line: 8-clock video preamble (CTL0 = 1) and a
//       2-clock video guard band, found with an 11-clock look-ahead (the
//       output is delayed by 11 clocks);
//     - once per frame, starting at the vsync leading edge: one data island
//       (8-clock preamble, 2-clock guard band, 32-clock packet, 2-clock
//       guard band) carrying an AVI InfoFrame (version 2): colour space
//       avi_y_i (0 RGB, 1 YCbCr 4:2:2, 2 YCbCr 4:4:4), colorimetry
//       avi_c_i, picture aspect avi_m_i, VIC avi_vic_i, RGB quantisation
//       range avi_q_i (0 default, 1 limited, 2 full). The packet header and
//       sub-packets carry the BCH ECC of the HDMI specification.
//   Requirements on the timing (true for every CEA-861 mode): horizontal
//   blanking >= 12 clocks, and the vsync leading edge at least 56 clocks
//   before the next active line (the island and a following preamble fit).
//   Input pixel {B, G, R} (or {Cb, Y, Cr}): component 0 in the LSBs.
//   vs_pol_i tells which vsync level is the active one. Clock - pixel
//   clock only. Reset - synchronous rst_n (active low). Latency - 12
//   clocks.
// Date: 2026-10-01
module hdmi_tx (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        hdmi_mode_i,
  input  logic        vs_pol_i,
  input  logic [1:0]  avi_y_i,
  input  logic [1:0]  avi_c_i,
  input  logic [1:0]  avi_m_i,
  input  logic [6:0]  avi_vic_i,
  input  logic [1:0]  avi_q_i,
  input  logic [23:0] rgb_i,
  input  logic        de_i,
  input  logic        hs_i,
  input  logic        vs_i,
  output logic [9:0]  tmds0_o,
  output logic [9:0]  tmds1_o,
  output logic [9:0]  tmds2_o,
  output logic [9:0]  tmds_clk_o
);
  localparam int D = 11;                       // look-ahead (preamble 8 + guard 2 + 1)
  localparam logic [1:0] M_CTRL = 2'd0, M_VIDEO = 2'd1, M_TERC4 = 2'd2, M_GUARD = 2'd3;
  localparam logic [9:0] GB_VID_02 = 10'b1011001100, GB_VID_1 = 10'b0100110011, GB_ISL = 10'b0100110011;
  assign tmds_clk_o = 10'b0000011111;

  // ---------------- look-ahead delay line: index 0 = what is output now
  logic [23:0] rgb_d [D+1];
  logic [D:0] de_d, hs_d, vs_d;
  always_ff @(posedge clk) begin
    rgb_d[0] <= rgb_i;
    de_d[0] <= de_i;
    hs_d[0] <= hs_i;
    vs_d[0] <= vs_i;
    for (int k = 1; k <= D; k++) begin
      rgb_d[k] <= rgb_d[k-1];
      de_d[k] <= de_d[k-1];
      hs_d[k] <= hs_d[k-1];
      vs_d[k] <= vs_d[k-1];
    end
  end
  wire [23:0] rgb0 = rgb_d[D];
  wire de0 = de_d[D], hs0 = hs_d[D], vs0 = vs_d[D];
  // de of the pixel k clocks after the current output pixel = de_d[D - k]
  logic [3:0] rise;                            // clocks until the next de, 0 = none within 10
  always_comb begin
    rise = 4'd0;
    for (int k = 10; k >= 1; k--) if (de_d[D - k]) rise = 4'(k);
  end

  // ---------------- AVI InfoFrame packet and BCH ECC
  function automatic logic [7:0] bch(input logic [63:0] d, input int nbits);
    logic [7:0] e;
    e = 8'd0;
    for (int i = 0; i < 64; i++) if (i < nbits) e = (e >> 1) ^ ((e[0] ^ d[i]) ? 8'b1000_0011 : 8'd0);
    bch = e;
  endfunction
  logic [7:0] pb [14];                         // PB0 .. PB13
  logic [31:0] hdr;
  logic [63:0] sp [4];
  always_comb begin
    logic [7:0] sum;
    for (int i = 0; i < 14; i++) pb[i] = 8'd0;
    pb[1] = {1'b0, avi_y_i, 1'b1, 2'b00, 2'b00};          // Y, A0 = 1 (R valid), no bars, no scan info
    pb[2] = {avi_c_i, avi_m_i, 4'b1000};                  // C, M, R = same as picture
    pb[3] = {1'b0, 3'b000, avi_q_i, 2'b00};               // ITC, EC, Q, SC
    pb[4] = {1'b0, avi_vic_i};
    sum = 8'h82 + 8'h02 + 8'h0D;
    for (int i = 1; i < 14; i++) sum = sum + pb[i];
    pb[0] = 8'h00 - sum;                                  // checksum: all bytes sum to 0
    hdr[23:0] = 24'h0D_02_82;
    hdr[31:24] = bch({40'd0, hdr[23:0]}, 24);
    for (int k = 0; k < 4; k++) begin
      sp[k] = '0;
      if (k < 2) for (int b = 0; b < 7; b++) sp[k][8*b +: 8] = pb[7*k + b];
      sp[k][63:56] = bch(sp[k], 56);
    end
  end

  // ---------------- data island sequencing (on the output timeline)
  logic [5:0] isl;                             // 0 = idle, 1..44 = position + 1
  logic vs0_q;
  wire  vs_lead = (vs0 == vs_pol_i) && (vs0_q != vs_pol_i);
  logic [31:0] hdr_q;
  logic [63:0] sp_q [4];
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      isl <= '0;
      vs0_q <= 1'b0;
      hdr_q <= '0;
      for (int k = 0; k < 4; k++) sp_q[k] <= '0;
    end
    else begin
      vs0_q <= vs0;
      if (isl != 0) isl <= (isl == 6'd44) ? 6'd0 : isl + 1'b1;
      else if (hdmi_mode_i && vs_lead && !de0) begin               // this clock is position 0
        isl <= 6'd2;
        hdr_q <= hdr;
        for (int k = 0; k < 4; k++) sp_q[k] <= sp[k];
      end
    end
  end
  wire [5:0] ip = isl - 1'b1;                  // island position 0..43
  wire       in_isl = (isl != 0) || (hdmi_mode_i && vs_lead && !de0);
  wire [5:0] ipos = (isl != 0) ? ip : 6'd0;
  wire [4:0] pk = 5'(ipos - 6'd10);            // packet clock 0..31

  // ---------------- per-channel symbol selection
  logic [1:0] m0, m1, m2;
  logic [1:0] c0, c1, c2;
  logic [3:0] t0, t1, t2;
  logic [9:0] g0, g1, g2;
  always_comb begin
    m0 = M_CTRL;
    m1 = M_CTRL;
    m2 = M_CTRL;
    c0 = {vs0, hs0};
    c1 = 2'b00;
    c2 = 2'b00;
    t0 = '0;
    t1 = '0;
    t2 = '0;
    g0 = GB_VID_02;
    g1 = GB_VID_1;
    g2 = GB_VID_02;
    if (de0) begin
      m0 = M_VIDEO;
      m1 = M_VIDEO;
      m2 = M_VIDEO;
    end else if (hdmi_mode_i && rise != 0 && rise <= 4'd2) begin            // video guard band
      m0 = M_GUARD;
      m1 = M_GUARD;
      m2 = M_GUARD;
    end else if (hdmi_mode_i && rise != 0) begin                            // video preamble
      c1 = 2'b01;
      c2 = 2'b00;
    end else if (in_isl) begin
      if (ipos < 6'd8) begin // island preamble
        c1 = 2'b01;
        c2 = 2'b01;
      end
      else if (ipos < 6'd10 || ipos >= 6'd42) begin                         // island guard bands
        m0 = M_TERC4;
        t0 = {2'b11, vs0, hs0};
        m1 = M_GUARD;
        m2 = M_GUARD;
        g1 = GB_ISL;
        g2 = GB_ISL;
      end else begin                                                        // packet
        m0 = M_TERC4;
        m1 = M_TERC4;
        m2 = M_TERC4;
        t0 = {pk != 0, hdr_q[pk], vs0, hs0};
        for (int k = 0; k < 4; k++) begin
          t1[k] = sp_q[k][2*pk];
          t2[k] = sp_q[k][2*pk + 1];
        end
      end
    end
  end

  tmds_encoder u_ch0 (
    .clk,
    .rst_n,
    .mode_i(m0),
    .d_i(rgb0[23:16]),
    .c_i(c0),
    .t_i(t0),
    .g_i(g0),
    .q_o(tmds0_o)
  );
  tmds_encoder u_ch1 (
    .clk,
    .rst_n,
    .mode_i(m1),
    .d_i(rgb0[15:8]),
    .c_i(c1),
    .t_i(t1),
    .g_i(g1),
    .q_o(tmds1_o)
  );
  tmds_encoder u_ch2 (
    .clk,
    .rst_n,
    .mode_i(m2),
    .d_i(rgb0[7:0]),
    .c_i(c2),
    .t_i(t2),
    .g_i(g2),
    .q_o(tmds2_o)
  );
endmodule
