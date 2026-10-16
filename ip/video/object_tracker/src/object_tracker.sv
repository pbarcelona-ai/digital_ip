// ***************
// Filename: object_tracker.sv
// Author: FPGA Cores 4 U
// Description: Object search / measurement for target detection and
//   tracking. Watches an AXI4-Stream video (24-bit pixels, tuser = start of
//   frame, tlast = end of line) without touching it: a passive tap on the
//   accepted beats (tvalid & tready). Per frame it finds the pixels of the
//   object inside a search window and reports their bounding box; the CPU
//   runs the tracking loop (search the whole frame, then a window around
//   the predicted position) and draws the result with symbol_overlay. One
//   instance is one detector (one object class: its pixel test and run
//   widths); a design detecting several classes instantiates one per class.
//     - Pixel {B, G, R} (R in [7:0]): luma Y = (R + 2 G + B) / 4, chroma
//       Cb = 128 + (B - Y) / 2, Cr = 128 + (R - Y) / 2, saturation
//       S = |Cb - 128| + |Cr - 128|.
//     - Object pixel, inside the window (WIN_X / WIN_Y, inclusive; taken at
//       the frame start) and
//         CTRL.MODE = 0 (luma): Y < THRESH (CTRL.POL = 1, dark object on a
//           light scene) or Y > THRESH (POL = 0);
//         CTRL.MODE = 1 (colour): Y, Cb and Cr inside Y_RANGE, CB_RANGE and
//           CR_RANGE (min / max inclusive) and S >= SAT_MIN (e.g. skin tone
//           for faces, saturated paint for cars).
//     - Run filter: a horizontal run of object pixels counts, when it ends
//       (the next pixel is not an object pixel, or the end of the line), if
//       it is at least MIN pixels long (RUN.MIN_W, or CTRL.MIN_RUN when
//       RUN.MIN_W = 0; 0 or 1: every pixel) and, with RUN.MAX_W != 0, at
//       most MAX_W long: isolated pixels, thin lines and objects wider than
//       the class are ignored. The run's whole length is judged, also where
//       it crosses the window's edge (a bus reaching into a car's window is
//       still a bus-length run, not a car-length one); its pixels inside the
//       window then add to COUNT, the sums and the box.
//     - Features: feat_i carries feature_detect's bits of the beat ([0]
//       edge, [1] motion). The object pixel test has two terms: term A is
//       the luma / colour test above combined with the motion bit
//       (CTRL.FEAT_A: the test, test OR motion, test AND motion, motion
//       only), judged with RUN; term B (CTRL.TERM_B) is the edge bit, judged
//       with RUN_B. Each term has its own run filter; both terms' counted
//       runs add to COUNT, the box and the sums (term A's first when both
//       close on the same pixel).
//     - Blobs: the counted runs are also grouped into up to NBLOB separate
//       objects per frame (one pass, no frame store): a run joins the blob
//       whose box it touches (its columns within BLOB_CFG.GAP of the box's,
//       its line at most GAP_Y + 1 below the box's last line: a car's roof
//       and body, apart where its windows break the paint, are one object
//       with GAP_Y as tall as the windows); a run touching
//       several blobs joins them into one; a run touching none starts a new
//       blob in a free slot. A blob no run has reached for GAP_Y + 1 lines is
//       closed; a closed blob of fewer than BLOB_CFG.KEEP pixels is dropped
//       (its slot reused), so small clutter does not use up the slots. With
//       every slot taken, a new run is not grouped (BLOB_LOST counts it).
//       With TERM_B, term A's runs use slots 0 .. NBLOB/2 - 1 and term B's
//       the others, so a painted bus never joins the edges of the buildings
//       behind it. At the end of the frame BLOB_X / BLOB_Y / BLOB_N[i] hold
//       blob i (BLOB_N = 0: no blob, or one of fewer than KEEP pixels).
//     - At the end of the frame (the tlast of line FRAME_SIZE height - 1)
//       COUNT, BOX_X, BOX_Y and the sums are latched, FRAMES increments and
//       done_o pulses for one clock. COUNT = 0: nothing found (the box then
//       reads x0 > x1).
//     - SCRATCH[0..27]: plain read / write words for the CPU (the tracking
//       state of this detector: the firmware keeps one set per tracked
//       object of the class).
//   Registers on the cfg_* / sts_* ports; object_tracker_top.sv is the
//   block with its AXI4-Lite register map (src/include/object_tracker_regs.sv): ID "OTRK" / VERSION / DATE at 0x00-0x08, CTRL 0x18,
//   FRAME_SIZE 0x1C, THRESH 0x20, WIN_X 0x24, WIN_Y 0x28, FRAMES 0x2C, COUNT
//   0x30, BOX_X 0x34, BOX_Y 0x38, SUM_X 0x3C, SUM_Y 0x40, STATUS 0x44, RUN
//   0x48, Y_RANGE 0x4C, CB_RANGE 0x50, CR_RANGE 0x54, SAT_MIN 0x58, BLOB_CFG
//   0x5C, SCRATCH 0x60 + 4 i (28 words), RUN_B 0xD0, BLOB_X 0x100 + 4 i,
//   BLOB_Y 0x120 + 4 i, BLOB_N 0x140 + 4 i (i < NBLOB = 8); ADDR_W = 9.
//   Clock - clk (pixel clock). Reset - synchronous active low rst_n.
//   Latency - results one clock after the last pixel of the frame.
// Date: 2026-10-15
module object_tracker #(
  parameter int CW = 16,                         // coordinate width
  parameter int NBLOB = 8                        // blobs per frame (BLOB_X / BLOB_Y / BLOB_N)
) (
  input  logic        clk,
  input  logic        rst_n,
  // video tap (observed only)
  // s_axis: axis_if.monitor (ip/shared/src/interfaces/axis_if.sv), DATA_W = 24
  axis_if.monitor s_axis,
  input  logic [1:0]  feat_i,                    // features of the beat (feature_detect): [0] edge, [1] motion
  output logic        done_o,                    // one clock: results of a frame latched
  // register ports
  // regs: object_tracker_regs_if.core (src/include/object_tracker_regs_if.sv)
  object_tracker_regs_if.core regs
);
  // ---------------- registers
  logic [31:0] ctrl, frame_size, win_x, win_y, frames, res_n, res_sx, res_sy, status_w;
  logic [7:0] thresh_r;
  logic [CW-1:0] res_x0, res_x1, res_y0, res_y1;
  logic full_win, in_frame;
  logic [7:0] blob_lost;                         // runs of the last frame not grouped (every blob slot taken)
  // register ports (the map object_tracker_regs is in the wrapper, src/object_tracker_top.sv)
  assign ctrl = regs.cfg_ctrl;
  assign frame_size = regs.cfg_frame_size;
  assign thresh_r = regs.cfg_thresh;
  assign win_x = regs.cfg_win_x;
  assign win_y = regs.cfg_win_y;
  assign regs.sts_frames = frames;
  assign regs.sts_count = res_n;
  assign regs.sts_box_x = {16'(res_x1), 16'(res_x0)};
  assign regs.sts_box_y = {16'(res_y1), 16'(res_y0)};
  assign regs.sts_sum_x = res_sx;
  assign regs.sts_sum_y = res_sy;
  assign regs.sts_status = {frames[15:0], blob_lost, 6'd0, full_win, in_frame};

  wire          en      = ctrl[0];
  wire          pol     = ctrl[1];
  wire          mode    = ctrl[2];
  wire [3:0]    min_run = ctrl[11:8];
  wire [CW-1:0] frame_w = frame_size[CW-1:0];
  wire [CW-1:0] frame_h = frame_size[16 +: CW];
  wire [7:0]    thresh  = thresh_r;
  wire [11:0]   min_w   = regs.cfg_run[11:0];
  wire [11:0]   max_w   = regs.cfg_run[27:16];

  // ---------------- position of the current beat
  wire          beat = s_axis.tvalid && s_axis.tready && en;
  logic [CW-1:0] x, y;                           // of the next beat (a start of frame restarts at 0, 0)
  wire  [CW-1:0] px = s_axis.tuser ? '0 : x;
  wire  [CW-1:0] py = s_axis.tuser ? '0 : y;
  // window of the frame being measured (taken at its start)
  logic [CW-1:0] wx0, wx1, wy0, wy1;
  wire  [CW-1:0] cwx0 = s_axis.tuser ? win_x[CW-1:0] : wx0;
  wire  [CW-1:0] cwx1 = s_axis.tuser ? win_x[16 +: CW] : wx1;
  wire  [CW-1:0] cwy0 = s_axis.tuser ? win_y[CW-1:0] : wy0;
  wire  [CW-1:0] cwy1 = s_axis.tuser ? win_y[16 +: CW] : wy1;

  // ---------------- object pixel: luma threshold or colour ranges
  wire [9:0] luma4 = 10'(s_axis.tdata[7:0]) + {1'b0, s_axis.tdata[15:8], 1'b0} + 10'(s_axis.tdata[23:16]);
  wire [7:0] luma = luma4[9:2];
  wire signed [9:0] db = $signed({2'b0, s_axis.tdata[23:16]}) - $signed({2'b0, luma});   // B - Y
  wire signed [9:0] dr = $signed({2'b0, s_axis.tdata[7:0]}) - $signed({2'b0, luma});     // R - Y
  wire signed [9:0] hb = db >>> 1;
  wire signed [9:0] hr = dr >>> 1;
  wire [7:0] cb = 8'(hb + 10'sd128);
  wire [7:0] cr = 8'(hr + 10'sd128);
  wire [8:0] sat = 9'(hb < 0 ? -hb : hb) + 9'(hr < 0 ? -hr : hr);
  wire       in_y  = luma >= regs.cfg_y_range[7:0] && luma <= regs.cfg_y_range[15:8];
  wire       in_cb = cb >= regs.cfg_cb_range[7:0] && cb <= regs.cfg_cb_range[15:8];
  wire       in_cr = cr >= regs.cfg_cr_range[7:0] && cr <= regs.cfg_cr_range[15:8];
  wire       colour_ok = in_y && in_cb && in_cr && sat >= 9'(regs.cfg_sat_min);
  // the run filters follow object pixels over the whole line; the window only limits which of a
  // counted run's pixels are measured. Term A: the luma / colour test combined with the motion feature
  // (CTRL.FEAT_A); term B: the edge feature (CTRL.TERM_B), with its own run band (RUN_B)
  wire       base = mode ? colour_ok : (pol ? luma < thresh : luma > thresh);
  wire [1:0] feat_a = ctrl[13:12];
  wire       term_b = ctrl[14];
  logic      obj [2];
  always_comb begin
    case (feat_a)
      2'd1: obj[0] = base | feat_i[1];
      2'd2: obj[0] = base & feat_i[1];
      2'd3: obj[0] = feat_i[1];
      default: obj[0] = base;
    endcase
    obj[1] = term_b & feat_i[0];
  end
  wire       row_in = py >= cwy0 && py <= cwy1;

  // ---------------- run filters (term A, term B): a run is judged when it ends, by its whole length
  logic [CW-1:0] run [2];                        // object pixels just before this one in the current run
  logic [CW-1:0] run_x0 [2];                     // first x of the current run
  wire           line_start = s_axis.tuser || px == 0;
  wire [11:0]    need_a = (min_w != 0) ? min_w : ((min_run == 0) ? 12'd1 : 12'(min_run));
  wire [11:0]    need_b = (regs.cfg_run_b[11:0] != 0) ? regs.cfg_run_b[11:0] : 12'd1;
  logic [CW-1:0] cur_len [2], cur_x0 [2];
  logic          counts [2];
  logic [CW-1:0] k_x0 [2], k_x1 [2], k_len [2];  // the part of the closing run inside the window
  always_comb begin
    for (int t = 0; t < 2; t++) begin
      logic [CW-1:0] prev, cl_len, cl_x0, cl_x1;
      logic close;
      logic [11:0] need, mx;
      prev = line_start ? '0 : run[t];           // the run this pixel continues (none at a line start)
      cur_len[t] = obj[t] ? prev + 1'b1 : '0;
      cur_x0[t] = (prev == 0) ? px : run_x0[t];
      // the run that ends here: the one before a non-object pixel, or the one reaching the line end
      close = obj[t] ? s_axis.tlast : prev != 0;
      cl_len = obj[t] ? cur_len[t] : prev;
      cl_x0 = obj[t] ? cur_x0[t] : run_x0[t];
      cl_x1 = obj[t] ? px : px - 1'b1;
      need = t ? need_b : need_a;
      mx = t ? regs.cfg_run_b[27:16] : max_w;
      k_x0[t] = (cl_x0 < cwx0) ? cwx0 : cl_x0;
      k_x1[t] = (cl_x1 > cwx1) ? cwx1 : cl_x1;
      k_len[t] = k_x1[t] - k_x0[t] + 1'b1;
      counts[t] = close && 32'(cl_len) >= 32'(need) && (mx == 0 || 32'(cl_len) <= 32'(mx)) && row_in &&
                  k_x0[t] <= k_x1[t];
    end
  end
  wire           eof = s_axis.tlast && py == frame_h - 1'b1;

  // accumulators of the frame being measured
  logic [31:0] acc_n, acc_sx, acc_sy;
  logic [CW-1:0] acc_x0, acc_x1, acc_y0, acc_y1;

  // accumulators including this beat (a start of frame begins from empty). A run that counts adds
  // all its pixels k_x0 .. k_x1 (sum of x = len * (x0 + x1) / 2); term A's run, then term B's.
  logic [31:0]   n_n, n_sx, n_sy;
  logic [CW-1:0] n_x0, n_x1, n_y0, n_y1;
  always_comb begin
    n_n  = s_axis.tuser ? 32'd0 : acc_n;
    n_sx = s_axis.tuser ? 32'd0 : acc_sx;
    n_sy = s_axis.tuser ? 32'd0 : acc_sy;
    n_x0 = s_axis.tuser ? '1 : acc_x0;
    n_x1 = s_axis.tuser ? '0 : acc_x1;
    n_y0 = s_axis.tuser ? '1 : acc_y0;
    n_y1 = s_axis.tuser ? '0 : acc_y1;
    for (int t = 0; t < 2; t++) if (counts[t]) begin
      n_n  = n_n + 32'(k_len[t]);
      n_sx = n_sx + 32'((64'(k_x0[t]) + 64'(k_x1[t])) * 64'(k_len[t]) >> 1);
      n_sy = n_sy + 32'(py) * 32'(k_len[t]);
      if (k_x0[t] < n_x0) n_x0 = k_x0[t];
      if (k_x1[t] > n_x1) n_x1 = k_x1[t];
      if (py < n_y0) n_y0 = py;
      if (py > n_y1) n_y1 = py;
    end
  end

  // ---------------- blobs: the counted runs grouped into separate objects; with TERM_B, term A's runs use
  // slots 0 .. NBLOB/2 - 1 and term B's the others (the two never join)
  wire [7:0]  gap  = regs.cfg_blob_cfg[7:0];
  wire [7:0]  gap_y = regs.cfg_blob_cfg[15:8];
  wire [15:0] keep = regs.cfg_blob_cfg[31:16];
  logic          bl_v [NBLOB];                   // slot in use
  logic [CW-1:0] bl_x0 [NBLOB], bl_x1 [NBLOB], bl_y0 [NBLOB], bl_y1 [NBLOB];
  logic [31:0]   bl_n [NBLOB];
  logic [7:0]    bl_lost;
  // slots including this beat (a start of frame begins from empty)
  logic          nb_v [NBLOB];
  logic [CW-1:0] nb_x0 [NBLOB], nb_x1 [NBLOB], nb_y0 [NBLOB], nb_y1 [NBLOB];
  logic [31:0]   nb_n [NBLOB];
  logic [7:0]    nb_lost;
  always_comb begin
    logic hit [NBLOB];
    logic any_hit, any_free, done;
    int   tgt, lo, hi;
    for (int i = 0; i < NBLOB; i++) begin
      nb_v[i]  = s_axis.tuser ? 1'b0 : bl_v[i];
      nb_x0[i] = bl_x0[i];
      nb_x1[i] = bl_x1[i];
      nb_y0[i] = bl_y0[i];
      nb_y1[i] = bl_y1[i];
      nb_n[i]  = s_axis.tuser ? 32'd0 : bl_n[i];
    end
    nb_lost = s_axis.tuser ? 8'd0 : bl_lost;
    for (int t = 0; t < 2; t++) if (counts[t]) begin
      lo = (term_b && t == 1) ? NBLOB / 2 : 0;
      hi = (term_b && t == 0) ? NBLOB / 2 : NBLOB;
      any_hit = 1'b0;
      any_free = 1'b0;
      tgt = 0;
      // blobs the run touches: columns within gap, its line at most gap_y + 1 below the blob's last line
      for (int i = 0; i < NBLOB; i++)
        hit[i] = i >= lo && i < hi && nb_v[i] && 32'(k_x0[t]) <= 32'(nb_x1[i]) + 32'(gap) &&
                 32'(k_x1[t]) + 32'(gap) >= 32'(nb_x0[i]) && 32'(py) <= 32'(nb_y1[i]) + 32'(gap_y) + 1;
      done = 1'b0;
      for (int i = 0; i < NBLOB; i++) if (hit[i] && !done) begin
        tgt = i;
        any_hit = 1'b1;
        done = 1'b1;
      end
      if (any_hit) begin                         // join: the run and every blob it touches into the first
        if (k_x0[t] < nb_x0[tgt]) nb_x0[tgt] = k_x0[t];
        if (k_x1[t] > nb_x1[tgt]) nb_x1[tgt] = k_x1[t];
        nb_y1[tgt] = py;
        nb_n[tgt] = nb_n[tgt] + 32'(k_len[t]);
        for (int i = 0; i < NBLOB; i++) if (hit[i] && i != tgt) begin
          if (nb_x0[i] < nb_x0[tgt]) nb_x0[tgt] = nb_x0[i];
          if (nb_x1[i] > nb_x1[tgt]) nb_x1[tgt] = nb_x1[i];
          if (nb_y0[i] < nb_y0[tgt]) nb_y0[tgt] = nb_y0[i];
          nb_n[tgt] = nb_n[tgt] + nb_n[i];
          nb_v[i] = 1'b0;
          nb_n[i] = 32'd0;
        end
      end else begin                             // new blob: a free slot, or a closed one too small to keep
        done = 1'b0;
        for (int i = 0; i < NBLOB; i++)
          if (!done && i >= lo && i < hi &&
              (!nb_v[i] || (32'(py) > 32'(nb_y1[i]) + 32'(gap_y) + 1 && nb_n[i] < 32'(keep)))) begin
            tgt = i;
            any_free = 1'b1;
            done = 1'b1;
          end
        if (any_free) begin
          nb_v[tgt] = 1'b1;
          nb_x0[tgt] = k_x0[t];
          nb_x1[tgt] = k_x1[t];
          nb_y0[tgt] = py;
          nb_y1[tgt] = py;
          nb_n[tgt] = 32'(k_len[t]);
        end else if (nb_lost != 8'hFF) nb_lost = nb_lost + 1'b1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < NBLOB; i++) begin
        bl_v[i] <= 1'b0;
        bl_n[i] <= '0;
        {bl_x0[i], bl_x1[i], bl_y0[i], bl_y1[i]} <= '0;
        regs.sts_blob_x[i*32 +: 32] <= 32'h0000_FFFF;
        regs.sts_blob_y[i*32 +: 32] <= 32'h0000_FFFF;
        regs.sts_blob_n[i*32 +: 32] <= '0;
      end
      bl_lost <= '0;
      blob_lost <= '0;
    end else if (beat) begin
      for (int i = 0; i < NBLOB; i++) begin
        bl_v[i] <= nb_v[i];
        bl_x0[i] <= nb_x0[i];
        bl_x1[i] <= nb_x1[i];
        bl_y0[i] <= nb_y0[i];
        bl_y1[i] <= nb_y1[i];
        bl_n[i] <= nb_n[i];
      end
      bl_lost <= nb_lost;
      if (eof && (in_frame || s_axis.tuser)) begin   // end of frame: the blobs of at least KEEP pixels
        for (int i = 0; i < NBLOB; i++) begin
          if (nb_v[i] && nb_n[i] >= 32'(keep) && nb_n[i] != 0) begin
            regs.sts_blob_x[i*32 +: 32] <= {16'(nb_x1[i]), 16'(nb_x0[i])};
            regs.sts_blob_y[i*32 +: 32] <= {16'(nb_y1[i]), 16'(nb_y0[i])};
            regs.sts_blob_n[i*32 +: 32] <= nb_n[i];
          end else begin
            regs.sts_blob_x[i*32 +: 32] <= 32'h0000_FFFF;
            regs.sts_blob_y[i*32 +: 32] <= 32'h0000_FFFF;
            regs.sts_blob_n[i*32 +: 32] <= '0;
          end
        end
        blob_lost <= nb_lost;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      x <= '0;
      y <= '0;
      in_frame <= 1'b0;
      run[0] <= '0;
      run[1] <= '0;
      run_x0[0] <= '0;
      run_x0[1] <= '0;
      {wx0, wx1, wy0, wy1} <= '0;
      {acc_n, acc_sx, acc_sy} <= '0;
      acc_x0 <= '1;
      acc_x1 <= '0;
      acc_y0 <= '1;
      acc_y1 <= '0;
      {frames, res_n, res_sx, res_sy} <= '0;
      res_x0 <= '1;
      res_x1 <= '0;
      res_y0 <= '1;
      res_y1 <= '0;
      full_win <= 1'b0;
      done_o <= 1'b0;
    end else begin
      done_o <= 1'b0;
      if (beat) begin
        if (s_axis.tuser) begin                  // new frame: its window
          wx0 <= cwx0;
          wx1 <= cwx1;
          wy0 <= cwy0;
          wy1 <= cwy1;
          full_win <= cwx0 == 0 && cwy0 == 0 && cwx1 >= frame_w - 1'b1 && cwy1 >= frame_h - 1'b1;
          in_frame <= 1'b1;
        end
        for (int t = 0; t < 2; t++) begin        // run state for the next pixel (none after a line end)
          run[t] <= s_axis.tlast ? '0 : cur_len[t];
          run_x0[t] <= cur_x0[t];
        end
        acc_n <= n_n;
        acc_sx <= n_sx;
        acc_sy <= n_sy;
        acc_x0 <= n_x0;
        acc_x1 <= n_x1;
        acc_y0 <= n_y0;
        acc_y1 <= n_y1;
        if (s_axis.tlast) begin
          x <= '0;
          y <= py + 1'b1;
        end else begin
          x <= px + 1'b1;
          y <= py;
        end
        if (eof && (in_frame || s_axis.tuser)) begin   // end of frame: latch the results
          res_n <= n_n;
          res_sx <= n_sx;
          res_sy <= n_sy;
          res_x0 <= n_x0;
          res_x1 <= n_x1;
          res_y0 <= n_y0;
          res_y1 <= n_y1;
          frames <= frames + 1'b1;
          in_frame <= 1'b0;
          done_o <= 1'b1;
        end
      end
    end
  end

endmodule
