// ***************
// Filename: symbol_overlay.sv
// Author: FPGA Cores 4 U
// Description: Symbol overlay for an AXI4-Stream video (24-bit pixels,
//   tuser = start of frame, tlast = end of line). Version: the VERSION register. Draws up to
//   NOBJ symbols over the image as it streams through: no frame buffer, one
//   clock of latency, full back-pressure (a register stage). Each object
//   is a box (x0..x1, y0..y1, inclusive) drawn as
//     - shape 0: rectangle outline, LINE_W pixels wide, inside the box;
//     - shape 1: filled rectangle;
//     - shape 2: crosshair, a horizontal and a vertical line LINE_W wide
//       through the centre of the box, as long as the box;
//     - shape 3: circle round the centre of the box, radius R = half the
//       larger side (it encloses a square box, reaches past a long box's
//       short sides), outline LINE_W wide inside the radius:
//       (R - LINE_W)^2 < dx^2 + dy^2 <= R^2 (an empty box, x0 > x1 or
//       y0 > y1, draws nothing, as for the other shapes); with OVAL
//       (CTRL[5]) an oval (ellipse) inside the box instead, semi-axes A =
//       half the width, B = half the height, outline LINE_W wide inside it:
//       dx^2 B^2 + dy^2 A^2 <= A^2 B^2 and outside the ellipse of A - LINE_W,
//       B - LINE_W (a wide box, e.g. a bus, gets a wide oval);
//   solid or dashed (DASH: 2^DASH_LOG2 pixels on, as many off, counted
//   from x0 along horizontal lines and from y0 along vertical ones; on a
//   circle by min(|dx|, |dy|), so the dashes repeat in each eighth), in
//   COLOR or blended 50 % with the video. Object 0 is on top.
//   NTXT text objects draw up to 16 characters each (3 x 5 pixel font in 4 x 6
//   cells, overlay_font_pkg; lowercase as capitals) at x, y, scaled 1x, 2x
//   or 4x, in COLOR, optionally on a backdrop (the video under the text
//   cells darkened to half) for legibility; texts are on top of the
//   objects, text 0 on top.
//   The CPU writes the object and text registers in any order, then COMMIT:
//   they take effect together at the next frame start (no torn symbol or
//   text); STATUS[0] stays set until then. CTRL.ENABLE is also taken at a
//   frame start; with it clear the video passes unchanged.
//   Registers on the cfg_* / sts_* ports; symbol_overlay_top.sv is the block
//   with its AXI4-Lite register map (src/include/symbol_overlay_regs.sv, AXI4-Lite
//   slave, ADDR_W = 10): ID "SOVL" / VERSION / DATE at 0x00-0x08, CTRL 0x18,
//   COMMIT 0x1C, STATUS 0x20, FRAME_NUM 0x24, object i OBJ_CTRL / OBJ_X /
//   OBJ_Y / OBJ_COLOR at 0x50 / 0x54 / 0x58 / 0x5C + 16 i, text j TXT_CTRL /
//   TXT_POS / TXT_COLOR at 0x110 / 0x114 / 0x118 + 16 j, TXT_CHARS at 0x210 +
//   16 j (4 words).
//   Clock - clk (pixel clock). Reset - synchronous active low rst_n.
// Date: 2026-10-14
module symbol_overlay #(
  parameter int NOBJ = 4,                        // symbols (1..12)
  parameter int NTXT = 4,                        // text objects (0..8)
  parameter int CW   = 16                        // coordinate width
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
  assign m_axis.tkeep = '1;      // not used by this block
  if (NOBJ < 1 || NOBJ > 12) begin : g_bad_nobj $error("symbol_overlay: NOBJ must be 1..12"); end
  if (NTXT < 0 || NTXT > 8) begin : g_bad_ntxt $error("symbol_overlay: NTXT must be 0..8"); end

  localparam int NT = (NTXT < 1) ? 1 : NTXT;     // storage for at least one (unused when NTXT = 0)
  // ---------------- registers
  logic ctrl_en, commit_wr, fnum_wr;
  logic commit_d;
  logic [19:0] fnum_d;
  logic [NOBJ*32-1:0] obj_ctrl, obj_x, obj_y;
  logic [NOBJ*24-1:0] obj_color;
  logic [NT*32-1:0] txt_ctrl, txt_pos;
  logic [NT*24-1:0] txt_color;
  logic [NT*128-1:0] txt_chars;
  logic [NOBJ*128-1:0] oreg;                     // per object {COLOR, Y, X, CTRL} as the drawing uses it
  logic [NT*96-1:0] treg;                        // per text {COLOR, POS, CTRL}
  logic act_en, pending;
  logic [15:0] frames;
  logic [19:0] fnum;
  // register ports (the map symbol_overlay_regs is in the wrapper, src/symbol_overlay_top.sv)
  assign ctrl_en = regs.cfg_ctrl;
  assign regs.sts_commit = pending;
  assign commit_d = regs.cfg_commit;
  assign commit_wr = regs.cfg_commit_wr;
  assign regs.sts_status = {frames, 15'd0, pending};
  assign regs.sts_frame_num = fnum;
  assign fnum_d = regs.cfg_frame_num;
  assign fnum_wr = regs.cfg_frame_num_wr;
  assign obj_ctrl = regs.cfg_obj_ctrl;
  assign obj_x = regs.cfg_obj_x;
  assign obj_y = regs.cfg_obj_y;
  assign obj_color = regs.cfg_obj_color;
  assign txt_ctrl = regs.cfg_txt_ctrl;
  assign txt_pos = regs.cfg_txt_pos;
  assign txt_color = regs.cfg_txt_color;
  assign txt_chars = regs.cfg_txt_chars;
  always_comb begin
    for (int i = 0; i < NOBJ; i++)
      oreg[i*128 +: 128] = {8'd0, obj_color[i*24 +: 24], obj_y[i*32 +: 32], obj_x[i*32 +: 32], obj_ctrl[i*32 +: 32]};
    for (int j = 0; j < NT; j++) treg[j*96 +: 96] = {8'd0, txt_color[j*24 +: 24], txt_pos[j*32 +: 32], txt_ctrl[j*32 +: 32]};
  end

  // ---------------- active object set (taken at a frame start)
  logic [NOBJ*128-1:0] act;                      // per object {COLOR, Y, X, CTRL}
  wire  in_beat = s_axis.tvalid && s_axis.tready;
  wire  take = in_beat && s_axis.tuser;         // start of frame: new settings apply to it
  wire [NOBJ*128-1:0] cur = (take && pending) ? oreg : act;
  wire  cur_en = take ? ctrl_en : act_en;
  // active texts: per text {COLOR, POS, CTRL} and its 16 characters
  logic [NT*96-1:0] tact;
  logic [NT*128-1:0] cact;
  wire [NT*96-1:0] tcur = (take && pending) ? treg : tact;
  wire [NT*128-1:0] ccur = (take && pending) ? txt_chars : cact;
  // frame number (5 BCD digits): set by a FRAME_NUM write for the next frame, else one more each frame
  logic [19:0] fnum_set;
  logic fnum_pend;
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
  wire [19:0] fcur = take ? (fnum_pend ? fnum_set : bcd_inc(fnum)) : fnum;
  // its digits without leading zeros: nd digits (1..5), digit k from the left
  logic [2:0] nd;
  always_comb begin
    nd = 3'd1;
    for (int d = 1; d < 5; d++) if (fcur[4*d +: 4] != 4'd0) nd = 3'(d + 1);
  end

  // ---------------- position of the current beat
  logic [CW-1:0] x, y;
  wire  [CW:0] px = s_axis.tuser ? '0 : {1'b0, x};
  wire  [CW:0] py = s_axis.tuser ? '0 : {1'b0, y};

  // ---------------- drawing (object 0 last: on top)
  logic [23:0] pix;
  always_comb begin
    pix = s_axis.tdata;
    if (cur_en) begin
      for (int i = NOBJ - 1; i >= 0; i--) begin
        logic [31:0] c, ox, oy, col;
        logic [CW:0] x0, x1, y0, y1, w, cx, cy, dx, dy, rad, m;
        logic signed [CW+2:0] sdx, sdy, rin;
        logic [2*CW+5:0] d2;
        logic [CW:0] ea, eb, ia, ib;
        logic [4*CW+11:0] eo, ei;
        logic oval;
        logic [2:0] k;
        logic in_box, hbar, vbar, hdash, vdash, ring, cdash, draw;
        c = cur[i*128 +: 32];
        ox = cur[i*128 + 32 +: 32];
        oy = cur[i*128 + 64 +: 32];
        col = cur[i*128 + 96 +: 32];
        x0 = {1'b0, ox[CW-1:0]};
        x1 = {1'b0, ox[16 +: CW]};
        y0 = {1'b0, oy[CW-1:0]};
        y1 = {1'b0, oy[16 +: CW]};
        w = (c[11:8] == 0) ? (CW+1)'(1) : (CW+1)'(c[11:8]);
        k = c[14:12];
        in_box = px >= x0 && px <= x1 && py >= y0 && py <= y1;
        dx = px - x0;
        dy = py - y0;
        hdash = !c[3] || !dx[5'(k)];                 // dashed along x: 2^k on, 2^k off
        vdash = !c[3] || !dy[5'(k)];
        cx = (x0 + x1) >> 1;
        cy = (y0 + y1) >> 1;
        case (c[2:1])
          2'd0: begin                            // rectangle outline
            hbar = py < y0 + w || py + w > y1;
            vbar = px < x0 + w || px + w > x1;
          end
          2'd1: begin                            // filled rectangle
            hbar = 1'b1;
            vbar = 1'b0;
          end
          default: begin                         // crosshair through the centre (shape 3: not used)
            hbar = py + (w >> 1) >= cy && py + (w >> 1) < cy + w;
            vbar = px + (w >> 1) >= cx && px + (w >> 1) < cx + w;
          end
        endcase
        // circle (shape 3): ring of width w inside radius rad, dashed by min(|dx|, |dy|)
        rad = ((x1 - x0 > y1 - y0) ? x1 - x0 : y1 - y0) >> 1;
        sdx = $signed({2'b0, px}) - $signed({2'b0, cx});
        sdy = $signed({2'b0, py}) - $signed({2'b0, cy});
        if (sdx < 0) sdx = -sdx;
        if (sdy < 0) sdy = -sdy;
        d2 = (2*CW+6)'(sdx * sdx) + (2*CW+6)'(sdy * sdy);
        rin = $signed({2'b0, rad}) - $signed({2'b0, w});
        ring = d2 <= (2*CW+6)'(rad * rad) && (rin < 0 || d2 > (2*CW+6)'(rin * rin));
        // oval (shape 3 with CTRL[5]): ellipse inside the box, ring of width w
        ea = (x1 - x0) >> 1;
        eb = (y1 - y0) >> 1;
        ia = ea - w;
        ib = eb - w;
        eo = (4*CW+12)'(sdx * sdx) * (4*CW+12)'(eb * eb) + (4*CW+12)'(sdy * sdy) * (4*CW+12)'(ea * ea);
        ei = (4*CW+12)'(sdx * sdx) * (4*CW+12)'(ib * ib) + (4*CW+12)'(sdy * sdy) * (4*CW+12)'(ia * ia);
        oval = eo <= (4*CW+12)'(ea * ea) * (4*CW+12)'(eb * eb) &&
               (ea < w || eb < w || ei > (4*CW+12)'(ia * ia) * (4*CW+12)'(ib * ib));
        if (c[5]) ring = oval;
        m = (sdx < sdy) ? (CW+1)'(sdx) : (CW+1)'(sdy);
        cdash = !c[3] || !m[5'(k)];
        draw = c[0] && ((c[2:1] == 2'd3) ? ring && cdash && x0 <= x1 && y0 <= y1
                                         : in_box && ((hbar && hdash) || (vbar && vdash) || c[2:1] == 2'd1));
        if (draw) begin
          if (c[4]) pix = {8'((9'(pix[23:16]) + 9'(col[23:16])) >> 1), 8'((9'(pix[15:8]) + 9'(col[15:8])) >> 1),
                           8'((9'(pix[7:0]) + 9'(col[7:0])) >> 1)};
          else pix = col[23:0];
        end
      end
    end
  end

  // ---------------- texts on top of the objects (text 0 last: on top)
  logic [23:0] pix_t;
  always_comb begin
    pix_t = pix;
    if (cur_en && NTXT > 0) begin
      for (int j = NT - 1; j >= 0; j--) begin
        logic [31:0] c, pos, col;
        logic [CW:0] dx, dy, tx, ty, cx, cy;
        logic [4:0] len;
        logic [1:0] sc;
        logic [7:0] ch;
        logic [14:0] g;
        logic in_txt, on;
        c = tcur[j*96 +: 32];
        pos = tcur[j*96 + 32 +: 32];
        col = tcur[j*96 + 64 +: 32];
        len = (c[12:8] > 5'd16) ? 5'd16 : c[12:8];
        sc = (c[2:1] > 2'd2) ? 2'd2 : c[2:1];
        tx = {1'b0, pos[CW-1:0]};
        ty = {1'b0, pos[16 +: CW]};
        dx = px - tx;
        dy = py - ty;
        cx = dx >> sc;                           // position in unscaled font pixels
        cy = dy >> sc;
        in_txt = c[0] && px >= tx && py >= ty && cy < 6 && (cx >> 2) < (CW+1)'(len) + (c[4] ? (CW+1)'(nd) : '0);
        if ((cx >> 2) < (CW+1)'(len)) ch = ccur[j*128 + 8 * cx[5:2] +: 8];
        else ch = 8'h30 + 8'(fcur[4 * (32'(nd) - 1 - (32'(cx >> 2) - 32'(len))) +: 4]);   // frame number digit
        g = overlay_font_pkg::glyph(ch);
        on = in_txt && cx[1:0] != 2'd3 && cy < 5 && g[5'(cy[2:0]) * 5'd3 + 5'(cx[1:0])];
        if (j < NTXT) begin
          if (on) pix_t = col[23:0];
          else if (in_txt && c[3]) pix_t = {1'b0, pix_t[23:17], 1'b0, pix_t[15:9], 1'b0, pix_t[7:1]};   // backdrop
        end
      end
    end
  end

  // ---------------- output register stage
  assign s_axis.tready = !m_axis.tvalid || m_axis.tready;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      x <= '0;
      y <= '0;
      act <= '0;
      act_en <= 1'b0;
      tact <= '0;
      cact <= '0;
      fnum <= '0;
      fnum_set <= '0;
      fnum_pend <= 1'b0;
      pending <= 1'b0;
      frames <= '0;
      m_axis.tvalid <= 1'b0;
      m_axis.tdata <= '0;
      m_axis.tlast <= 1'b0;
      m_axis.tuser <= 1'b0;
    end else begin
      if (take) begin
        act <= cur;
        act_en <= cur_en;
        tact <= tcur;
        cact <= ccur;
        fnum <= fcur;
        frames <= frames + 1'b1;
      end
      // COMMIT write sets pending; a frame start with pending applies it (a commit in that same
      // clock waits for the next frame start)
      if (commit_wr && commit_d) pending <= 1'b1;
      else if (take) pending <= 1'b0;
      if (fnum_wr) begin                           // a write in the clock of a frame start waits for the next one
        fnum_set <= fnum_d;
        fnum_pend <= 1'b1;
      end else if (take) fnum_pend <= 1'b0;
      if (in_beat) begin
        if (s_axis.tlast) begin
          x <= '0;
          y <= CW'(py + 1'b1);
        end else begin
          x <= CW'(px + 1'b1);
          y <= CW'(py);
        end
        m_axis.tdata <= pix_t;
        m_axis.tlast <= s_axis.tlast;
        m_axis.tuser <= s_axis.tuser;
        m_axis.tvalid <= 1'b1;
      end else if (m_axis.tready) m_axis.tvalid <= 1'b0;
    end
  end

endmodule
