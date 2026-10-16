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
//   rst_n (active low). Latency - 5 clocks, 1 pixel per clock. The output goes through a 2-entry ip_axis_fifo, so s_axis_tready does
//   not depend combinationally on m_axis_tready (+3 clocks).
// Date: 2026-10-16
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
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = PW
  axis_if.slave s_axis,
  // RAW out
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = PW
  axis_if.master m_axis
);
  // output stage: the last pipeline register (q_*) feeds a 2-entry FIFO whose ready is registered,
  // so s_axis_tready does not depend combinationally on m_axis_tready
  logic [PW-1:0] q_d;
  logic q_l, q_u, q_v, q_r;
  wire en = !q_v || q_r;   // whole pipeline advances together
  assign s_axis.tready = en;
  wire acc = s_axis.tvalid && en;

  // CFA phase of the incoming pixel and per-frame settings
  logic xo, yo;                                // x / y parity of the next pixel
  logic [1:0] cfa_f;
  logic blc_by_f, wb_by_f;
  wire  [1:0] cfa_now = s_axis.tuser ? cfa_i : cfa_f;
  wire        blc_by  = s_axis.tuser ? blc_bypass_i : blc_by_f;
  wire        wb_by   = s_axis.tuser ? wb_bypass_i  : wb_by_f;
  wire        px_x    = s_axis.tuser ? 1'b0 : xo;
  wire        px_y    = s_axis.tuser ? 1'b0 : yo;
  wire  [1:0] color   = {px_y ^ cfa_now[1], px_x ^ cfa_now[0]};

  // Stage 1: black level
  logic [PW-1:0] v1;
  logic [1:0] c1;
  logic wb1, l1, u1, val1;
  // Stage 2: white balance (output register)
  wire [11:0] g = (c1 == 2'd0) ? gain_r_i : (c1 == 2'd3) ? gain_b_i : gain_g_i;
  wire [PW+12:0] prod = v1 * g + 13'd128;
  wire [PW+4:0]  scaled = prod[PW+12:8];
  wire [PW-1:0]  wb_out = (scaled > {5'd0, {PW{1'b1}}}) ? {PW{1'b1}} : scaled[PW-1:0];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      xo <= 1'b0;
      yo <= 1'b0;
      cfa_f <= '0;
      blc_by_f <= 1'b0;
      wb_by_f <= 1'b0;
      val1 <= 1'b0;
      v1 <= '0;
      c1 <= '0;
      wb1 <= 1'b0;
      l1 <= 1'b0;
      u1 <= 1'b0;
      q_v <= 1'b0;
      q_d <= '0;
      q_l <= 1'b0;
      q_u <= 1'b0;
    end else if (en) begin
      if (acc) begin
        if (s_axis.tuser) begin
          cfa_f <= cfa_i;
          blc_by_f <= blc_bypass_i;
          wb_by_f <= wb_bypass_i;
        end
        xo <= s_axis.tlast ? 1'b0 : ~px_x;
        yo <= s_axis.tlast ? ~px_y : px_y;
      end
      val1 <= acc;
      c1 <= color;
      wb1 <= wb_by;
      l1 <= s_axis.tlast;
      u1 <= s_axis.tuser;
      if (blc_by) v1 <= s_axis.tdata;
      else        v1 <= (s_axis.tdata > blc_i[color*PW +: PW]) ? s_axis.tdata - blc_i[color*PW +: PW] : '0;
      q_v <= val1;
      q_d <= wb1 ? v1 : wb_out;
      q_l <= l1;
      q_u <= u1;
    end
  end
  axis_if #(.DATA_W(PW)) u_out_fifo_s ();
  assign u_out_fifo_s.tdata = q_d;
  assign u_out_fifo_s.tlast = q_l;
  assign u_out_fifo_s.tuser = q_u;
  assign u_out_fifo_s.tvalid = q_v;
  assign q_r = u_out_fifo_s.tready;
  ip_axis_fifo #(
    .DATA_W(PW),
    .DEPTH(2)
  ) u_out_fifo (
    .clk,
    .rst_n,
    .s(u_out_fifo_s),
    .m(m_axis),
    .level_o()
  );
endmodule
