// ***************
// Filename: symbol_overlay_rows.sv
// Author: FPGA Cores 4 U
// Description: Row engine of symbol_overlay: for one row (start, row) it
//   computes every object's row data, the values the pixel logic compares
//   x against, exactly (integer arithmetic, no rounding):
//     ellipse (shape 3) in doubled coordinates, dy2 = 2 row - T2:
//       outer: valid when b^2 - dy2^2 >= 0, xo = isqrt((a^2 (b^2 - dy2^2))
//              div b^2): the ring's outer limit |dx2| <= xo, the same as
//              dx2^2 b^2 + dy2^2 a^2 <= a^2 b^2;
//       inner: valid when ai > 0, bi > 0 and bi^2 - dy2^2 > 0, xi =
//              isqrt((ai^2 (bi^2 - dy2^2) - 1) div bi^2): |dx2| <= xi
//              is dx2^2 bi^2 + dy2^2 ai^2 < ai^2 bi^2;
//     triangle, t = row - y0, valid when 0 <= t <= H: e(t) = W t div H (H =
//       0: W), L = (S2 - e) >> 1, R = (S2 + e + 1) >> 1, and Lp / Rp from
//       e(max(t - 1, 0)).
//   Four operations per object (outer, inner, e(t), e(t - 1)) enter one
//   pipeline, one per clock: squares, the product, a restoring divider
//   (2 CW + 1 quotient bits, one per stage) and an integer square root (CW
//   + 1 result bits, one per stage); results are written into the row data
//   registers as they leave it. busy from start until the last result is
//   written (4 NOBJ + 4 + 2 CW + 1 + CW + 1 + 1 clocks); done then, held
//   until the next start. The per-object inputs must not change while
//   busy. Clock - clk. Reset - synchronous active low rst_n (idle, done
//   low).
// Date: 2026-10-20
module symbol_overlay_rows #(
  parameter int NOBJ = 4,
  parameter int CW   = 13
) (
  input  logic                    clk,
  input  logic                    rst_n,
  input  logic                    start,         // pulse: compute row (ignored while busy)
  input  logic [CW-1:0]           row,
  output logic                    busy,
  output logic                    done,
  // per object k at [k*(CW+1) +: CW+1] / [k*CW +: CW]
  input  logic [NOBJ*(CW+1)-1:0]  a_i,            // ellipse axes (doubled-coordinate lengths)
  input  logic [NOBJ*(CW+1)-1:0]  b_i,
  input  logic [NOBJ*(CW+1)-1:0]  ai_i,           // inner ellipse axes (0: no inner ellipse)
  input  logic [NOBJ*(CW+1)-1:0]  bi_i,
  input  logic [NOBJ*(CW+1)-1:0]  s2_i,           // x0 + x1
  input  logic [NOBJ*(CW+1)-1:0]  t2_i,           // y0 + y1
  input  logic [NOBJ*CW-1:0]      y0_i,
  input  logic [NOBJ*CW-1:0]      w_i,            // x1 - x0 (x0 <= x1)
  input  logic [NOBJ*CW-1:0]      h_i,            // y1 - y0 (y0 <= y1)
  output logic [NOBJ*(CW+1)-1:0]  xo_o,
  output logic [NOBJ-1:0]         xo_v,
  output logic [NOBJ*(CW+1)-1:0]  xi_o,
  output logic [NOBJ-1:0]         xi_v,
  output logic [NOBJ*CW-1:0]      l_o,
  output logic [NOBJ*CW-1:0]      r_o,
  output logic [NOBJ*CW-1:0]      lp_o,
  output logic [NOBJ*CW-1:0]      rp_o,
  output logic [NOBJ-1:0]         tv_o
);
  if (NOBJ < 1 || NOBJ > 32) begin : g_bad_nobj $error("symbol_overlay_rows: NOBJ must be 1..32"); end
  localparam int OW  = (NOBJ > 1) ? $clog2(NOBJ) : 1;
  localparam int NOP = 4 * NOBJ;
  localparam int CNW = $clog2(NOP + 1);
  localparam int SW  = CW + 1;                   // axis / sum width
  localparam int SQ  = 2 * CW + 1;               // squares of the axes (<= 2**(2 CW))
  localparam int NW  = 4 * CW + 1;               // numerator
  localparam int QW  = 2 * CW + 1;               // quotient
  localparam int RW  = SQ + 1;                   // divider partial remainder
  localparam int QP  = QW + 1;                   // square root input, even width
  localparam int RT  = QP / 2;                   // square root result (CW + 1 bits)
  localparam int DY  = CW + 3;                   // signed dy2 / t

  // ---------------- issue: one operation per clock ----------------
  logic [CNW-1:0] cnt;
  logic issuing;
  logic [CW-1:0] row_q;
  wire [OW-1:0] i_o  = OW'(cnt >> 2);
  wire [1:0]    i_op = cnt[1:0];
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cnt <= '0;
      issuing <= 1'b0;
      row_q <= '0;
    end else if (start && !busy) begin
      cnt <= '0;
      issuing <= 1'b1;
      row_q <= row;
    end else if (issuing) begin
      if (cnt == CNW'(NOP - 1)) issuing <= 1'b0;
      cnt <= cnt + 1'b1;
    end
  end

  // ---------------- stage 1: operands ----------------
  wire [SW-1:0] i_a  = a_i[i_o*SW +: SW];
  wire [SW-1:0] i_b  = b_i[i_o*SW +: SW];
  wire [SW-1:0] i_ai = ai_i[i_o*SW +: SW];
  wire [SW-1:0] i_bi = bi_i[i_o*SW +: SW];
  wire [SW-1:0] i_t2 = t2_i[i_o*SW +: SW];
  wire [CW-1:0] i_y0 = y0_i[i_o*CW +: CW];
  wire [CW-1:0] i_h  = h_i[i_o*CW +: CW];
  wire signed [DY-1:0] i_t = $signed(DY'(row_q)) - $signed(DY'(i_y0));
  logic          s1_v, s1_e, s1_tv;              // valid, ellipse operation enabled, triangle row valid
  logic [OW-1:0] s1_o;
  logic [1:0]    s1_op;
  logic [SW-1:0] s1_sa, s1_sb;
  logic signed [DY-1:0] s1_dy2, s1_t;
  logic [CW-1:0] s1_w, s1_h;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s1_v <= 1'b0;
      s1_e <= 1'b0;
      s1_tv <= 1'b0;
      s1_o <= '0;
      s1_op <= '0;
      s1_sa <= '0;
      s1_sb <= '0;
      s1_dy2 <= '0;
      s1_t <= '0;
      s1_w <= '0;
      s1_h <= '0;
    end else begin
      s1_v <= issuing;
      s1_o <= i_o;
      s1_op <= i_op;
      s1_sa <= i_op[0] ? i_ai : i_a;
      s1_sb <= i_op[0] ? i_bi : i_b;
      s1_e <= !i_op[0] || (i_ai != '0 && i_bi != '0);
      s1_dy2 <= $signed(DY'({row_q, 1'b0})) - $signed(DY'(i_t2));
      s1_tv <= i_t >= 0 && i_t <= $signed(DY'(i_h));
      s1_t <= (i_op[0] && i_t > 0) ? i_t - 1'b1 : i_t;   // e(t - 1) for operation 3 (t = 0: e(0))
      s1_w <= w_i[i_o*CW +: CW];
      s1_h <= i_h;
    end
  end

  // ---------------- stage 2: squares ----------------
  logic          s2_v, s2_e, s2_tv;
  logic [OW-1:0] s2_o;
  logic [1:0]    s2_op;
  logic [SQ-1:0] s2_qa, s2_qb;
  logic [2*DY-1:0] s2_qdy;
  logic [CW-1:0] s2_w, s2_h;
  logic [CW-1:0] s2_t;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s2_v <= 1'b0;
      s2_e <= 1'b0;
      s2_tv <= 1'b0;
      s2_o <= '0;
      s2_op <= '0;
      s2_qa <= '0;
      s2_qb <= '0;
      s2_qdy <= '0;
      s2_w <= '0;
      s2_h <= '0;
      s2_t <= '0;
    end else begin
      s2_v <= s1_v;
      s2_e <= s1_e;
      s2_tv <= s1_tv;
      s2_o <= s1_o;
      s2_op <= s1_op;
      s2_qa <= SQ'(s1_sa * s1_sa);
      s2_qb <= SQ'(s1_sb * s1_sb);
      s2_qdy <= (2*DY)'(s1_dy2 * s1_dy2);
      s2_w <= s1_w;
      s2_h <= s1_h;
      s2_t <= s1_t[CW-1:0];                      // used only when 0 <= t <= H
    end
  end

  // ---------------- stage 3: the ellipse's row term, the triangle's product ----------------
  logic          s3_v, s3_ok;
  logic [OW-1:0] s3_o;
  logic [1:0]    s3_op;
  logic [SQ-1:0] s3_qa, s3_diff, s3_den;
  logic [2*CW-1:0] s3_wt;
  logic [CW-1:0] s3_w, s3_h;
  wire signed [2*DY:0] s2_d = $signed({1'b0, (2*DY)'(s2_qb)}) - $signed({1'b0, s2_qdy});
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s3_v <= 1'b0;
      s3_ok <= 1'b0;
      s3_o <= '0;
      s3_op <= '0;
      s3_qa <= '0;
      s3_diff <= '0;
      s3_den <= '0;
      s3_wt <= '0;
      s3_w <= '0;
      s3_h <= '0;
    end else begin
      s3_v <= s2_v;
      s3_o <= s2_o;
      s3_op <= s2_op;
      s3_qa <= s2_qa;
      s3_den <= s2_qb;
      s3_diff <= (s2_d > 0) ? SQ'(s2_d) : '0;
      // outer: b^2 - dy2^2 >= 0; inner: > 0 (and both inner axes non-zero); triangle: the row in the box
      s3_ok <= s2_op[1] ? s2_tv : (s2_e && (s2_op[0] ? s2_d > 0 : s2_d >= 0));
      s3_wt <= (2*CW)'(s2_w * s2_t);
      s3_w <= s2_w;
      s3_h <= s2_h;
    end
  end

  // ---------------- stage 4: numerator and divisor ----------------
  logic          s4_v, s4_ok, s4_byp;
  logic [OW-1:0] s4_o;
  logic [1:0]    s4_op;
  logic [NW-1:0] s4_num;
  logic [SQ-1:0] s4_den;
  logic [CW-1:0] s4_w;
  wire  [NW-1:0] s3_p = NW'(s3_qa * s3_diff);
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      s4_v <= 1'b0;
      s4_ok <= 1'b0;
      s4_byp <= 1'b0;
      s4_o <= '0;
      s4_op <= '0;
      s4_num <= '0;
      s4_den <= '0;
      s4_w <= '0;
    end else begin
      s4_v <= s3_v;
      s4_ok <= s3_ok;
      s4_o <= s3_o;
      s4_op <= s3_op;
      s4_w <= s3_w;
      if (s3_op[1]) begin                        // triangle: W t div H (H = 0: W)
        s4_num <= NW'(s3_wt);
        s4_den <= SQ'(s3_h);
        s4_byp <= s3_h == '0;
      end else begin                             // ellipse: a^2 (b^2 - dy2^2) div b^2, inner - 1
        s4_num <= (s3_op[0] && s3_ok) ? s3_p - 1'b1 : s3_p;
        s4_den <= s3_den;
        s4_byp <= 1'b0;
      end
    end
  end

  // ---------------- divider: QW stages, one quotient bit each ----------------
  // stage i takes stage i - 1's registers (stage 0: stage 4's) and registers its result
  for (genvar i = 0; i < QW; i++) begin : g_div
    logic          v_i, ok_i, byp_i, v_q, ok_q, byp_q;
    logic [OW-1:0] o_i, o_q;
    logic [1:0]    op_i, op_q;
    logic [RW-1:0] rem_i, rem_q;
    logic [QW-1:0] lo_i, lo_q;                   // numerator bits still to bring in (top first)
    logic [QW-1:0] q_i, q_q;
    logic [SQ-1:0] den_i, den_q;
    logic [CW-1:0] wd_i, wd_q;
    if (i == 0) begin : g_in
      assign v_i = s4_v;
      assign ok_i = s4_ok;
      assign byp_i = s4_byp;
      assign o_i = s4_o;
      assign op_i = s4_op;
      assign rem_i = RW'(s4_num >> QW);
      assign lo_i = s4_num[QW-1:0];
      assign q_i = '0;
      assign den_i = s4_den;
      assign wd_i = s4_w;
    end else begin : g_in
      assign v_i = g_div[i-1].v_q;
      assign ok_i = g_div[i-1].ok_q;
      assign byp_i = g_div[i-1].byp_q;
      assign o_i = g_div[i-1].o_q;
      assign op_i = g_div[i-1].op_q;
      assign rem_i = g_div[i-1].rem_q;
      assign lo_i = g_div[i-1].lo_q;
      assign q_i = g_div[i-1].q_q;
      assign den_i = g_div[i-1].den_q;
      assign wd_i = g_div[i-1].wd_q;
    end
    wire unused_top = &{1'b0, q_i[QW-1], 1'b0};    // shifted out (the quotient fits in QW bits)
    wire [RW:0] r2 = {rem_i, lo_i[QW-1]};
    wire ge = r2 >= (RW+1)'(den_i);
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        v_q <= 1'b0;
        ok_q <= 1'b0;
        byp_q <= 1'b0;
        o_q <= '0;
        op_q <= '0;
        rem_q <= '0;
        lo_q <= '0;
        q_q <= '0;
        den_q <= '0;
        wd_q <= '0;
      end else begin
        v_q <= v_i;
        ok_q <= ok_i;
        byp_q <= byp_i;
        o_q <= o_i;
        op_q <= op_i;
        rem_q <= RW'(ge ? r2 - (RW+1)'(den_i) : r2);
        lo_q <= {lo_i[QW-2:0], 1'b0};
        q_q <= {q_i[QW-2:0], ge};
        den_q <= den_i;
        wd_q <= wd_i;
      end
    end
  end

  // ---------------- integer square root: RT stages, one result bit each ----------------
  for (genvar i = 0; i < RT; i++) begin : g_sqrt
    logic          v_i, ok_i, v_q, ok_q;
    logic [OW-1:0] o_i, o_q;
    logic [1:0]    op_i, op_q;
    logic [QP-1:0] in_i, in_q;                   // radicand bits still to bring in (top pair first)
    logic [RT+1:0] rem_i, rem_q;
    logic [RT-1:0] root_i, root_q;
    logic [QW-1:0] q_i, q_q;                     // the quotient itself (triangle operations)
    if (i == 0) begin : g_in
      assign v_i = g_div[QW-1].v_q;
      assign ok_i = g_div[QW-1].ok_q;
      assign o_i = g_div[QW-1].o_q;
      assign op_i = g_div[QW-1].op_q;
      assign in_i = QP'(g_div[QW-1].q_q);
      assign rem_i = '0;
      assign root_i = '0;
      assign q_i = g_div[QW-1].byp_q ? QW'(g_div[QW-1].wd_q) : g_div[QW-1].q_q;
    end else begin : g_in
      assign v_i = g_sqrt[i-1].v_q;
      assign ok_i = g_sqrt[i-1].ok_q;
      assign o_i = g_sqrt[i-1].o_q;
      assign op_i = g_sqrt[i-1].op_q;
      assign in_i = g_sqrt[i-1].in_q;
      assign rem_i = g_sqrt[i-1].rem_q;
      assign root_i = g_sqrt[i-1].root_q;
      assign q_i = g_sqrt[i-1].q_q;
    end
    wire [RT+3:0] r4 = {rem_i, in_i[QP-1 -: 2]};
    wire [RT+3:0] tst = (RT+4)'({root_i, 2'b01});
    wire ge = r4 >= tst;
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        v_q <= 1'b0;
        ok_q <= 1'b0;
        o_q <= '0;
        op_q <= '0;
        in_q <= '0;
        rem_q <= '0;
        root_q <= '0;
        q_q <= '0;
      end else begin
        v_q <= v_i;
        ok_q <= ok_i;
        o_q <= o_i;
        op_q <= op_i;
        in_q <= {in_i[QP-3:0], 2'b00};
        rem_q <= (RT+2)'(ge ? r4 - tst : r4);
        root_q <= {root_i[RT-2:0], ge};
        q_q <= q_i;
      end
    end
  end

  // ---------------- write back ----------------
  wire          wb_v  = g_sqrt[RT-1].v_q;
  wire          wb_ok = g_sqrt[RT-1].ok_q;
  wire [OW-1:0] wb_o  = g_sqrt[RT-1].o_q;
  wire [1:0]    wb_op = g_sqrt[RT-1].op_q;
  wire [SW-1:0] wb_root = SW'(g_sqrt[RT-1].root_q);
  wire [SW-1:0] wb_s2 = s2_i[wb_o*SW +: SW];
  wire [CW:0]   wb_e = (CW+1)'(g_sqrt[RT-1].q_q);
  // L and R lie in [x0, x1] when the row is valid (CW bits); the top bits are only set otherwise
  wire [CW+1:0] wb_l = ((CW+2)'(wb_s2) - (CW+2)'(wb_e)) >> 1;
  wire [CW+1:0] wb_r = ((CW+2)'(wb_s2) + (CW+2)'(wb_e) + 1'b1) >> 1;
  wire          unused_ok = &{1'b0, s1_t[DY-1:CW], wb_l[CW+1:CW], wb_r[CW+1:CW], g_div[QW-1].rem_q,
                              g_div[QW-1].lo_q, g_div[QW-1].den_q, g_sqrt[RT-1].in_q, g_sqrt[RT-1].rem_q,
                              g_sqrt[RT-1].q_q[QW-1:CW+1], 1'b0};    // e <= W: CW + 1 bits
  logic [CNW-1:0] wcnt;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wcnt <= '0;
      busy <= 1'b0;
      done <= 1'b0;
      xo_o <= '0;
      xo_v <= '0;
      xi_o <= '0;
      xi_v <= '0;
      l_o <= '0;
      r_o <= '0;
      lp_o <= '0;
      rp_o <= '0;
      tv_o <= '0;
    end else begin
      if (start && !busy) begin
        busy <= 1'b1;
        done <= 1'b0;
        wcnt <= '0;
      end else if (wb_v) begin
        if (wcnt == CNW'(NOP - 1)) begin
          busy <= 1'b0;
          done <= 1'b1;
        end
        wcnt <= wcnt + 1'b1;
      end
      if (wb_v) begin
        case (wb_op)
          2'd0: begin
            xo_o[wb_o*SW +: SW] <= wb_root;
            xo_v[wb_o] <= wb_ok;
          end
          2'd1: begin
            xi_o[wb_o*SW +: SW] <= wb_root;
            xi_v[wb_o] <= wb_ok;
          end
          2'd2: begin
            l_o[wb_o*CW +: CW] <= CW'(wb_l);
            r_o[wb_o*CW +: CW] <= CW'(wb_r);
            tv_o[wb_o] <= wb_ok;
          end
          default: begin
            lp_o[wb_o*CW +: CW] <= CW'(wb_l);
            rp_o[wb_o*CW +: CW] <= CW'(wb_r);
          end
        endcase
      end
    end
  end
endmodule
