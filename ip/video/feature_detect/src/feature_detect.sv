// ***************
// Filename: feature_detect.sv
// Author: FPGA Cores 4 U
// Description: Edge, motion and sky features of an AXI4-Stream video (24-bit
//   pixels {B, G, R}, tuser = start of frame, tlast = end of line) for
//   object detectors. Version 2.0.0. A tap on the accepted beats of s_axis
//   (tvalid & tready; it never stalls the stream): every beat is forwarded
//   on m_axis two clocks later (tvalid one clock per beat; m_axis.tready is
//   not used) with feat_o, the feature bits of that pixel ([0] edge, [1]
//   motion; 0 while the frame is not processed), so object_tracker
//   detectors watching m_axis get the bits with their beat. Golden model:
//   ip/video/feature_detect/model/feature_detect_model.py (its header
//   defines every bit and register; tb/python compares them).
//     - A frame is processed when CTRL.EN is set at its start; CTRL, EDGE,
//       MOTION, SHIFT and SKY_CFG are taken at the frame start. FRAME_SIZE
//       must be the frame's size (the frame end and the cells come from it).
//     - Luma Y = (R + 2 G + B) / 4: a shift-add approximation of BT.601 luma
//       (ITU-R BT.601-7: 0.299 R + 0.587 G + 0.114 B); blue weighs 0.25
//       instead of 0.114, so blue objects look brighter to the tests.
//     - Edge (feat_o[0]): the Sobel |Gx| + |Gy| of the 3 x 3 window ending
//       at the pixel (rows y - 2 .. y, columns x - 2 .. x; x, y >= 2) above
//       EDGE.THRESH, filled along the line over EDGE.SPAN pixels.
//     - Motion (feat_o[1]): cells of 2^CELL_LOG2 pixels square (cw = width >>
//       CELL_LOG2 by ch = height >> CELL_LOG2); per cell the lowest / highest
//       luma x 16 in two background banks (one read during a frame, the
//       other written; they swap at the frame end); a pixel moves when the
//       background is valid, its source cell (cx - sx, cy - sy) is in the
//       frame and its luma is below lo / 16 - MOTION.THRESH or above hi /
//       16 + MOTION.THRESH; filled over MOTION.SPAN. At its last pixel each
//       cell is written: old + (new - old) >>> MOTION.RATE of its source,
//       or the new values without a valid source. The first frame after a
//       restart only fills the background.
//     - Camera shift: column / row luma profiles per cell column / cell row
//       in three rotating banks; after a frame with a previous one a search
//       (per axis the shift -SHIFT_MAX .. SHIFT_MAX with the lowest sum of
//       |cur[i] - prev[i - s]| over i = SHIFT_MAX .. n - 1 - SHIFT_MAX; 0
//       first, a later shift only when strictly lower; one term per clock,
//       STATUS.BUSY) runs during the next frame -> SHIFT_EST; with
//       CTRL.AUTO_SHIFT a frame uses the estimate of the search that ended
//       two frames before it (the search after frame N, frame N + 2), else
//       SHIFT.
//     - Sky: per column group of 2^SKY_CFG.SHIFT pixels (32 groups) the lines
//       from the top to its first pixel with the edge bit or a luma below
//       SKY_CFG.Y_MIN (the frame height when none) -> SKY[0..31].
//     - Restart (a CTRL write with RESTART, or a FRAME_SIZE write): at the
//       next frame start the background, profiles and shift start again.
//     - Per frame EDGE_COUNT, MOTION_COUNT, FRAMES; done_o pulses once a
//       frame's results and its shift search are complete.
//   Memories: the luma line buffer, the background banks and the column
//   profiles are read with a registered read (block RAM); cell addresses
//   are counted, not multiplied. Limits: frames of at least SHIFT_MAX + 2
//   cells each way and more beats than the search's clocks (about (2
//   SHIFT_MAX + 1) (cw + ch)); CELL_LOG2 >= 1.
//   Registers on the cfg_* / sts_* ports; feature_detect_top.sv is the block
//   with its AXI4-Lite register map (src/include/feature_detect_regs.sv,
//   ADDR_W = 8): ID "FEAT" / VERSION / DATE at 0x00-0x08, CTRL 0x18,
//   FRAME_SIZE 0x1C, EDGE 0x20, MOTION 0x24, SHIFT 0x28, SHIFT_EST 0x2C,
//   STATUS 0x30, FRAMES 0x34, EDGE_COUNT 0x38, MOTION_COUNT 0x3C,
//   SHIFT_USED 0x40, SKY_CFG 0x44, SKY 0x80 + 4 i.
//   Clock - clk (pixel clock). Reset - synchronous active low rst_n.
// Date: 2026-10-21
module feature_detect #(
  parameter int MAXW      = 2048,                // longest line (luma line buffer)
  parameter int MAXH      = 1152,                // most lines (background cells)
  parameter int CELL_LOG2 = 2,                   // background cell: 2^CELL_LOG2 pixels square (>= 1)
  parameter int SHIFT_MAX = 4,                   // camera shift searched: +- cells
  parameter int CW        = 16                   // coordinate width
) (
  input  logic        clk,
  input  logic        rst_n,
  // the observed video
  // s_axis: axis_if.monitor (ip/shared/src/interfaces/axis_if.sv), DATA_W = 24
  axis_if.monitor s_axis,
  // the beats again, two clocks later (m_axis.tready is not used)
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = 24
  axis_if.master m_axis,
  output logic [1:0]  feat_o,                    // features of the m_axis beat: [0] edge, [1] motion
  output logic        done_o,                    // one clock: a frame's results and shift search complete
  // register ports
  // regs: feature_detect_regs_if.core (src/include/feature_detect_regs_if.sv)
  feature_detect_regs_if.core regs
);
  if (CELL_LOG2 < 1) begin : g_bad_cell $error("feature_detect: CELL_LOG2 must be >= 1"); end
  localparam int CELL  = 1 << CELL_LOG2;
  localparam int NCX   = MAXW >> CELL_LOG2;      // cells per line, lines of cells (at most)
  localparam int NCY   = MAXH >> CELL_LOG2;
  localparam int NCELL = NCX * NCY;
  localparam int AW    = $clog2(NCELL);
  localparam int XW    = $clog2(MAXW);
  localparam int CXW   = $clog2(NCX);            // profile addresses
  localparam int CYW   = $clog2(NCY);
  localparam int PW    = 32;                     // profile sums
  localparam int SG    = CW + 2;                 // signed cell arithmetic
  assign m_axis.tkeep = '1;      // not used by this block
  wire unused_tready = &{1'b0, m_axis.tready, s_axis.tkeep, 1'b0};

  // ---------------- the configuration (taken at the frame start)
  wire          frame_wr = regs.cfg_frame_size_wr;
  wire [CW-1:0] frame_w  = regs.cfg_frame_size[CW-1:0];
  wire [CW-1:0] frame_h  = regs.cfg_frame_size[16 +: CW];
  wire [CW-1:0] cw = frame_w >> CELL_LOG2;       // cells of this frame size
  wire [CW-1:0] ch = frame_h >> CELL_LOG2;
  logic         f_act, f_edge, f_mot, f_auto;    // this frame: processed, edge, motion, auto shift
  logic [10:0]  f_et;
  logic [3:0]   f_esp, f_msp, f_sksh;
  logic [7:0]   f_mt, f_skmin;
  logic [2:0]   f_rate;
  logic         restart_pend;

  // ---------------- position of the presented beat
  wire          beat = s_axis.tvalid && s_axis.tready;
  logic [CW-1:0] x, y;
  wire  [CW-1:0] px = s_axis.tuser ? '0 : x;
  wire  [CW-1:0] py = s_axis.tuser ? '0 : y;
  wire  [CW-1:0] cx = px >> CELL_LOG2;
  wire  [CW-1:0] cy = py >> CELL_LOG2;
  wire           in_cells = cx < cw && cy < ch;
  wire  [7:0]    luma = 8'((10'(s_axis.tdata[7:0]) + {1'b0, s_axis.tdata[15:8], 1'b0} + 10'(s_axis.tdata[23:16])) >> 2);
  // processed: this frame (the start's decision for a tuser beat)
  wire           act0 = s_axis.tuser ? regs.cfg_ctrl[0] : f_act;
  wire           restart_now = s_axis.tuser && regs.cfg_ctrl[0] && restart_pend;

  // ---------------- the shift of the frame and the cell addresses (counted)
  logic                 bg_valid;
  logic signed [7:0]    sh_x, sh_y, sh_next_x, sh_next_y;
  logic [AW-1:0]        dbase;                   // first cell of the beat's cell row (cy * cw)
  logic signed [AW+1:0] soff;                    // sy * cw of this frame
  wire  signed [7:0] fsx = s_axis.tuser ? (regs.cfg_ctrl[3] ? (restart_now ? 8'sd0 : sh_next_x) :
                                           $signed(regs.cfg_shift[7:0])) : sh_x;
  wire  signed [7:0] fsy = s_axis.tuser ? (regs.cfg_ctrl[3] ? (restart_now ? 8'sd0 : sh_next_y) :
                                           $signed(regs.cfg_shift[15:8])) : sh_y;
  wire  [AW-1:0]        dbase0 = s_axis.tuser ? '0 : dbase;
  wire  signed [AW+1:0] soff0 = s_axis.tuser ? (AW+2)'($signed(fsy) * $signed({1'b0, cw})) : soff;
  wire  signed [SG-1:0] scx = $signed({2'b0, cx}) - SG'(fsx);
  wire  signed [SG-1:0] scy = $signed({2'b0, cy}) - SG'(fsy);
  wire                  bgv0 = bg_valid && !restart_now;
  wire                  src_ok0 = bgv0 && in_cells && scx >= 0 && scx < $signed({2'b0, cw}) && scy >= 0 &&
                                  scy < $signed({2'b0, ch});
  wire  [AW-1:0]        src_a = AW'($signed({2'b0, dbase0}) - soff0 + (AW+2)'(scx));
  wire  [AW-1:0]        dst_a = dbase0 + AW'(cx);

  // ---------------- memories (registered reads)
  logic rb;                                      // background bank read this frame
  logic eof1;                                    // stage 1 holds a frame's last pixel this clock
  wire  rb0 = eof1 ? ~rb : rb;                   // (the bank swap of a frame ending in this clock)
  logic [15:0] lbuf [MAXW];                      // {line y - 2, line y - 1} per column
  logic [23:0] bank0 [NCELL];                    // {hi, lo} x 16 per cell
  logic [23:0] bank1 [NCELL];
  logic [15:0] lb_q;
  logic [23:0] b0_q, b1_q;                       // each bank's read register (block RAM output)
  logic        rb_q;                             // the bank read in the last clock
  wire  [23:0] bg_q = rb_q ? b1_q : b0_q;
  logic        lb_we, bk_we;                     // stage 1 writes
  logic [XW-1:0] lb_wa;
  logic [15:0] lb_wd;
  logic [AW-1:0] bk_wa;
  logic [23:0] bk_wd;
  logic        bk_wsel;
  // the memories and their read registers are not reset: a line, cell or profile is written by its
  // frame before it is read (edges from line 2, the background once BG_VALID, the search after a frame)
  always_ff @(posedge clk) begin
    lb_q <= lbuf[XW'(px)];
    if (lb_we) lbuf[lb_wa] <= lb_wd;
  end
  always_ff @(posedge clk) begin                 // one memory per block, so each maps to block RAM
    b0_q <= bank0[src_a];
    if (bk_we && !bk_wsel) bank0[bk_wa] <= bk_wd;
  end
  always_ff @(posedge clk) begin
    b1_q <= bank1[src_a];
    if (bk_we && bk_wsel) bank1[bk_wa] <= bk_wd;
  end
  always_ff @(posedge clk)
    if (!rst_n) rb_q <= 1'b0;
    else rb_q <= rb0;
  // column profiles: three rotating banks (each one memory: a write port for the pixels, a read port for
  // the pixels' bank or the search)
  logic [PW-1:0] colp [3][NCX];
  logic [PW-1:0] rowp [3][NCY];
  logic [1:0]    pw_b, pl_b, pp_b;               // banks: written now, the last frame, the one before
  logic [1:0]    sl_b, sp_b;                     // banks searched: the frame, its previous one
  logic [CW-1:0] sr_cur, sr_prev;                // search read addresses
  logic          sr_axis;
  logic [PW-1:0] cp_q [3];
  logic [PW-1:0] rp_q [3];
  logic          cp_we, rp_we;
  logic [1:0]    cp_wb, rp_wb;                   // the bank of the write (the banks rotate at a frame end)
  logic [CXW-1:0] cp_wa;
  logic [CYW-1:0] rp_wa;
  logic [PW-1:0] cp_wd, rp_wd;
  for (genvar b = 0; b < 3; b++) begin : g_prof
    wire [CXW-1:0] ca = CXW'((pw_b == 2'(b)) ? cx : ((sl_b == 2'(b)) ? sr_cur : sr_prev));
    wire [CYW-1:0] ra = CYW'((sl_b == 2'(b)) ? sr_cur : sr_prev);
    always_ff @(posedge clk) begin
      cp_q[b] <= colp[b][ca];
      rp_q[b] <= rowp[b][ra];
      if (cp_we && cp_wb == 2'(b)) colp[b][cp_wa] <= cp_wd;
      if (rp_we && rp_wb == 2'(b)) rowp[b][rp_wa] <= rp_wd;
    end
  end

  // ---------------- stage 1: the beat with its memory data
  logic          v1, a1, u1, l1, cin1, sok1;     // valid, processed, tuser, tlast, in cells, source valid
  logic [23:0]   d1;
  logic [7:0]    y1l;                            // luma
  logic [CW-1:0] px1, py1;
  logic [CXW-1:0] cx1;                           // (inside the cells: below NCX / NCY)
  logic [CYW-1:0] cy1;
  logic [AW-1:0] dst1;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      v1 <= 1'b0;
      a1 <= 1'b0;
      u1 <= 1'b0;
      l1 <= 1'b0;
      cin1 <= 1'b0;
      sok1 <= 1'b0;
      d1 <= '0;
      y1l <= '0;
      px1 <= '0;
      py1 <= '0;
      cx1 <= '0;
      cy1 <= '0;
      dst1 <= '0;
    end else begin
      v1 <= beat;
      a1 <= beat && act0;
      u1 <= s_axis.tuser;
      l1 <= s_axis.tlast;
      cin1 <= in_cells;
      sok1 <= src_ok0;
      d1 <= s_axis.tdata;
      y1l <= luma;
      px1 <= px;
      py1 <= py;
      cx1 <= CXW'(cx);
      cy1 <= CYW'(cy);
      dst1 <= dst_a;
    end
  end
  // edge: the 3 x 3 window (columns x - 2, x - 1 in registers, column x from the line buffer)
  logic [7:0] t1, t2, m1, m2, b1, b2;
  wire  [7:0] t0 = lb_q[15:8];
  wire  [7:0] m0 = lb_q[7:0];
  wire  [7:0] b0 = y1l;
  wire signed [12:0] gx = $signed(13'(t0) + 13'({m0, 1'b0}) + 13'(b0)) - $signed(13'(t2) + 13'({m2, 1'b0}) + 13'(b2));
  wire signed [12:0] gy = $signed(13'(b2) + 13'({b1, 1'b0}) + 13'(b0)) - $signed(13'(t2) + 13'({t1, 1'b0}) + 13'(t0));
  wire [12:0] mag = 13'(gx < 0 ? -gx : gx) + 13'(gy < 0 ? -gy : gy);
  wire        e_raw = a1 && f_edge && px1 >= 2 && py1 >= 2 && mag > 13'(f_et);
  logic [4:0] e_since, m_since;                  // pixels since the last raw bit, before this one (16: none)
  wire  [4:0] e_prev = (px1 == 0) ? 5'd16 : e_since;
  wire        e_bit = a1 && (e_raw || (e_prev + 5'd1 < 5'(f_esp)));   // (0 when not processed)
  // motion
  wire  [11:0] bg_lo = bg_q[11:0];
  wire  [11:0] bg_hi = bg_q[23:12];
  wire         m_raw = a1 && f_mot && sok1 &&
                       ($signed({2'b0, y1l}) < $signed({2'b0, bg_lo[11:4]}) - $signed({2'b0, f_mt}) ||
                        $signed({2'b0, y1l}) > $signed({2'b0, bg_hi[11:4]}) + $signed({2'b0, f_mt}));
  wire  [4:0]  m_prev = (px1 == 0) ? 5'd16 : m_since;
  wire         m_bit = a1 && (m_raw || (m_prev + 5'd1 < 5'(f_msp)));
  // this frame's lowest / highest luma per cell column (the cell row being scanned)
  logic [7:0] cmin [NCX];
  logic [7:0] cmax [NCX];
  wire        c_first = py1[CELL_LOG2-1:0] == 0 && px1[CELL_LOG2-1:0] == 0;
  wire        c_last = &py1[CELL_LOG2-1:0] && &px1[CELL_LOG2-1:0];
  wire  [7:0] n_min = (c_first || y1l < cmin[cx1]) ? y1l : cmin[cx1];
  wire  [7:0] n_max = (c_first || y1l > cmax[cx1]) ? y1l : cmax[cx1];
  wire signed [13:0] d_lo = $signed({2'b0, n_min, 4'b0}) - $signed({2'b0, bg_lo});
  wire signed [13:0] d_hi = $signed({2'b0, n_max, 4'b0}) - $signed({2'b0, bg_hi});
  wire  [11:0] w_lo = sok1 ? 12'($signed({2'b0, bg_lo}) + (d_lo >>> f_rate)) : {n_min, 4'b0};
  wire  [11:0] w_hi = sok1 ? 12'($signed({2'b0, bg_hi}) + (d_hi >>> f_rate)) : {n_max, 4'b0};
  // profiles: a cell's pixels on a line summed, then added to its column (one read and one write per cell)
  logic [PW-1:0] cacc, chold, racc;
  wire           cl_first = px1[CELL_LOG2-1:0] == 0;
  wire           cl_last = &px1[CELL_LOG2-1:0];
  wire  [PW-1:0] cacc_n = (cl_first ? PW'(0) : cacc) + PW'(y1l);
  wire  [PW-1:0] chold_n = cl_first ? ((py1 == 0) ? PW'(0) : cp_q[pw_b]) : chold;
  wire           row_first = py1[CELL_LOG2-1:0] == 0 && px1 == 0;
  wire  [PW-1:0] racc_n = (row_first ? PW'(0) : racc) + PW'(y1l);
  wire           row_last = &py1[CELL_LOG2-1:0] && px1 == (cw << CELL_LOG2) - 1'b1;
  wire           eof = l1 && py1 == frame_h - 1'b1;
  assign eof1 = v1 && a1 && eof;
  // sky: the first line of each column group with an edge or a dark pixel
  logic [CW-1:0] sky_first [32];
  wire  [CW-1:0] sky_g = px1 >> f_sksh;
  wire           sky_hit = e_bit || y1l < f_skmin;

  // ---------------- shift search: issue (reads) one clock ahead of the accumulation
  typedef enum logic [1:0] {S_IDLE, S_RUN, S_DONE} st_e;
  st_e st;
  logic signed [7:0] s_cur;
  logic [CW-1:0] s_i, n_c, n_r;
  logic          s_iss, s_iss_end, s_iss_lastsh;  // stage 2: a term read, the shift's last, the axis' last shift
  logic signed [7:0] s_iss_s;
  logic          s_iss_axis;
  logic [PW-1:0] s_acc, s_best;
  logic signed [7:0] s_bs;
  wire  [CW-1:0] s_n = sr_axis ? n_r : n_c;
  wire           s_end_i = 32'(s_i) + 1 >= 32'(s_n) - SHIFT_MAX;   // the last term of this shift
  assign sr_cur = s_i;
  assign sr_prev = CW'($signed({1'b0, s_i}) - s_cur);
  wire  [PW-1:0] s_cv = s_iss_axis ? rp_q[sl_b] : cp_q[sl_b];
  wire  [PW-1:0] s_pv = s_iss_axis ? rp_q[sp_b] : cp_q[sp_b];
  wire  [PW-1:0] s_ad = (s_cv > s_pv) ? s_cv - s_pv : s_pv - s_cv;
  wire  [PW-1:0] s_tot = s_acc + s_ad;
  wire           s_better = (s_iss_s == 0) || s_tot < s_best;
  wire signed [7:0] s_res = s_better ? s_iss_s : s_bs;
  function automatic logic signed [7:0] next_s(input logic signed [7:0] s);
    if (s == 0) return -8'(SHIFT_MAX);
    if (s == -1) return 8'sd1;
    return s + 8'sd1;
  endfunction

  // ---------------- counts, state
  logic [31:0] cnt_e, cnt_m, frames;
  logic in_frame, have_last;
  logic [15:0] sky_out [32];
  assign regs.sts_frames = frames;
  assign regs.sts_status = {frames[15:0], 13'd0, st != S_IDLE, bg_valid, in_frame};
  assign regs.sts_shift_used = {16'd0, 8'(sh_y), 8'(sh_x)};
  for (genvar g = 0; g < 32; g++) begin : g_sky_out
    assign regs.sts_sky[g*16 +: 16] = sky_out[g];
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      x <= '0;
      y <= '0;
      dbase <= '0;
      soff <= '0;
      {f_act, f_edge, f_mot, f_auto} <= '0;
      f_et <= '0;
      {f_esp, f_msp, f_sksh} <= '0;
      {f_mt, f_skmin} <= '0;
      f_rate <= '0;
      restart_pend <= 1'b0;
      {t1, t2, m1, m2, b1, b2} <= '0;
      e_since <= 5'd16;
      m_since <= 5'd16;
      rb <= 1'b0;
      bg_valid <= 1'b0;
      {sh_x, sh_y, sh_next_x, sh_next_y} <= '0;
      pw_b <= 2'd0;
      pl_b <= 2'd1;
      pp_b <= 2'd2;
      {sl_b, sp_b} <= '0;
      have_last <= 1'b0;
      {cacc, chold, racc} <= '0;
      lb_we <= 1'b0;
      lb_wa <= '0;
      lb_wd <= '0;
      bk_we <= 1'b0;
      bk_wa <= '0;
      bk_wd <= '0;
      bk_wsel <= 1'b0;
      cp_we <= 1'b0;
      cp_wb <= '0;
      cp_wa <= '0;
      cp_wd <= '0;
      rp_we <= 1'b0;
      rp_wb <= '0;
      rp_wa <= '0;
      rp_wd <= '0;
      st <= S_IDLE;
      sr_axis <= 1'b0;
      s_cur <= '0;
      s_i <= '0;
      {n_c, n_r} <= '0;
      s_iss <= 1'b0;
      s_iss_end <= 1'b0;
      s_iss_lastsh <= 1'b0;
      s_iss_s <= '0;
      s_iss_axis <= 1'b0;
      s_acc <= '0;
      s_best <= '0;
      s_bs <= '0;
      regs.sts_shift_est <= '0;
      {cnt_e, cnt_m, frames} <= '0;
      regs.sts_edge_count <= '0;
      regs.sts_motion_count <= '0;
      in_frame <= 1'b0;
      done_o <= 1'b0;
      for (int g = 0; g < 32; g++) begin
        sky_first[g] <= '1;
        sky_out[g] <= '0;
      end
      m_axis.tvalid <= 1'b0;
      m_axis.tdata <= '0;
      m_axis.tlast <= 1'b0;
      m_axis.tuser <= 1'b0;
      feat_o <= '0;
    end else begin
      done_o <= 1'b0;
      lb_we <= 1'b0;
      bk_we <= 1'b0;
      cp_we <= 1'b0;
      rp_we <= 1'b0;
      if ((regs.cfg_ctrl_wr && regs.cfg_ctrl[4]) || frame_wr) restart_pend <= 1'b1;
      // ---------------- stage 0: the accepted beat
      if (beat) begin
        if (s_axis.tlast) begin
          x <= '0;
          y <= py + 1'b1;
          dbase <= (((py + 1'b1) & CW'(CELL - 1)) == '0) ? dbase0 + AW'(cw) : dbase0;
        end else begin
          x <= px + 1'b1;
          y <= py;
          dbase <= dbase0;
        end
        if (s_axis.tuser) begin                  // the frame start: its configuration and shift
          f_act <= regs.cfg_ctrl[0];
          if (regs.cfg_ctrl[0]) begin
            f_edge <= regs.cfg_ctrl[1];
            f_mot <= regs.cfg_ctrl[2];
            f_auto <= regs.cfg_ctrl[3];
            f_et <= regs.cfg_edge[10:0];
            f_esp <= regs.cfg_edge[19:16];
            f_mt <= regs.cfg_motion[7:0];
            f_msp <= regs.cfg_motion[11:8];
            f_rate <= regs.cfg_motion[14:12];
            f_sksh <= regs.cfg_sky_cfg[3:0];
            f_skmin <= regs.cfg_sky_cfg[15:8];
            sh_x <= fsx;
            sh_y <= fsy;
            soff <= soff0;
            in_frame <= 1'b1;
          end
        end
      end
      // ---------------- stage 1
      m_axis.tvalid <= v1;
      m_axis.tdata <= d1;
      m_axis.tlast <= l1;
      m_axis.tuser <= u1;
      feat_o <= {m_bit, e_bit};
      if (v1) begin
        lb_we <= 1'b1;                           // the line buffer: this line becomes line y - 1
        lb_wa <= XW'(px1);
        lb_wd <= {m0, y1l};
        t2 <= t1;
        t1 <= t0;
        m2 <= m1;
        m1 <= m0;
        b2 <= b1;
        b1 <= b0;
      end
      if (a1) begin
        e_since <= e_raw ? 5'd0 : (e_prev == 5'd16 ? 5'd16 : e_prev + 5'd1);
        m_since <= m_raw ? 5'd0 : (m_prev == 5'd16 ? 5'd16 : m_prev + 5'd1);
        if (cin1) begin                          // cells, background, profiles
          cmin[cx1] <= n_min;
          cmax[cx1] <= n_max;
          if (c_last) begin
            bk_we <= 1'b1;
            bk_wa <= dst1;
            bk_wd <= {w_hi, w_lo};
            bk_wsel <= ~rb;
          end
          cacc <= cacc_n;
          chold <= chold_n;
          if (cl_last) begin
            cp_we <= 1'b1;
            cp_wb <= pw_b;
            cp_wa <= cx1;
            cp_wd <= chold_n + cacc_n;
          end
          racc <= racc_n;
          if (row_last) begin
            rp_we <= 1'b1;
            rp_wb <= pw_b;
            rp_wa <= cy1;
            rp_wd <= racc_n;
          end
        end
        for (int g = 0; g < 32; g++)             // sky (a frame start: every group again)
          if (u1) sky_first[g] <= (sky_hit && sky_g == CW'(g)) ? py1 : '1;
          else if (sky_hit && sky_g == CW'(g) && sky_first[g] == '1) sky_first[g] <= py1;
        cnt_e <= (u1 ? 32'd0 : cnt_e) + 32'(e_bit);
        cnt_m <= (u1 ? 32'd0 : cnt_m) + 32'(m_bit);
        if (eof) begin                           // the frame's end
          regs.sts_edge_count <= (u1 ? 32'd0 : cnt_e) + 32'(e_bit);
          regs.sts_motion_count <= (u1 ? 32'd0 : cnt_m) + 32'(m_bit);
          frames <= frames + 1'b1;
          in_frame <= 1'b0;
          rb <= ~rb;
          bg_valid <= 1'b1;
          for (int g = 0; g < 32; g++) begin
            logic [CW-1:0] f;
            f = (u1 && !(sky_hit && sky_g == CW'(g))) ? '1 : sky_first[g];
            if (sky_hit && sky_g == CW'(g) && f == '1) f = py1;
            sky_out[g] <= (f == '1) ? 16'(frame_h) : 16'(f);
          end
          pw_b <= pp_b;                          // profiles: this frame becomes the last, the last the previous
          pl_b <= pw_b;
          pp_b <= pl_b;
          have_last <= 1'b1;
          sh_next_x <= $signed(regs.sts_shift_est[7:0]);   // the last search's result: for the next frame
          sh_next_y <= $signed(regs.sts_shift_est[15:8]);
          if (have_last) begin                   // search this frame against the last one
            st <= S_RUN;
            sr_axis <= 1'b0;
            s_cur <= '0;
            s_i <= CW'(SHIFT_MAX);
            sl_b <= pw_b;
            sp_b <= pl_b;
            n_c <= cw;
            n_r <= ch;
          end else done_o <= 1'b1;
        end
      end
      // ---------------- shift search: issue a term's reads, accumulate it a clock later
      s_iss <= 1'b0;
      if (st == S_RUN) begin
        if (32'(s_n) < 32'(2 * SHIFT_MAX + 1)) begin   // too few cells to compare: no shift
          if (sr_axis) begin
            regs.sts_shift_est[15:8] <= '0;
            st <= S_DONE;
          end else begin
            regs.sts_shift_est[7:0] <= '0;
            sr_axis <= 1'b1;
          end
        end else begin
          s_iss <= 1'b1;
          s_iss_end <= s_end_i;
          s_iss_lastsh <= s_cur == 8'(SHIFT_MAX);
          s_iss_s <= s_cur;
          s_iss_axis <= sr_axis;
          if (!s_end_i) s_i <= s_i + 1'b1;
          else begin
            s_i <= CW'(SHIFT_MAX);
            if (s_cur == 8'(SHIFT_MAX)) begin    // the axis' last term issued
              s_cur <= '0;
              if (sr_axis) st <= S_DONE;
              else sr_axis <= 1'b1;
            end else s_cur <= next_s(s_cur);
          end
        end
      end
      if (s_iss) begin
        if (!s_iss_end) s_acc <= s_tot;
        else begin                               // a shift's sum is complete
          s_acc <= '0;
          if (s_better) begin
            s_best <= s_tot;
            s_bs <= s_iss_s;
          end
          if (s_iss_lastsh) begin                // the axis' result
            if (s_iss_axis) regs.sts_shift_est[15:8] <= 8'(s_res);
            else regs.sts_shift_est[7:0] <= 8'(s_res);
          end
        end
      end
      if (st == S_DONE && !s_iss) begin
        st <= S_IDLE;
        done_o <= 1'b1;
      end
      // ---------------- a restart at this frame start (wins over a frame end in the same clock)
      if (beat && restart_now) begin
        restart_pend <= (regs.cfg_ctrl_wr && regs.cfg_ctrl[4]) || frame_wr;
        bg_valid <= 1'b0;
        have_last <= 1'b0;
        sh_next_x <= '0;
        sh_next_y <= '0;
        regs.sts_shift_est <= '0;
        st <= S_IDLE;
        s_iss <= 1'b0;
        s_acc <= '0;
        done_o <= 1'b0;
      end
    end
  end
  // not used: the frame's mode (kept with its configuration), the registers' write pulses (they act by value at
  // a frame start) and their unused bits
  wire unused_cfg = &{1'b0, f_auto, regs.cfg_ctrl[31:5], regs.cfg_edge[31:20], regs.cfg_edge[15:11],
                      regs.cfg_motion[31:15], regs.cfg_shift[31:16], regs.cfg_sky_cfg[7:4], regs.cfg_edge_wr,
                      regs.cfg_motion_wr, regs.cfg_shift_wr, regs.cfg_sky_cfg_wr, 1'b0};
endmodule
