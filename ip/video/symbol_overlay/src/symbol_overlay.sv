// ***************
// Filename: symbol_overlay.sv
// Author: FPGA Cores 4 U
// Description: Symbol overlay for an AXI4-Stream video (24-bit pixels,
//   tuser = start of frame, tlast = end of line). Version 2.0.0 (the VERSION
//   register). Draws, as the video streams through (no frame buffer), up to
//   NOBJ objects (each a symbol and a label of up to 4 characters) and NTXT
//   texts. Golden model: ip/video/symbol_overlay/model/symbol_overlay_model.py
//   (its header is the full definition of every symbol, label and text;
//   the output frames are bit exact, tb/python).
//   Layers of a pixel: the symbol of the lowest-index enabled object that
//   covers it (its colour, or with BLEND the 50 % mix with the video), then
//   the label of the lowest-index object whose label cells cover it
//   (backdrop: the pixel halved, then the glyph), then the text of lowest
//   index covering it (halved with BACKDROP, then the glyph). Symbols:
//   rectangle outline (dashed, solid CORNERS, TICKS), filled box,
//   crosshair, circle / oval (an exact integer ellipse ring in doubled
//   coordinates), triangle (TRIANGLE: integer edges, dashed with solid
//   vertices). Glyphs: the 3 x 5 font (overlay_font_pkg) at 1x / 2x / 4x /
//   8x, or with CTRL.FONT at 2x and larger the smooth font (4-bit coverage
//   ROMs overlay_font_aa_s<S>.mem in FONT_DIR: v = (v (15 - a) + c a + 7) /
//   15). Texts may end with the frame number (5 BCD digits).
//   Updates: the CPU writes registers in any order, then COMMIT; the next
//   frame start takes a snapshot of every object / text register and CTRL's
//   LABEL_SCALE / FONT (STATUS[0] pending until then; a COMMIT in the clock
//   of the snapshot waits for the following frame). CTRL.ENABLE is taken at
//   every frame start (clear: the video passes unchanged). FRAME_NUM: a
//   write sets the number of the next frame, otherwise each frame start
//   adds one (BCD); reads return the current frame's number.
//   Labels are placed with the size of the frame before the commit is
//   applied (2**CW - 1 before the first frame): centred under the symbol
//   inb the frame width, above the symbol when they would crs the
//   frame's bottom.
//   Timing: at a frame start the stream is held (s_axis.tready low) until
//   the pipeline has drained, the snapshot is prepared (2 clocks) and row 0
//   is computed (the row engine symbol_overlay_rows, about 4 NOBJ + 3 CW + 7
//   clocks); the next row is computed while a row streams, and the first
//   beat of a row waits one clock to take it (or longer when a row is
//   shorter than the row engine's time). Pipeline latency 4 clocks, full
//   back-pressure. The output pixels do not depend on the timing.
//   Limits: frame width and height below 2**CW; coordinates are CW bits.
//   Registers on the cfg_* / sts_* ports; symbol_overlay_top.sv is the block
//   with its AXI4-Lite register map (src/include/symbol_overlay_regs.sv,
//   ADDR_W = 10): ID "SOVL" / VERSION / DATE at 0x00-0x08, CTRL 0x18, COMMIT
//   0x1C, STATUS 0x20, FRAME_NUM 0x24, objects 0-15 OBJ_CTRL / OBJ_X / OBJ_Y
//   / OBJ_COLOR at 0x50 + 16 i, OBJ_LABEL at 0x260 + 4 i, objects 16-31 at
//   0x2A0 + 16 (i - 16) and their labels at 0x3A0 + 4 (i - 16), texts j
//   TXT_CTRL / TXT_POS / TXT_COLOR at 0x150 + 16 j, TXT_CHARS at 0x210 + 16 j.
//   Clock - clk (pixel clock). Reset - synchronous active low rst_n.
// Date: 2026-10-20
module symbol_overlay #(
  parameter int NOBJ     = 4,                     // objects (1..32)
  parameter int NTXT     = 4,                     // texts (0..4)
  parameter int CW       = 13,                    // coordinate bits (8..15)
  parameter     FONT_DIR = ""                     // directory of overlay_font_aa_s<S>.mem, with a trailing /
) (
  input  logic        clk,
  input  logic        rst_n,
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = 24
  axis_if.slave s_axis,
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = 24
  axis_if.master m_axis,
  // register ports
  // regs: symbol_overlay_regs_if.core (src/include/symbol_overlay_regs_if.sv)
  symbol_overlay_regs_if.core regs
);
  if (NOBJ < 1 || NOBJ > 32) begin : g_bad_nobj $error("symbol_overlay: NOBJ must be 1..32"); end
  if (NTXT < 0 || NTXT > 4) begin : g_bad_ntxt $error("symbol_overlay: NTXT must be 0..4"); end
  if (CW < 8 || CW > 15) begin : g_bad_cw $error("symbol_overlay: CW must be 8..15"); end
  assign m_axis.tkeep = '1;      // not used by this block

  localparam int NT = (NTXT < 1) ? 1 : NTXT;     // storage for at least one text (unused when NTXT = 0)
  localparam int OW = (NOBJ > 1) ? $clog2(NOBJ) : 1;
  localparam int TW = (NT > 1) ? $clog2(NT) : 1;
  localparam int SG = CW + 4;                    // signed coordinate arithmetic
  localparam int SW = CW + 1;
  localparam int KW = $clog2(SG);                // bit index into a coordinate
  typedef logic signed [SG-1:0] sc_t;

  // ================================================================ registers
  logic [3:0]  ctrl;
  logic        commit_set, fnum_wr;
  logic [19:0] fnum_d;
  logic [15:0] l_ctrl [NOBJ];                    // live object registers (both banks)
  logic [31:0] l_x [NOBJ], l_y [NOBJ], l_lab [NOBJ];
  logic [23:0] l_col [NOBJ];
  assign ctrl = regs.cfg_ctrl;
  assign commit_set = regs.cfg_commit_wr && regs.cfg_commit;
  assign fnum_d = regs.cfg_frame_num;
  assign fnum_wr = regs.cfg_frame_num_wr;
  for (genvar k = 0; k < NOBJ; k++) begin : g_live
    if (k < 16) begin : g_b1
      assign l_ctrl[k] = regs.cfg_obj_ctrl[k*32 +: 16];
      assign l_x[k] = regs.cfg_obj_x[k*32 +: 32];
      assign l_y[k] = regs.cfg_obj_y[k*32 +: 32];
      assign l_col[k] = regs.cfg_obj_color[k*24 +: 24];
      assign l_lab[k] = regs.cfg_obj_label[k*32 +: 32];
    end else begin : g_b2
      assign l_ctrl[k] = regs.cfg_obj2_ctrl[(k-16)*32 +: 16];
      assign l_x[k] = regs.cfg_obj2_x[(k-16)*32 +: 32];
      assign l_y[k] = regs.cfg_obj2_y[(k-16)*32 +: 32];
      assign l_col[k] = regs.cfg_obj2_color[(k-16)*24 +: 24];
      assign l_lab[k] = regs.cfg_obj2_label[(k-16)*32 +: 32];
    end
  end
  // values the logic does not use: write pulses (registers act by value), OBJ_CTRL [31:16], the
  // coordinates' bits above CW, TXT_CTRL / TXT_POS upper bits, the second bank when NOBJ <= 16
  wire unused_ok = &{1'b0, regs.cfg_ctrl_wr, regs.cfg_obj_ctrl_wr, regs.cfg_obj_x_wr, regs.cfg_obj_y_wr,
                     regs.cfg_obj_color_wr, regs.cfg_obj_label_wr, regs.cfg_obj2_ctrl_wr, regs.cfg_obj2_x_wr,
                     regs.cfg_obj2_y_wr, regs.cfg_obj2_color_wr, regs.cfg_obj2_label_wr, regs.cfg_txt_ctrl_wr,
                     regs.cfg_txt_pos_wr, regs.cfg_txt_color_wr, regs.cfg_txt_chars_wr, regs.cfg_obj_ctrl,
                     regs.cfg_obj_x, regs.cfg_obj_y, regs.cfg_obj2_ctrl, regs.cfg_obj2_x, regs.cfg_obj2_y,
                     regs.cfg_obj2_color, regs.cfg_obj2_label, regs.cfg_txt_ctrl, regs.cfg_txt_pos, 1'b0};

  // ================================================================ state
  logic        pending, act_en, seen, applied;
  logic [15:0] frames;
  logic [19:0] fnum, fnum_set;
  logic        fnum_pend;
  logic [CW-1:0] wf, hf, w_meas;                 // size of the last frame; the first line's length
  // the snapshot (the active set)
  logic [15:0] a_ctrl [NOBJ];
  logic [CW-1:0] a_x0 [NOBJ], a_x1 [NOBJ], a_y0 [NOBJ], a_y1 [NOBJ];
  logic [23:0] a_col [NOBJ];
  logic [31:0] a_lab [NOBJ];
  logic [1:0]  a_ls;                             // LABEL_SCALE
  logic        a_font;
  logic [12:0] t_ctrl [NT];
  logic [CW-1:0] t_x [NT], t_y [NT];
  logic [23:0] t_color [NT];
  logic [127:0] t_chars [NT];
  // prepared values
  logic [2:0]  lab_n [NOBJ];
  sc_t         lab_x [NOBJ], lab_y [NOBJ], lab_xe [NOBJ], lab_ye [NOBJ];
  logic [CW-1:0] o_cl [NOBJ];
  logic [SW-1:0] e_a [NOBJ], e_b [NOBJ], e_ai [NOBJ], e_bi [NOBJ];
  logic [4:0]  txt_n [NT];
  sc_t         txt_xe [NT], txt_ye [NT];

  // ================================================================ position of the presented beat
  logic [CW-1:0] x, y;
  wire  [CW-1:0] px = s_axis.tuser ? '0 : x;
  wire  [CW-1:0] py = s_axis.tuser ? '0 : y;

  // ================================================================ row engine and the current row's data
  logic          eng_start, eng_busy, eng_done;
  logic [CW-1:0] eng_row;                        // the row the engine computes / computed
  logic [NOBJ*SW-1:0] p_a, p_b, p_ai, p_bi, p_s2, p_t2;
  logic [NOBJ*CW-1:0] p_y0, p_w, p_h;
  logic [NOBJ*SW-1:0] n_xo, n_xi;
  logic [NOBJ-1:0]    n_xov, n_xiv, n_tv;
  logic [NOBJ*CW-1:0] n_l, n_r, n_lp, n_rp;
  for (genvar k = 0; k < NOBJ; k++) begin : g_eng_in
    assign p_a[k*SW +: SW] = e_a[k];
    assign p_b[k*SW +: SW] = e_b[k];
    assign p_ai[k*SW +: SW] = e_ai[k];
    assign p_bi[k*SW +: SW] = e_bi[k];
    assign p_s2[k*SW +: SW] = SW'(a_x0[k]) + SW'(a_x1[k]);
    assign p_t2[k*SW +: SW] = SW'(a_y0[k]) + SW'(a_y1[k]);
    assign p_y0[k*CW +: CW] = a_y0[k];
    assign p_w[k*CW +: CW] = a_x1[k] - a_x0[k];
    assign p_h[k*CW +: CW] = a_y1[k] - a_y0[k];
  end
  symbol_overlay_rows #(
    .NOBJ(NOBJ),
    .CW(CW)
  ) u_rows (
    .clk,
    .rst_n,
    .start(eng_start),
    .row(eng_row),
    .busy(eng_busy),
    .done(eng_done),
    .a_i(p_a),
    .b_i(p_b),
    .ai_i(p_ai),
    .bi_i(p_bi),
    .s2_i(p_s2),
    .t2_i(p_t2),
    .y0_i(p_y0),
    .w_i(p_w),
    .h_i(p_h),
    .xo_o(n_xo),
    .xo_v(n_xov),
    .xi_o(n_xi),
    .xi_v(n_xiv),
    .l_o(n_l),
    .r_o(n_r),
    .lp_o(n_lp),
    .rp_o(n_rp),
    .tv_o(n_tv)
  );
  logic [NOBJ*SW-1:0] c_xo, c_xi;                // the current row's data
  logic [NOBJ-1:0]    c_xov, c_xiv, c_tv;
  logic [NOBJ*CW-1:0] c_l, c_r, c_lp, c_rp;
  logic [CW-1:0]      cur_row;

  // ================================================================ frame start / row control
  typedef enum logic [2:0] {F_RUN, F_START, F_PREP, F_ROW0, F_WAIT0} fst_e;
  fst_e fst;
  logic fs_done;                                 // the presented frame start is prepared
  logic p1_v, p2_v, p3_v;                        // pixel pipeline stages hold a beat
  wire  need_fs  = s_axis.tvalid && s_axis.tuser && !fs_done;
  wire  need_row = s_axis.tvalid && !s_axis.tuser && px == '0 && cur_row != py;
  wire  adv;                                     // the pixel pipeline moves
  assign s_axis.tready = adv && fst == F_RUN && !need_fs && !need_row;
  wire  in_beat = s_axis.tvalid && s_axis.tready;
  wire  drained = !p1_v && !p2_v && !p3_v;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fst <= F_RUN;
      fs_done <= 1'b0;
      eng_start <= 1'b0;
      eng_row <= '0;
      cur_row <= '0;
      c_xo <= '0;
      c_xi <= '0;
      c_xov <= '0;
      c_xiv <= '0;
      c_tv <= '0;
      c_l <= '0;
      c_r <= '0;
      c_lp <= '0;
      c_rp <= '0;
      pending <= 1'b0;
      act_en <= 1'b0;
      seen <= 1'b0;
      applied <= 1'b0;
      frames <= '0;
      fnum <= '0;
      fnum_set <= '0;
      fnum_pend <= 1'b0;
      wf <= '1;
      hf <= '1;
      a_ls <= '0;
      a_font <= 1'b0;
      for (int k = 0; k < NOBJ; k++) begin
        a_ctrl[k] <= '0;
        a_x0[k] <= '0;
        a_x1[k] <= '0;
        a_y0[k] <= '0;
        a_y1[k] <= '0;
        a_col[k] <= '0;
        a_lab[k] <= '0;
      end
      for (int j = 0; j < NT; j++) begin
        t_ctrl[j] <= '0;
        t_x[j] <= '0;
        t_y[j] <= '0;
        t_color[j] <= '0;
        t_chars[j] <= '0;
      end
    end else begin
      eng_start <= 1'b0;
      if (commit_set) pending <= 1'b1;
      if (fnum_wr) begin
        fnum_set <= fnum_d;
        fnum_pend <= 1'b1;
      end
      if (in_beat && s_axis.tuser) fs_done <= 1'b0;
      case (fst)
        F_RUN: begin
          if (need_fs) fst <= F_START;
          else if (need_row && eng_done && !eng_start) begin
            if (eng_row == py) begin                 // the next row is ready: take it, start the one after
              c_xo <= n_xo;
              c_xi <= n_xi;
              c_xov <= n_xov;
              c_xiv <= n_xiv;
              c_tv <= n_tv;
              c_l <= n_l;
              c_r <= n_r;
              c_lp <= n_lp;
              c_rp <= n_rp;
              cur_row <= py;
              eng_row <= py + 1'b1;
            end else eng_row <= py;                  // (not the row expected: compute it)
            eng_start <= 1'b1;
          end
        end
        F_START: if (drained) begin                  // the frame start: ENABLE, frame number, the snapshot
          act_en <= ctrl[0];
          frames <= frames + 1'b1;
          fnum <= fnum_pend ? fnum_set : bcd_inc(fnum);
          if (!fnum_wr) fnum_pend <= 1'b0;
          seen <= 1'b1;
          if (seen) begin
            wf <= w_meas;
            hf <= y;
          end
          applied <= pending;
          if (pending) begin
            if (!commit_set) pending <= 1'b0;
            a_ls <= ctrl[2:1];
            a_font <= ctrl[3];
            for (int k = 0; k < NOBJ; k++) begin
              a_ctrl[k] <= l_ctrl[k];
              a_x0[k] <= l_x[k][CW-1:0];
              a_x1[k] <= l_x[k][16 +: CW];
              a_y0[k] <= l_y[k][CW-1:0];
              a_y1[k] <= l_y[k][16 +: CW];
              a_col[k] <= l_col[k];
              a_lab[k] <= l_lab[k];
            end
            for (int j = 0; j < NT; j++) begin
              t_ctrl[j] <= regs.cfg_txt_ctrl[j*32 +: 13];
              t_x[j] <= regs.cfg_txt_pos[j*32 +: CW];
              t_y[j] <= regs.cfg_txt_pos[j*32 + 16 +: CW];
              t_color[j] <= regs.cfg_txt_color[j*24 +: 24];
              t_chars[j] <= regs.cfg_txt_chars[j*128 +: 128];
            end
          end
          fst <= F_PREP;
        end
        F_PREP: fst <= F_ROW0;                       // the prepared values load (below)
        F_ROW0: if (!eng_busy) begin
          eng_row <= '0;
          eng_start <= 1'b1;
          fst <= F_WAIT0;
        end
        F_WAIT0: if (eng_done && !eng_start) begin
          c_xo <= n_xo;
          c_xi <= n_xi;
          c_xov <= n_xov;
          c_xiv <= n_xiv;
          c_tv <= n_tv;
          c_l <= n_l;
          c_r <= n_r;
          c_lp <= n_lp;
          c_rp <= n_rp;
          cur_row <= '0;
          eng_row <= CW'(1);
          eng_start <= 1'b1;
          fs_done <= 1'b1;
          fst <= F_RUN;
        end
        default: fst <= F_RUN;
      endcase
    end
  end

  function automatic logic [19:0] bcd_inc(input logic [19:0] v);
    logic [19:0] r;
    logic cy;
    r = v;
    cy = 1'b1;
    for (int d = 0; d < 5; d++) if (cy) begin
      if (r[4*d +: 4] >= 4'd9) r[4*d +: 4] = 4'd0;
      else begin
        r[4*d +: 4] = r[4*d +: 4] + 4'd1;
        cy = 1'b0;
      end
    end
    return r;
  endfunction

  // ---------------- prepared values (loaded in F_PREP from a new snapshot)
  logic [2:0]    pr_n [NOBJ];
  sc_t           pr_lx [NOBJ], pr_ly [NOBJ];
  logic [CW-1:0] pr_cl [NOBJ];
  logic [SW-1:0] pr_a [NOBJ], pr_b [NOBJ], pr_ai [NOBJ], pr_bi [NOBJ];
  logic [4:0]    pr_tn [NT];
  for (genvar k = 0; k < NOBJ; k++) begin : g_prep
    always_comb begin
      logic [31:0] lab;
      sc_t tw, cxm, lx, ly;
      logic [SW-1:0] aa, bb, two_lw, m;
      logic [3:0] lw;
      lab = a_lab[k];
      pr_n[k] = (lab[7:0] == 0) ? 3'd0 : (lab[15:8] == 0) ? 3'd1 : (lab[23:16] == 0) ? 3'd2 :
                (lab[31:24] == 0) ? 3'd3 : 3'd4;
      tw = ((sc_t'(pr_n[k]) <<< 2) - sc_t'(1)) <<< a_ls;   // (4 n - 1) s, s = 1 << LABEL_SCALE
      cxm = (sc_t'(a_x0[k]) + sc_t'(a_x1[k])) >>> 1;
      lx = cxm - (tw >>> 1);
      if (sc_t'(wf) - tw < lx) lx = sc_t'(wf) - tw;
      if (lx < 0) lx = '0;
      ly = sc_t'(a_y1[k]) + sc_t'(2);
      if (ly + (sc_t'(5) <<< a_ls) > sc_t'(hf)) begin
        ly = sc_t'(a_y0[k]) - (sc_t'(7) <<< a_ls);
        if (ly < 0) ly = '0;
      end
      pr_lx[k] = lx;
      pr_ly[k] = ly;
      // the rectangle / triangle corner length: max(3, min(A, B) >> 2)
      aa = SW'(a_x1[k]) - SW'(a_x0[k]) + 1'b1;
      bb = SW'(a_y1[k]) - SW'(a_y0[k]) + 1'b1;
      m = ((aa < bb) ? aa : bb) >> 2;
      pr_cl[k] = (m < SW'(3)) ? CW'(3) : CW'(m);
      // the ellipse axes: (A, B) with OVAL, else (R, R), R = max(A, B); inner axes 2 LINE_W shorter (>= 0)
      lw = (a_ctrl[k][11:8] == 4'd0) ? 4'd1 : a_ctrl[k][11:8];
      two_lw = SW'({lw, 1'b0});
      if (a_ctrl[k][5]) begin
        pr_a[k] = aa;
        pr_b[k] = bb;
      end else begin
        pr_a[k] = (aa > bb) ? aa : bb;
        pr_b[k] = (aa > bb) ? aa : bb;
      end
      pr_ai[k] = (pr_a[k] > two_lw) ? pr_a[k] - two_lw : '0;
      pr_bi[k] = (pr_b[k] > two_lw) ? pr_b[k] - two_lw : '0;
    end
  end
  for (genvar j = 0; j < NT; j++) begin : g_prep_t
    always_comb begin
      logic [4:0] len;
      len = (t_ctrl[j][12:8] > 5'd16) ? 5'd16 : t_ctrl[j][12:8];
      pr_tn[j] = len + (t_ctrl[j][4] ? 5'd5 : 5'd0);
    end
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int k = 0; k < NOBJ; k++) begin
        lab_n[k] <= '0;
        lab_x[k] <= '0;
        lab_y[k] <= '0;
        lab_xe[k] <= '0;
        lab_ye[k] <= '0;
        o_cl[k] <= '0;
        e_a[k] <= '0;
        e_b[k] <= '0;
        e_ai[k] <= '0;
        e_bi[k] <= '0;
      end
      for (int j = 0; j < NT; j++) begin
        txt_n[j] <= '0;
        txt_xe[j] <= '0;
        txt_ye[j] <= '0;
      end
    end else if (fst == F_PREP && applied) begin
      for (int k = 0; k < NOBJ; k++) begin
        lab_n[k] <= pr_n[k];
        lab_x[k] <= pr_lx[k];
        lab_y[k] <= pr_ly[k];
        lab_xe[k] <= pr_lx[k] + (sc_t'(pr_n[k]) <<< (3'(a_ls) + 3'd2));
        lab_ye[k] <= pr_ly[k] + (sc_t'(6) <<< a_ls);
        o_cl[k] <= pr_cl[k];
        e_a[k] <= pr_a[k];
        e_b[k] <= pr_b[k];
        e_ai[k] <= pr_ai[k];
        e_bi[k] <= pr_bi[k];
      end
      for (int j = 0; j < NT; j++) begin
        txt_n[j] <= pr_tn[j];
        txt_xe[j] <= sc_t'(t_x[j]) + (sc_t'(pr_tn[j]) <<< (3'(t_ctrl[j][2:1]) + 3'd2));
        txt_ye[j] <= sc_t'(t_y[j]) + (sc_t'(6) <<< t_ctrl[j][2:1]);
      end
    end
  end

  // ================================================================ stage 0: hits of the accepted beat
  logic [NOBJ-1:0] h_sym, h_lab;
  logic [NT-1:0]   h_txt;
  for (genvar k = 0; k < NOBJ; k++) begin : g_obj
    always_comb begin
      /* verilator lint_off UNUSEDSIGNAL */        // [4] BLEND and [5] OVAL are used elsewhere
      logic [15:0] c;
      /* verilator lint_on UNUSEDSIGNAL */
      logic [3:0] lw;
      logic [KW-1:0] kd;
      sc_t X, Y, x0, x1, y0, y1, lws, cx, cy, dx, dy, cl, hw, s2, t2, adx, ady, mn, W, H, t, L, R, Lp, Rp;
      sc_t dl, dr, le, xo, xi, lws3;
      logic inb, hor, edg, ond, near, tick, rect, crs, ring, left, right, base, tri_on, on;
      c = a_ctrl[k];
      lw = (c[11:8] == 4'd0) ? 4'd1 : c[11:8];
      kd = KW'(c[14:12]);                          // dash bit (k); the ellipse's is k + 1
      X = sc_t'(px);
      Y = sc_t'(py);
      x0 = sc_t'(a_x0[k]);
      x1 = sc_t'(a_x1[k]);
      y0 = sc_t'(a_y0[k]);
      y1 = sc_t'(a_y1[k]);
      lws = sc_t'(lw);
      lws3 = (lws <<< 1) + lws;
      cl = sc_t'(o_cl[k]);
      cx = (x0 + x1) >>> 1;
      cy = (y0 + y1) >>> 1;
      dx = X - x0;
      dy = Y - y0;
      inb = X >= x0 && X <= x1 && Y >= y0 && Y <= y1;
      // rectangle outline, dashes, solid corners, ticks
      hor = Y < y0 + lws || Y > y1 - lws;
      edg = inb && (hor || X < x0 + lws || X > x1 - lws);
      ond = hor ? !dx[kd] : !dy[kd];
      near = (dx < cl || x1 - X < cl) && (dy < cl || y1 - Y < cl);
      tick = inb && ((X == cx && ((Y >= y0 + lws && Y <= y0 + lws3 - 1) ||
                                     (Y >= y1 - lws3 + 1 && Y <= y1 - lws))) ||
                        (Y == cy && ((X >= x0 + lws && X <= x0 + lws3 - 1) ||
                                     (X >= x1 - lws3 + 1 && X <= x1 - lws))));
      rect = (edg && (!c[3] || ond || (c[15] && near))) || (c[6] && tick);
      // crosshair
      hw = ((lws + 1) >>> 1) + (lws[0] ? sc_t'(0) : sc_t'(1));
      crs = inb && ((X - cx < hw && cx - X < hw) || (Y - cy < hw && cy - Y < hw)) &&
              (!c[3] || !dx[kd] || !dy[kd]);
      // ellipse ring: |dx2| in (xi, xo] on this row
      s2 = x0 + x1;
      t2 = y0 + y1;
      adx = (2 * X >= s2) ? 2 * X - s2 : s2 - 2 * X;
      ady = (2 * Y >= t2) ? 2 * Y - t2 : t2 - 2 * Y;
      mn = (adx < ady) ? adx : ady;
      xo = sc_t'(c_xo[k*SW +: SW]);
      xi = sc_t'(c_xi[k*SW +: SW]);
      ring = c_xov[k] && adx <= xo && !(c_xiv[k] && adx <= xi) && (!c[3] || !mn[kd + KW'(1)]);
      // triangle: bands from this row's edges
      W = x1 - x0;
      H = y1 - y0;
      t = Y - y0;
      L = sc_t'(c_l[k*CW +: CW]);
      R = sc_t'(c_r[k*CW +: CW]);
      Lp = sc_t'(c_lp[k*CW +: CW]);
      Rp = sc_t'(c_rp[k*CW +: CW]);
      left = X >= L && X <= ((Lp - 1 > L) ? Lp - 1 : L) + lws - 1;
      right = X >= ((Rp + 1 < R) ? Rp + 1 : R) - lws + 1 && X <= R;
      base = t > H - lws && X >= L && X <= R;
      le = (H > (W >>> 1)) ? H : (W >>> 1);
      dl = (t > (s2 >>> 1) - X) ? t : (s2 >>> 1) - X;
      dr = (t > X - ((s2 + 1) >>> 1)) ? t : X - ((s2 + 1) >>> 1);
      if (c[3]) begin
        left = left && (dl < cl || le - dl < cl || !dl[kd]);
        right = right && (dr < cl || le - dr < cl || !dr[kd]);
        base = base && (dx < cl || W - dx < cl || !dx[kd]);
      end
      tri_on = c_tv[k] && inb && (left || right || base);
      if (c[7]) on = tri_on;
      else case (c[2:1])
        2'd0: on = rect;
        2'd1: on = inb;
        2'd2: on = crs;
        default: on = ring;
      endcase
      h_sym[k] = act_en && c[0] && x0 <= x1 && y0 <= y1 && on;
      h_lab[k] = act_en && c[0] && lab_n[k] != 3'd0 && X >= lab_x[k] && X < lab_xe[k] && Y >= lab_y[k] &&
                 Y < lab_ye[k];
    end
  end
  for (genvar j = 0; j < NT; j++) begin : g_txt
    always_comb begin
      sc_t X, Y;
      X = sc_t'(px);
      Y = sc_t'(py);
      h_txt[j] = (j < NTXT) && act_en && t_ctrl[j][0] && txt_n[j] != 5'd0 && X >= sc_t'(t_x[j]) &&
                 X < txt_xe[j] && Y >= sc_t'(t_y[j]) && Y < txt_ye[j];
    end
  end

  // ================================================================ pixel pipeline
  assign adv = !m_axis.tvalid || m_axis.tready;
  // stage 1 registers
  logic            p1_last, p1_user;
  logic [23:0]     p1_pix;
  logic [CW-1:0]   p1_x, p1_y;
  logic [NOBJ-1:0] p1_sym, p1_lab;
  logic [NT-1:0]   p1_txt;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      p1_v <= 1'b0;
      p1_last <= 1'b0;
      p1_user <= 1'b0;
      p1_pix <= '0;
      p1_x <= '0;
      p1_y <= '0;
      p1_sym <= '0;
      p1_lab <= '0;
      p1_txt <= '0;
    end else if (adv) begin
      p1_v <= in_beat;
      p1_last <= s_axis.tlast;
      p1_user <= s_axis.tuser;
      p1_pix <= s_axis.tdata;
      p1_x <= px;
      p1_y <= py;
      p1_sym <= h_sym;
      p1_lab <= h_lab;
      p1_txt <= h_txt;
    end
  end

  // ---------------- stage 1: selection, characters, font addresses
  logic [OW-1:0] s_sym, s_lab;
  logic [TW-1:0] s_txt;
  always_comb begin
    s_sym = '0;
    s_lab = '0;
    for (int k = NOBJ - 1; k >= 0; k--) begin
      if (p1_sym[k]) s_sym = OW'(k);
      if (p1_lab[k]) s_lab = OW'(k);
    end
    s_txt = '0;
    for (int j = NT - 1; j >= 0; j--) if (p1_txt[j]) s_txt = TW'(j);
  end
  // the glyph cell of the selected label and text: character, column and row in the cell (scale 1 << sl)
  logic [7:0] l_ch, t_ch;
  logic [4:0] l_cc, t_cc;                        // column in the cell (0 .. 4 s - 1)
  logic [5:0] l_row, t_row;                      // row in the cell (0 .. 6 s - 1)
  logic [1:0] t_sl;
  always_comb begin
    sc_t dxl, dxt;
    logic [4:0] cidx, nlen;                       // cell index (labels < 4, texts < 21)
    logic [2:0] d;
    dxl = sc_t'(p1_x) - lab_x[s_lab];
    cidx = 5'(dxl >>> (3'(a_ls) + 3'd2));
    l_ch = a_lab[s_lab][8 * cidx[1:0] +: 8];
    l_cc = 5'(dxl & ((sc_t'(4) <<< a_ls) - sc_t'(1)));
    l_row = 6'(sc_t'(p1_y) - lab_y[s_lab]);
    t_sl = t_ctrl[s_txt][2:1];
    dxt = sc_t'(p1_x) - sc_t'(t_x[s_txt]);
    cidx = 5'(dxt >>> (3'(t_sl) + 3'd2));
    nlen = (t_ctrl[s_txt][12:8] > 5'd16) ? 5'd16 : t_ctrl[s_txt][12:8];
    d = 3'(cidx - nlen);                          // the frame number's digit (from the left)
    if (cidx < nlen) t_ch = t_chars[s_txt][8 * cidx[3:0] +: 8];
    else t_ch = 8'h30 + 8'(fnum[4 * (3'd4 - d) +: 4]);
    t_cc = 5'(dxt & ((sc_t'(4) <<< t_sl) - sc_t'(1)));
    t_row = 6'(sc_t'(p1_y) - sc_t'(t_y[s_txt]));
  end
  // 3 x 5 glyph pixels and smooth-font ROM addresses: (character - 32) * 6 s + row ('?' outside 32-126)
  function automatic logic glyph3(input logic [7:0] ch, input logic [4:0] col, input logic [5:0] row,
                                  input logic [1:0] sl);
    logic [4:0] fc;
    logic [5:0] fr;
    logic [14:0] g;
    fc = col >> sl;
    fr = row >> sl;
    g = overlay_font_pkg::glyph(ch);
    return fr < 6'd5 && fc < 5'd3 && g[4'(fr) * 4'd3 + 4'(fc)];
  endfunction
  function automatic logic [12:0] aa_addr(input logic [7:0] ch, input logic [5:0] row, input logic [1:0] sl);
    logic [6:0] ci;
    ci = (ch >= 8'd32 && ch <= 8'd126) ? 7'(ch - 8'd32) : 7'd31;
    return 13'(((13'(ci) << 2) + (13'(ci) << 1)) << sl) + 13'(row);   // ci * 6 s + row
  endfunction
  wire [12:0] l_addr = aa_addr(l_ch, l_row, a_ls);
  wire [12:0] t_addr = aa_addr(t_ch, t_row, t_sl);
  logic [31:0]  rom2_l, rom2_t;
  logic [63:0]  rom4_l, rom4_t;
  logic [127:0] rom8_l, rom8_t;
  overlay_font_rom #(.W(32), .DEPTH(1140), .FILE(FONT_DIR == "" ? "" : {FONT_DIR, "overlay_font_aa_s2.mem"})) u_rom2 (
    .clk,
    .en_a(adv),
    .addr_a(l_addr[10:0]),
    .data_a(rom2_l),
    .en_b(adv),
    .addr_b(t_addr[10:0]),
    .data_b(rom2_t)
  );
  overlay_font_rom #(.W(64), .DEPTH(2280), .FILE(FONT_DIR == "" ? "" : {FONT_DIR, "overlay_font_aa_s4.mem"})) u_rom4 (
    .clk,
    .en_a(adv),
    .addr_a(l_addr[11:0]),
    .data_a(rom4_l),
    .en_b(adv),
    .addr_b(t_addr[11:0]),
    .data_b(rom4_t)
  );
  overlay_font_rom #(.W(128), .DEPTH(4560), .FILE(FONT_DIR == "" ? "" : {FONT_DIR, "overlay_font_aa_s8.mem"})) u_rom8 (
    .clk,
    .en_a(adv),
    .addr_a(l_addr),
    .data_a(rom8_l),
    .en_b(adv),
    .addr_b(t_addr),
    .data_b(rom8_t)
  );
  // stage 2 registers
  logic          p2_last, p2_user;
  logic [23:0]   p2_pix;
  logic          p2_sym, p2_blend;
  logic [23:0]   p2_scol;
  logic          p2_lab, p2_laa, p2_lg3;
  logic [23:0]   p2_lcol;
  logic [4:0]    p2_lc;
  logic          p2_txt, p2_tbd, p2_taa, p2_tg3;
  logic [23:0]   p2_tcol;
  logic [4:0]    p2_tc;
  logic [1:0]    p2_tsl;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      p2_v <= 1'b0;
      p2_last <= 1'b0;
      p2_user <= 1'b0;
      p2_pix <= '0;
      p2_sym <= 1'b0;
      p2_blend <= 1'b0;
      p2_scol <= '0;
      p2_lab <= 1'b0;
      p2_laa <= 1'b0;
      p2_lg3 <= 1'b0;
      p2_lcol <= '0;
      p2_lc <= '0;
      p2_txt <= 1'b0;
      p2_tbd <= 1'b0;
      p2_taa <= 1'b0;
      p2_tg3 <= 1'b0;
      p2_tcol <= '0;
      p2_tc <= '0;
      p2_tsl <= '0;
    end else if (adv) begin
      p2_v <= p1_v;
      p2_last <= p1_last;
      p2_user <= p1_user;
      p2_pix <= p1_pix;
      p2_sym <= |p1_sym;
      p2_blend <= a_ctrl[s_sym][4];
      p2_scol <= a_col[s_sym];
      p2_lab <= |p1_lab;
      p2_laa <= a_font && a_ls != 2'd0;
      p2_lg3 <= glyph3(l_ch, l_cc, l_row, a_ls);
      p2_lcol <= a_col[s_lab];
      p2_lc <= l_cc;
      p2_txt <= |p1_txt;
      p2_tbd <= t_ctrl[s_txt][3];
      p2_taa <= a_font && t_sl != 2'd0;
      p2_tg3 <= glyph3(t_ch, t_cc, t_row, t_sl);
      p2_tcol <= t_color[s_txt];
      p2_tc <= t_cc;
      p2_tsl <= t_sl;
    end
  end

  // ---------------- stage 2: coverage, the symbol and label layers
  function automatic logic [3:0] nib(input logic [1:0] sl, input logic [4:0] col, input logic [31:0] w2,
                                     input logic [63:0] w4, input logic [127:0] w8);
    case (sl)
      2'd1: return w2[(5'd7 - {2'b0, col[2:0]}) * 4 +: 4];
      2'd2: return w4[(5'd15 - {1'b0, col[3:0]}) * 4 +: 4];
      default: return w8[(5'd31 - col) * 4 +: 4];
    endcase
  endfunction
  // v (15 - a) + c a + 7, divided by 15 (exact over the range: (n * 2185) >> 15)
  // (shifts and adds: no multipliers)
  function automatic logic [11:0] mul4(input logic [7:0] v, input logic [3:0] a);
    return (a[0] ? 12'(v) : 12'd0) + (a[1] ? 12'(v) << 1 : 12'd0) + (a[2] ? 12'(v) << 2 : 12'd0) +
           (a[3] ? 12'(v) << 3 : 12'd0);
  endfunction
  function automatic logic [7:0] mix(input logic [7:0] v, input logic [7:0] c, input logic [3:0] a);
    logic [11:0] n;
    logic [23:0] q;
    n = mul4(v, 4'd15 - a) + mul4(c, a) + 12'd7;
    q = (24'(n) << 11) + (24'(n) << 7) + (24'(n) << 3) + 24'(n);  // n * 2185
    return 8'(q >> 15);
  endfunction
  function automatic logic [23:0] mix3(input logic [23:0] v, input logic [23:0] c, input logic [3:0] a);
    return {mix(v[23:16], c[23:16], a), mix(v[15:8], c[15:8], a), mix(v[7:0], c[7:0], a)};
  endfunction
  /* verilator lint_off UNUSEDSIGNAL */            // the low bit of each channel is shifted out
  function automatic logic [23:0] half(input logic [23:0] v);
    return {1'b0, v[23:17], 1'b0, v[15:9], 1'b0, v[7:1]};
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */
  function automatic logic [23:0] avg(input logic [23:0] v, input logic [23:0] c);
    return {8'((9'(v[23:16]) + 9'(c[23:16])) >> 1), 8'((9'(v[15:8]) + 9'(c[15:8])) >> 1),
            8'((9'(v[7:0]) + 9'(c[7:0])) >> 1)};
  endfunction
  wire [3:0]  l_a = p2_laa ? nib(a_ls, p2_lc, rom2_l, rom4_l, rom8_l) : (p2_lg3 ? 4'd15 : 4'd0);
  wire [3:0]  t_a = p2_taa ? nib(p2_tsl, p2_tc, rom2_t, rom4_t, rom8_t) : (p2_tg3 ? 4'd15 : 4'd0);
  wire [23:0] v1 = p2_sym ? (p2_blend ? avg(p2_pix, p2_scol) : p2_scol) : p2_pix;
  wire [23:0] v2 = p2_lab ? mix3(half(v1), p2_lcol, l_a) : v1;
  // stage 3 registers
  logic          p3_last, p3_user;
  logic [23:0]   p3_pix;
  logic          p3_txt, p3_tbd;
  logic [23:0]   p3_tcol;
  logic [3:0]    p3_ta;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      p3_v <= 1'b0;
      p3_last <= 1'b0;
      p3_user <= 1'b0;
      p3_pix <= '0;
      p3_txt <= 1'b0;
      p3_tbd <= 1'b0;
      p3_tcol <= '0;
      p3_ta <= '0;
    end else if (adv) begin
      p3_v <= p2_v;
      p3_last <= p2_last;
      p3_user <= p2_user;
      p3_pix <= v2;
      p3_txt <= p2_txt;
      p3_tbd <= p2_tbd;
      p3_tcol <= p2_tcol;
      p3_ta <= t_a;
    end
  end

  // ---------------- stage 3: the text layer, the output register
  wire [23:0] v3 = p3_txt ? mix3(p3_tbd ? half(p3_pix) : p3_pix, p3_tcol, p3_ta) : p3_pix;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      m_axis.tvalid <= 1'b0;
      m_axis.tdata <= '0;
      m_axis.tlast <= 1'b0;
      m_axis.tuser <= 1'b0;
    end else if (adv) begin
      m_axis.tvalid <= p3_v;
      m_axis.tdata <= v3;
      m_axis.tlast <= p3_last;
      m_axis.tuser <= p3_user;
    end
  end

  // ================================================================ beat position, frame size, status
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      x <= '0;
      y <= '0;
      w_meas <= '0;
    end else if (in_beat) begin
      if (s_axis.tlast) begin
        x <= '0;
        y <= py + 1'b1;
        if (py == '0) w_meas <= px + 1'b1;
      end else begin
        x <= px + 1'b1;
        y <= py;
      end
    end
  end
  assign regs.sts_commit = pending;
  assign regs.sts_status = {frames, 15'd0, pending};
  assign regs.sts_frame_num = fnum;
endmodule
