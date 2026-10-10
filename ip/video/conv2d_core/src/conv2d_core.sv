// ***************
// Filename: conv2d_core.sv
// Author: FPGA Cores 4 U
// Description: Programmable N x N 2D convolution for AXI4-Stream video.
//   Version 1.0.0. isp_window builds the N x N neighbourhood of every
//   pixel (N-1 line buffers, BORDER rule at the frame edges) and a
//   4-stage multiply-accumulate pipeline computes, per colour component,
//     out = clamp((sum(k[i] * p[i]) + 2^(shift-1)) >>> shift, 0, 2^CW-1)
//   with signed COEF_W-bit coefficients k (coef_i[i*COEF_W +: COEF_W],
//   i = r*N + c, see conv2d_pkg) and shift 0..31 (no rounding term when 0).
//   The same kernel is applied to all C components. coef_i / shift_i are
//   sampled when a frame's first window is formed (R = (N-1)/2 lines after
//   its start-of-frame pixel) and held for the whole frame, so a kernel
//   change never splits a frame; the latency does not depend on the
//   kernel (an identity kernel is a pass-through with the same delay).
//   Pixels - s_axis_tdata component j in [j*CW +: CW]; tuser = SOF,
//   tlast = EOL. Frame size from width_i / height_i (>= R + 1, static
//   during a frame), see isp_window. Throughput - 1 pixel per clock (plus
//   isp_window's R idle cycles per line and R lines per frame).
//   sof_wait_o is isp_window's: while it is high and a start-of-frame
//   pixel is presented, a parent may switch width_i / height_i for the new
//   frame (no combinational path from s_axis_tready).
//   Resources - N*N*C multipliers (CW+1 x COEF_W bits). Clock - clk.
//   Reset - synchronous rst_n (active low). Latency - isp_window (R lines
//   + R + 1 clocks) + 4 clocks.
// Date: 2026-10-08
module conv2d_core #(
  parameter int N      = 5,                     // kernel size: 3 or 5
  parameter int C      = 3,                     // components per pixel
  parameter int CW     = 8,                     // component width
  parameter int COEF_W = 12,                    // signed coefficient width
  parameter int MAX_W  = 2048,                  // longest line
  parameter int BORDER = 0                      // 0 clamp to edge, 1 mirror (isp_window)
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic [15:0]             width_i,
  input  logic [15:0]             height_i,
  input  logic [N*N*COEF_W-1:0]   coef_i,
  input  logic [4:0]              shift_i,
  input  logic [C*CW-1:0]         s_axis_tdata,
  input  logic                    s_axis_tlast,
  input  logic                    s_axis_tuser,
  input  logic                    s_axis_tvalid,
  output logic                    s_axis_tready,
  output logic [C*CW-1:0]         m_axis_tdata,
  output logic                    m_axis_tlast,
  output logic                    m_axis_tuser,
  output logic                    m_axis_tvalid,
  input  logic                    m_axis_tready,
  output logic                    frame_o,          // pulse: a frame's kernel was taken
  output logic                    sof_wait_o        // between frames (isp_window), see below
);
  localparam int NN = N * N, PW = C * CW;
  localparam int PROD_W = CW + 1 + COEF_W;
  localparam int ACC_W  = PROD_W + $clog2(NN) + 1;
  if (N != 3 && N != 5) begin : g_bad_n $error("conv2d_core: N must be 3 or 5"); end

  // ---------------- window ----------------
  logic [NN*PW-1:0] w_d;
  logic w_l, w_u, w_v, w_r;
  isp_window #(
    .N(N),
    .PW(PW),
    .MAX_W(MAX_W),
    .BORDER(BORDER)
  ) u_win (
    .clk,
    .rst_n,
    .width_i,
    .height_i,
    .s_axis_tdata,
    .s_axis_tlast,
    .s_axis_tuser,
    .s_axis_tvalid,
    .s_axis_tready,
    .m_axis_tdata(w_d),
    .m_x(),
    .m_y(),
    .m_axis_tlast(w_l),
    .m_axis_tuser(w_u),
    .m_axis_tvalid(w_v),
    .m_axis_tready(w_r),
    .sof_wait_o
  );

  // ---------------- kernel, held per frame ----------------
  logic [NN*COEF_W-1:0] coef_q;
  logic [4:0] shift_q;
  wire                  take = w_v && w_r && w_u;
  wire [NN*COEF_W-1:0]  k    = w_u ? coef_i  : coef_q;   // the first window of a frame uses the new kernel
  wire [4:0]            ks   = w_u ? shift_i : shift_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      coef_q <= '0;
      shift_q <= '0;
    end
    else if (take) begin
      coef_q <= coef_i;
      shift_q <= shift_i;
    end
  end
  assign frame_o = take;

  // ---------------- MAC pipeline (all stages advance together) ----------------
  logic v1, v2, v3, v4, l1, l2, l3, l4, u1, u2, u3, u4;
  logic [4:0] s1, s2, s3;
  wire adv = !v4 || m_axis_tready;
  assign w_r = adv;

  logic signed [PROD_W-1:0] p1 [C*NN];             // products
  logic signed [ACC_W-1:0]  rs [C*N];              // row sums (combinational)
  logic signed [ACC_W-1:0]  r2 [C*N];
  logic signed [ACC_W-1:0]  ts [C];                // totals + rounding (combinational)
  logic signed [ACC_W-1:0]  a3 [C];
  logic [PW-1:0]            d4;

  function automatic logic [CW-1:0] clamp(input logic signed [ACC_W-1:0] v);
    if (v < 0) return '0;
    if (v > ACC_W'((1 << CW) - 1)) return {CW{1'b1}};
    return v[CW-1:0];
  endfunction

  always_comb begin
    for (int c = 0; c < C; c++)
      for (int r = 0; r < N; r++) begin
        rs[c*N + r] = '0;
        for (int j = 0; j < N; j++) rs[c*N + r] = rs[c*N + r] + ACC_W'(p1[c*NN + r*N + j]);
      end
    for (int c = 0; c < C; c++) begin
      ts[c] = (s2 != 0) ? (ACC_W'(1) <<< (s2 - 1)) : '0;
      for (int r = 0; r < N; r++) ts[c] = ts[c] + r2[c*N + r];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      {v1, v2, v3, v4} <= '0;
    end else if (adv) begin
      v1 <= w_v;
      v2 <= v1;
      v3 <= v2;
      v4 <= v3;
    end
  end

  always_ff @(posedge clk) begin
    if (adv) begin
      l1 <= w_l;
      u1 <= w_u;
      s1 <= ks;
      for (int c = 0; c < C; c++)
        for (int i = 0; i < NN; i++)
          p1[c*NN + i] <= $signed({1'b0, w_d[i*PW + c*CW +: CW]}) * $signed(k[i*COEF_W +: COEF_W]);
      l2 <= l1;
      u2 <= u1;
      s2 <= s1;
      for (int i = 0; i < C*N; i++) r2[i] <= rs[i];
      l3 <= l2;
      u3 <= u2;
      s3 <= s2;
      for (int c = 0; c < C; c++) a3[c] <= ts[c];
      l4 <= l3;
      u4 <= u3;
      for (int c = 0; c < C; c++) d4[c*CW +: CW] <= clamp(a3[c] >>> s3);
    end
  end

  assign m_axis_tdata  = d4;
  assign m_axis_tlast  = l4;
  assign m_axis_tuser  = u4;
  assign m_axis_tvalid = v4;
endmodule
