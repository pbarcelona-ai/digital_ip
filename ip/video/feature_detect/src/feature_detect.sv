// ***************
// Filename: feature_detect.sv
// Author: FPGA Cores 4 U
// Description: Edge and motion features of an AXI4-Stream video (24-bit
//   pixels {B, G, R}, tuser = start of frame, tlast = end of line) for
//   object detectors. A passive tap on the accepted beats (tvalid &
//   tready): it never touches the stream. For every beat it gives two
//   feature bits of that pixel (feat_o, the same clock: combinational from
//   the beat and the stored state), which object_tracker detectors watching
//   the same stream combine with their own luma / colour tests.
//     - Luma Y = (R + 2 G + B) / 4.
//     - Edge (feat_o[0]): the 3 x 3 Sobel magnitude |Gx| + |Gy| of the
//       window centred one line and one pixel behind the beat (rows y - 2 ..
//       y, columns x - 2 .. x: two line buffers of luma) is above
//       EDGE.THRESH (pixels with x < 2 or y < 2: none); then filled along the
//       line: the bit is set when an edge was found in the last EDGE.SPAN
//       pixels of the line (0 or 1: the pixel itself), so a textured object
//       gives solid runs.
//     - Motion (feat_o[1]): a background of 2^CELL_LOG2-pixel square cells
//       (cw = width >> CELL_LOG2 by ch = height >> CELL_LOG2 cells; pixels
//       past them never move), per cell the lowest and the highest luma
//       with 4 fraction bits, in two banks: one read during a frame, the
//       other written; they swap at the frame end. A pixel in cell (cx, cy)
//       moves when the background is valid, the cell it came from, (cx -
//       sx, cy - sy) with the shift (sx, sy) in effect (taken at the frame
//       start), is in the frame, and its luma is below lo - MOTION.THRESH or
//       above hi + MOTION.THRESH (integer parts of the source cell); filled
//       along the line with MOTION.SPAN like the edges. At its last pixel
//       every cell is written: old + (new - old) >>> MOTION.RATE of its
//       source cell (new: the cell's lowest / highest luma of this frame,
//       x 16), or the new values when there is no valid source. The first
//       frame after CTRL.RESTART (or reset) only fills the background.
//     - Camera shift: the column and row luma profiles (sums of the luma
//       per cell column / cell row, over the cells) of each frame are kept
//       in three rotating banks. After a frame (with a previous one) a
//       search compares them with the previous frame's: per axis the shift
//       s in -SHIFT_MAX .. SHIFT_MAX with the lowest sum over i = SHIFT_MAX ..
//       n - 1 - SHIFT_MAX of |cur[i] - prev[i - s]| (s = 0 first, a later s
//       only when strictly lower), one term per clock (STATUS.BUSY), into
//       SHIFT_EST; with CTRL.AUTO_SHIFT it becomes the shift of the next
//       frame that starts after the search, else SHIFT (written by the CPU)
//       is used.
//     - Per frame EDGE_COUNT and MOTION_COUNT (pixels with the filled bit
//       set) and FRAMES; done_o pulses once a frame's results and its shift
//       search are complete.
//   Registers on the cfg_* / sts_* ports; feature_detect_top.sv is the block
//   with its AXI4-Lite register map (src/include/feature_detect_regs.sv,
//   ADDR_W = 8): ID "FEAT" / VERSION / DATE at 0x00-0x08, CTRL 0x18,
//   FRAME_SIZE 0x1C, EDGE 0x20, MOTION 0x24, SHIFT 0x28, SHIFT_EST 0x2C,
//   STATUS 0x30, FRAMES 0x34, EDGE_COUNT 0x38, MOTION_COUNT 0x3C,
//   SHIFT_USED 0x40.
//   Clock - clk (pixel clock). Reset - synchronous active low rst_n.
// Date: 2026-10-14
module feature_detect #(
  parameter int MAXW      = 2048,                // longest line (luma line buffers)
  parameter int MAXH      = 1152,                // most lines (background cells)
  parameter int CELL_LOG2 = 3,                   // background cell: 2^CELL_LOG2 pixels square
  parameter int SHIFT_MAX = 4,                   // camera shift searched: +- cells
  parameter int CW        = 16                   // coordinate width
) (
  input  logic        clk,
  input  logic        rst_n,
  // video tap (observed only)
  // s_axis: axis_if.monitor (ip/shared/src/interfaces/axis_if.sv), DATA_W = 24
  axis_if.monitor s_axis,
  output logic [1:0]  feat_o,                    // features of the current beat: [0] edge, [1] motion
  output logic        done_o,                    // one clock: a frame's counts and shift search complete
  // register ports
  // regs: feature_detect_regs_if.core (src/include/feature_detect_regs_if.sv)
  feature_detect_regs_if.core regs
);
  localparam int CELL = 1 << CELL_LOG2;
  localparam int NCX = MAXW >> CELL_LOG2;        // cells per line, lines of cells (at most)
  localparam int NCY = MAXH >> CELL_LOG2;
  localparam int NCELL = NCX * NCY;
  localparam int PW = 32;                        // profile sums

  wire          en       = regs.cfg_ctrl[0];
  wire          edge_en  = regs.cfg_ctrl[1];
  wire          mot_en   = regs.cfg_ctrl[2];
  wire          auto_sh  = regs.cfg_ctrl[3];
  wire          restart  = regs.cfg_ctrl_wr && regs.cfg_ctrl[4];
  wire [CW-1:0] frame_w  = regs.cfg_frame_size[CW-1:0];
  wire [CW-1:0] frame_h  = regs.cfg_frame_size[16 +: CW];
  wire [10:0]   edge_t   = regs.cfg_edge[10:0];
  wire [3:0]    edge_sp  = regs.cfg_edge[19:16];
  wire [7:0]    mot_t    = regs.cfg_motion[7:0];
  wire [3:0]    mot_sp   = regs.cfg_motion[11:8];
  wire [2:0]    rate     = regs.cfg_motion[14:12];

  // ---------------- position of the current beat
  wire          beat = s_axis.tvalid && s_axis.tready && en;
  logic [CW-1:0] x, y;
  wire  [CW-1:0] px = s_axis.tuser ? '0 : x;
  wire  [CW-1:0] py = s_axis.tuser ? '0 : y;
  wire  [CW-1:0] cw = frame_w >> CELL_LOG2;      // cells of this frame size
  wire  [CW-1:0] ch = frame_h >> CELL_LOG2;
  wire  [CW-1:0] cx = px >> CELL_LOG2;
  wire  [CW-1:0] cy = py >> CELL_LOG2;
  wire           in_cells = cx < cw && cy < ch;
  wire           eof = s_axis.tlast && py == frame_h - 1'b1;
  wire  [7:0]    luma = 8'((10'(s_axis.tdata[7:0]) + {1'b0, s_axis.tdata[15:8], 1'b0} + 10'(s_axis.tdata[23:16])) >> 2);

  // ---------------- edges: line buffers of luma, 3 x 3 window
  logic [7:0] lb1 [MAXW];                        // line y - 1
  logic [7:0] lb2 [MAXW];                        // line y - 2
  logic [7:0] t1, t2, m1, m2, b1, b2;            // columns x - 1, x - 2 of the top (y - 2), middle, bottom (y) rows
  wire  [7:0] t0 = lb2[px];
  wire  [7:0] m0 = lb1[px];
  wire  [7:0] b0 = luma;
  wire signed [12:0] gx = $signed(13'(t0) + 13'({m0, 1'b0}) + 13'(b0)) - $signed(13'(t2) + 13'({m2, 1'b0}) + 13'(b2));
  wire signed [12:0] gy = $signed(13'(b2) + 13'({b1, 1'b0}) + 13'(b0)) - $signed(13'(t2) + 13'({t1, 1'b0}) + 13'(t0));
  wire [12:0] mag = 13'(gx < 0 ? -gx : gx) + 13'(gy < 0 ? -gy : gy);
  wire        e_raw = edge_en && px >= 2 && py >= 2 && mag > 13'(edge_t);
  // fill: an edge within the last SPAN pixels of the line (since: pixels since the last edge, before this one)
  logic [4:0] e_since, m_since;                  // of the previous pixel (16: none on this line yet)
  wire  [4:0] e_prev = (px == 0) ? 5'd16 : e_since;
  wire        e_bit = e_raw || (5'(e_prev) + 5'd1 < 5'(edge_sp));

  // ---------------- motion: background banks, the shift in effect
  logic [23:0] bank0 [NCELL];                    // {hi, lo} x 16 per cell
  logic [23:0] bank1 [NCELL];
  logic rb;                                      // bank read this frame (the other is written)
  logic bg_valid;
  logic signed [7:0] sh_x, sh_y, sh_next_x, sh_next_y;   // shift of this frame; next one (search result)
  wire  signed [7:0] fsx = s_axis.tuser ? (auto_sh ? sh_next_x : $signed(regs.cfg_shift[7:0])) : sh_x;
  wire  signed [7:0] fsy = s_axis.tuser ? (auto_sh ? sh_next_y : $signed(regs.cfg_shift[15:8])) : sh_y;
  wire  signed [CW+1:0] scx = $signed({2'b0, cx}) - fsx;
  wire  signed [CW+1:0] scy = $signed({2'b0, cy}) - fsy;
  wire           src_ok = bg_valid && in_cells && scx >= 0 && scx < $signed({2'b0, cw}) && scy >= 0 &&
                          scy < $signed({2'b0, ch});
  wire  [31:0]   src_a = 32'(scy) * 32'(cw) + 32'(scx);
  wire  [31:0]   dst_a = 32'(cy) * 32'(cw) + 32'(cx);
  wire  [23:0]   bg = src_ok ? (rb ? bank1[src_a] : bank0[src_a]) : '0;
  wire  [11:0]   bg_lo = bg[11:0];
  wire  [11:0]   bg_hi = bg[23:12];
  wire           m_raw = mot_en && src_ok &&
                         ($signed({2'b0, luma}) < $signed({2'b0, bg_lo[11:4]}) - $signed({2'b0, mot_t}) ||
                          $signed({2'b0, luma}) > $signed({2'b0, bg_hi[11:4]}) + $signed({2'b0, mot_t}));
  wire  [4:0]    m_prev = (px == 0) ? 5'd16 : m_since;
  wire           m_bit = m_raw || (5'(m_prev) + 5'd1 < 5'(mot_sp));
  assign feat_o = {m_bit, e_bit};
  // this frame's lowest / highest luma per cell column (the cell row being scanned)
  logic [7:0] cmin [NCX];
  logic [7:0] cmax [NCX];
  wire        c_first = py[CELL_LOG2-1:0] == 0 && px[CELL_LOG2-1:0] == 0;
  wire        c_last = &py[CELL_LOG2-1:0] && &px[CELL_LOG2-1:0];
  wire  [7:0] n_min = (c_first || luma < cmin[cx]) ? luma : cmin[cx];
  wire  [7:0] n_max = (c_first || luma > cmax[cx]) ? luma : cmax[cx];
  wire signed [13:0] d_lo = $signed({2'b0, n_min, 4'b0}) - $signed({2'b0, bg_lo});
  wire signed [13:0] d_hi = $signed({2'b0, n_max, 4'b0}) - $signed({2'b0, bg_hi});
  wire  [11:0] w_lo = src_ok ? 12'($signed({2'b0, bg_lo}) + (d_lo >>> rate)) : {n_min, 4'b0};
  wire  [11:0] w_hi = src_ok ? 12'($signed({2'b0, bg_hi}) + (d_hi >>> rate)) : {n_max, 4'b0};

  // ---------------- camera shift: column / row profiles in three rotating banks
  logic [PW-1:0] colp [3*NCX];                 // bank b, cell column i at b * NCX + i
  logic [PW-1:0] rowp [3*NCY];
  logic [1:0]    pw_b, pl_b, pp_b;               // banks: written now, the last frame, the one before
  logic          have_last, have_prev;           // the last / previous frame's profiles exist
  logic [PW-1:0] racc;                           // the cell row's luma sum so far
  wire           col_first = py == 0 && px[CELL_LOG2-1:0] == 0;
  wire  [PW-1:0] col_prev = colp[32'(pw_b) * NCX + 32'(cx)];
  wire  [PW-1:0] col_n = (col_first ? PW'(0) : col_prev) + PW'(luma);
  wire           row_first = py[CELL_LOG2-1:0] == 0 && px == 0;
  wire  [PW-1:0] row_n = (row_first ? PW'(0) : racc) + PW'(luma);
  wire           row_last = &py[CELL_LOG2-1:0] && px == (cw << CELL_LOG2) - 1'b1;
  // search: per axis (0 columns, 1 rows) every shift, one term per clock
  typedef enum logic [1:0] {S_IDLE, S_RUN, S_DONE} st_e;
  st_e st;
  logic axis;                                    // 0 columns, 1 rows
  logic signed [7:0] s_cur;
  logic [CW-1:0] s_i;
  logic [PW-1:0] s_acc, s_best;
  logic signed [7:0] s_bs;
  logic [CW-1:0] n_c, n_r;                       // profile lengths of the searched frames
  logic [1:0]    sl_b, sp_b;                     // banks searched: the frame, its previous one
  wire  [CW-1:0] s_n = axis ? n_r : n_c;
  wire  [PW-1:0] s_cv = axis ? rowp[32'(sl_b) * NCY + 32'(s_i)] : colp[32'(sl_b) * NCX + 32'(s_i)];
  wire  [CW-1:0] s_pi = CW'($signed({1'b0, s_i}) - s_cur);
  wire  [PW-1:0] s_pv = axis ? rowp[32'(sp_b) * NCY + 32'(s_pi)] : colp[32'(sp_b) * NCX + 32'(s_pi)];
  wire  [PW-1:0] s_ad = (s_cv > s_pv) ? s_cv - s_pv : s_pv - s_cv;
  wire           s_end_i = 32'(s_i) + 1 >= 32'(s_n) - SHIFT_MAX;   // the last term of this shift
  // the order of the shifts: 0, then -SHIFT_MAX .. SHIFT_MAX (0 skipped)
  function automatic logic signed [7:0] next_s(input logic signed [7:0] s);
    if (s == 0) return -8'(SHIFT_MAX);
    if (s == -1) return 8'sd1;
    return s + 8'sd1;
  endfunction

  // ---------------- counts
  logic [31:0] cnt_e, cnt_m, frames;
  logic in_frame;
  assign regs.sts_frames = frames;
  assign regs.sts_status = {frames[15:0], 13'd0, st != S_IDLE, bg_valid, in_frame};
  assign regs.sts_shift_used = {16'd0, 8'(sh_y), 8'(sh_x)};

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      x <= '0;
      y <= '0;
      {t1, t2, m1, m2, b1, b2} <= '0;
      e_since <= 5'd16;
      m_since <= 5'd16;
      rb <= 1'b0;
      bg_valid <= 1'b0;
      {sh_x, sh_y, sh_next_x, sh_next_y} <= '0;
      pw_b <= 2'd0;
      pl_b <= 2'd1;
      pp_b <= 2'd2;
      have_last <= 1'b0;
      have_prev <= 1'b0;
      racc <= '0;
      st <= S_IDLE;
      axis <= 1'b0;
      s_cur <= '0;
      s_i <= '0;
      s_acc <= '0;
      s_best <= '0;
      s_bs <= '0;
      {n_c, n_r} <= '0;
      {sl_b, sp_b} <= '0;
      regs.sts_shift_est <= '0;
      {cnt_e, cnt_m, frames} <= '0;
      regs.sts_edge_count <= '0;
      regs.sts_motion_count <= '0;
      in_frame <= 1'b0;
      done_o <= 1'b0;
    end else begin
      done_o <= 1'b0;
      if (restart) begin                         // background, profiles and shift start again
        bg_valid <= 1'b0;
        have_last <= 1'b0;
        have_prev <= 1'b0;
        sh_next_x <= '0;
        sh_next_y <= '0;
        regs.sts_shift_est <= '0;
      end
      if (beat) begin
        // position
        if (s_axis.tlast) begin
          x <= '0;
          y <= py + 1'b1;
        end else begin
          x <= px + 1'b1;
          y <= py;
        end
        if (s_axis.tuser) begin                  // the shift of this frame
          sh_x <= fsx;
          sh_y <= fsy;
          in_frame <= 1'b1;
        end
        // edge window and line buffers
        lb2[px] <= lb1[px];
        lb1[px] <= luma;
        t2 <= t1;
        t1 <= t0;
        m2 <= m1;
        m1 <= m0;
        b2 <= b1;
        b1 <= b0;
        e_since <= e_raw ? 5'd0 : (e_prev == 5'd16 ? 5'd16 : e_prev + 5'd1);
        m_since <= m_raw ? 5'd0 : (m_prev == 5'd16 ? 5'd16 : m_prev + 5'd1);
        // background cells and profiles (inside the cells)
        if (in_cells) begin
          cmin[cx] <= n_min;
          cmax[cx] <= n_max;
          if (c_last) begin
            if (rb) bank0[dst_a] <= {w_hi, w_lo};
            else bank1[dst_a] <= {w_hi, w_lo};
          end
          colp[32'(pw_b) * NCX + 32'(cx)] <= col_n;
          racc <= row_n;
          if (row_last) rowp[32'(pw_b) * NCY + 32'(cy)] <= row_n;
        end
        // counts
        if (s_axis.tuser) begin
          cnt_e <= 32'(e_bit);
          cnt_m <= 32'(m_bit);
        end else begin
          cnt_e <= cnt_e + 32'(e_bit);
          cnt_m <= cnt_m + 32'(m_bit);
        end
        if (eof && (in_frame || s_axis.tuser)) begin   // end of frame
          regs.sts_edge_count <= (s_axis.tuser ? 32'd0 : cnt_e) + 32'(e_bit);
          regs.sts_motion_count <= (s_axis.tuser ? 32'd0 : cnt_m) + 32'(m_bit);
          frames <= frames + 1'b1;
          in_frame <= 1'b0;
          rb <= ~rb;
          if (!restart) bg_valid <= 1'b1;
          // profiles: this frame becomes the last, the last the previous
          pw_b <= pp_b;
          pl_b <= pw_b;
          pp_b <= pl_b;
          if (!restart) begin
            have_last <= 1'b1;
            have_prev <= have_last;
          end
          if (have_last && !restart) begin       // search this frame against the last one
            st <= S_RUN;
            axis <= 1'b0;
            s_cur <= '0;
            s_i <= CW'(SHIFT_MAX);
            s_acc <= '0;
            sl_b <= pw_b;
            sp_b <= pl_b;
            n_c <= cw;
            n_r <= ch;
          end else done_o <= 1'b1;
        end
      end
      // shift search (one term per clock, also while the next frame streams)
      if (st == S_RUN) begin
        if (32'(s_n) < 32'(2 * SHIFT_MAX + 1)) begin   // too few cells to compare: no shift
          s_bs <= '0;
          s_best <= '0;
          s_i <= CW'(SHIFT_MAX);
          s_acc <= '0;
          s_cur <= '0;
          if (axis) begin
            regs.sts_shift_est <= {16'd0, 8'd0, 8'(regs.sts_shift_est[7:0])};
            sh_next_y <= '0;
            st <= S_DONE;
          end else begin
            regs.sts_shift_est[7:0] <= '0;
            sh_next_x <= '0;
            axis <= 1'b1;
          end
        end else if (!s_end_i) begin
          s_acc <= s_acc + s_ad;
          s_i <= s_i + 1'b1;
        end else begin                           // a shift's sum is complete
          logic [PW-1:0] tot;
          logic better;
          tot = s_acc + s_ad;
          better = (s_cur == 0) || tot < s_best;
          s_acc <= '0;
          s_i <= CW'(SHIFT_MAX);
          if (better) begin
            s_best <= tot;
            s_bs <= s_cur;
          end
          if (s_cur == 8'(SHIFT_MAX)) begin       // the last shift of this axis
            logic signed [7:0] r;
            r = better ? s_cur : s_bs;
            if (axis) begin
              regs.sts_shift_est[15:8] <= 8'(r);
              sh_next_y <= r;
              st <= S_DONE;
            end else begin
              regs.sts_shift_est[7:0] <= 8'(r);
              sh_next_x <= r;
              axis <= 1'b1;
            end
            s_cur <= '0;
          end else s_cur <= next_s(s_cur);
        end
      end else if (st == S_DONE) begin
        st <= S_IDLE;
        done_o <= 1'b1;
      end
    end
  end

endmodule
