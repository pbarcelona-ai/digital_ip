// ***************
// Filename: isp_blc_wb.sv
// Author: FPGA Cores 4 U
// Description: Bayer-domain black level correction and white balance.
//   Version 1.0.0. For each RAW pixel of colour c (from the CFA phase):
//     black level:   v = max(raw - blc[c], 0)               (blc_bypass_i: v = raw)
//     white balance: out = min((v * gain[c] + 128) >> 8, 2^PW-1)
//                                                           (wb_bypass_i: out = v)
//   Colours c: 0 = R, 1 = Gr (green on a red row), 2 = Gb, 3 = B. blc_i holds
//   four PW-bit offsets, colour c in [c*PW +: PW]; gains are unsigned Q4.8
//   (256 = 1.0, max 15.996) for R, G (both greens) and B.
//   CFA pattern cfa_i: 0 RGGB, 1 GRBG, 2 GBRG, 3 BGGR (top-left 2x2).
//   The phase restarts at every tuser (SOF) and tlast (EOL) pixel. Bypass
//   bits and the pattern are sampled at the start of each frame, so a
//   change never splits a frame. Clock - clk only. Reset - synchronous
//   rst_n (active low). Latency - 2 clocks, 1 pixel per clock.
// Date: 2026-10-01
module isp_blc_wb #(
  parameter int PW = 10                        // RAW pixel width
) (
  input  logic            clk,
  input  logic            rst_n,
  input  logic [1:0]      cfa_i,
  input  logic            blc_bypass_i,
  input  logic            wb_bypass_i,
  input  logic [4*PW-1:0] blc_i,               // R, Gr, Gb, B offsets
  input  logic [11:0]     gain_r_i,            // Q4.8
  input  logic [11:0]     gain_g_i,
  input  logic [11:0]     gain_b_i,
  // RAW in
  input  logic [PW-1:0]   s_axis_tdata,
  input  logic            s_axis_tlast,
  input  logic            s_axis_tuser,
  input  logic            s_axis_tvalid,
  output logic            s_axis_tready,
  // RAW out
  output logic [PW-1:0]   m_axis_tdata,
  output logic            m_axis_tlast,
  output logic            m_axis_tuser,
  output logic            m_axis_tvalid,
  input  logic            m_axis_tready
);
  wire en = !m_axis_tvalid || m_axis_tready;   // whole pipeline advances together
  assign s_axis_tready = en;
  wire acc = s_axis_tvalid && en;

  // CFA phase of the incoming pixel and per-frame settings
  logic xo, yo;                                // x / y parity of the next pixel
  logic [1:0] cfa_f; logic blc_by_f, wb_by_f;
  wire  [1:0] cfa_now = s_axis_tuser ? cfa_i : cfa_f;
  wire        blc_by  = s_axis_tuser ? blc_bypass_i : blc_by_f;
  wire        wb_by   = s_axis_tuser ? wb_bypass_i  : wb_by_f;
  wire        px_x    = s_axis_tuser ? 1'b0 : xo;
  wire        px_y    = s_axis_tuser ? 1'b0 : yo;
  wire  [1:0] color   = {px_y ^ cfa_now[1], px_x ^ cfa_now[0]};

  // Stage 1: black level
  logic [PW-1:0] v1; logic [1:0] c1; logic wb1, l1, u1, val1;
  // Stage 2: white balance (output register)
  wire [11:0] g = (c1 == 2'd0) ? gain_r_i : (c1 == 2'd3) ? gain_b_i : gain_g_i;
  wire [PW+12:0] prod = v1 * g + 13'd128;
  wire [PW+4:0]  scaled = prod[PW+12:8];
  wire [PW-1:0]  wb_out = (scaled > {5'd0, {PW{1'b1}}}) ? {PW{1'b1}} : scaled[PW-1:0];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      xo <= 1'b0; yo <= 1'b0; cfa_f <= '0; blc_by_f <= 1'b0; wb_by_f <= 1'b0;
      val1 <= 1'b0; v1 <= '0; c1 <= '0; wb1 <= 1'b0; l1 <= 1'b0; u1 <= 1'b0;
      m_axis_tvalid <= 1'b0; m_axis_tdata <= '0; m_axis_tlast <= 1'b0; m_axis_tuser <= 1'b0;
    end else if (en) begin
      if (acc) begin
        if (s_axis_tuser) begin cfa_f <= cfa_i; blc_by_f <= blc_bypass_i; wb_by_f <= wb_bypass_i; end
        xo <= s_axis_tlast ? 1'b0 : ~px_x;
        yo <= s_axis_tlast ? ~px_y : px_y;
      end
      val1 <= acc; c1 <= color; wb1 <= wb_by; l1 <= s_axis_tlast; u1 <= s_axis_tuser;
      if (blc_by) v1 <= s_axis_tdata;
      else        v1 <= (s_axis_tdata > blc_i[color*PW +: PW]) ? s_axis_tdata - blc_i[color*PW +: PW] : '0;
      m_axis_tvalid <= val1; m_axis_tdata <= wb1 ? v1 : wb_out; m_axis_tlast <= l1; m_axis_tuser <= u1;
    end
  end
endmodule
