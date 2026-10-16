// ***************
// Filename: feature_ref.sv
// Author: FPGA Cores 4 U
// Description: Testbench reference model of feature_detect, written from
//   its specification (image_processing/video_processor/python-prototype/
//   detect_proto.py is the same model in Python). Called hierarchically,
//   one frame at a time in stream order:
//     w, h            frame size (at most MAXW x MAXH)
//     img[][]         the frame ({B, G, R}, R in [7:0])
//     restart()       CTRL.RESTART: background, profiles and shift invalid
//     step(ctrl, edge_cfg, motion_cfg, sx, sy)
//                     one frame with CTRL, EDGE, MOTION and the shift in
//                     effect (cells, as feature_detect took it at the frame
//                     start: SHIFT_USED): edg[][] / mot[][] (the filled
//                     feature bits of every pixel), n_edge / n_motion, then
//                     the background written; est_valid / est_x / est_y: the
//                     shift search of this frame against the last one
//   Rules: luma Y = (R + 2G + B) / 4; edge = |Gx| + |Gy| > THRESH of the
//   3 x 3 Sobel window centred on (x - 1, y - 1) (x >= 2, y >= 2); motion =
//   luma beyond the background cell's [lo - THRESH, hi + THRESH] (integer
//   parts) of the source cell (cx - sx, cy - sy) when it is in the frame and
//   the background is valid; both filled along the line (a set raw bit in
//   the last SPAN pixels, SPAN 0 as 1); each cell then written as old +
//   (new - old) >>> RATE of its source (x 16), or new without one; column /
//   row profiles per cell; the search keeps s = 0 unless a later shift
//   (-S .. S) gives a strictly lower sum of |cur[i] - prev[i - s]|,
//   i = S .. n - 1 - S.
// Date: 2026-10-14
`timescale 1ns/1ps
module feature_ref #(
  parameter int MAXW = 320,
  parameter int MAXH = 240,
  parameter int CELL_LOG2 = 2,
  parameter int SHIFT_MAX = 4
);
  localparam int CELL = 1 << CELL_LOG2;
  localparam int NCX = MAXW >> CELL_LOG2;
  localparam int NCY = MAXH >> CELL_LOG2;
  int w = MAXW, h = MAXH;
  bit [23:0] img [MAXH][MAXW];
  bit edg [MAXH][MAXW];
  bit mot [MAXH][MAXW];
  int n_edge, n_motion;
  bit est_valid;
  int est_x, est_y;
  // state
  bit bg_valid = 0;
  int lo [NCY][NCX], hi [NCY][NCX];            // x 16
  bit have_last = 0;
  longint col_last [NCX], row_last [NCY];
  int n_cl, n_rl;                               // profile lengths of the last frame

  task automatic restart();
    bg_valid = 0;
    have_last = 0;
  endtask

  function automatic int luma(input bit [23:0] p);
    return (int'(p[7:0]) + 2 * int'(p[15:8]) + int'(p[23:16])) / 4;
  endfunction

  // filled bit of x on a line: a raw bit in the last span pixels (span 0 as 1)
  bit fl_raw [MAXW];
  function automatic bit filled(input int x, input int span);
    int sp;
    sp = (span < 1) ? 1 : span;
    for (int k = 0; k < sp && k <= x; k++) if (fl_raw[x - k]) return 1;
    return 0;
  endfunction

  // shift search: cur / prev profiles in pc / pp, n entries
  longint pc [MAXW], pp [MAXW];
  function automatic longint sad(input int n, input int s);
    longint t;
    t = 0;
    for (int i = SHIFT_MAX; i < n - SHIFT_MAX; i++) t += (pc[i] > pp[i - s]) ? pc[i] - pp[i - s] : pp[i - s] - pc[i];
    return t;
  endfunction
  function automatic int best_shift(input int n);
    longint b, d;
    int bs;
    if (n < 2 * SHIFT_MAX + 1) return 0;
    b = sad(n, 0);
    bs = 0;
    for (int s = -SHIFT_MAX; s <= SHIFT_MAX; s++) begin
      if (s == 0) continue;
      d = sad(n, s);
      if (d < b) begin
        b = d;
        bs = s;
      end
    end
    return bs;
  endfunction

  task automatic step(input int ctrl, input int edge_cfg, input int motion_cfg, input int sx, input int sy);
    int yv [MAXH][MAXW];
    int et, es, mt, ms, rate, cw, ch;
    int nlo [NCY][NCX], nhi [NCY][NCX];
    longint col [NCX], row [NCY];
    et = edge_cfg & 'h7FF;
    es = (edge_cfg >> 16) & 15;
    mt = motion_cfg & 255;
    ms = (motion_cfg >> 8) & 15;
    rate = (motion_cfg >> 12) & 7;
    cw = w >> CELL_LOG2;
    ch = h >> CELL_LOG2;
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) yv[y][x] = luma(img[y][x]);
    // edges
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) begin
      edg[y][x] = 0;
      if (ctrl[1] && x >= 2 && y >= 2) begin
        int gx, gy;
        gx = (yv[y-2][x] + 2 * yv[y-1][x] + yv[y][x]) - (yv[y-2][x-2] + 2 * yv[y-1][x-2] + yv[y][x-2]);
        gy = (yv[y][x-2] + 2 * yv[y][x-1] + yv[y][x]) - (yv[y-2][x-2] + 2 * yv[y-2][x-1] + yv[y-2][x]);
        edg[y][x] = ((gx < 0 ? -gx : gx) + (gy < 0 ? -gy : gy)) > et;
      end
    end
    // this frame's cells and profiles
    for (int cy = 0; cy < ch; cy++) for (int cx = 0; cx < cw; cx++) begin
      nlo[cy][cx] = 255;
      nhi[cy][cx] = 0;
    end
    for (int i = 0; i < NCX; i++) col[i] = 0;
    for (int i = 0; i < NCY; i++) row[i] = 0;
    for (int y = 0; y < ch * CELL; y++) for (int x = 0; x < cw * CELL; x++) begin
      int cx, cy, v;
      cx = x >> CELL_LOG2;
      cy = y >> CELL_LOG2;
      v = yv[y][x];
      if (v < nlo[cy][cx]) nlo[cy][cx] = v;
      if (v > nhi[cy][cx]) nhi[cy][cx] = v;
      col[cx] += v;
      row[cy] += v;
    end
    // motion against the background (source cells at the shift)
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) begin
      int cx, cy, scx, scy;
      mot[y][x] = 0;
      cx = x >> CELL_LOG2;
      cy = y >> CELL_LOG2;
      scx = cx - sx;
      scy = cy - sy;
      if (ctrl[2] && bg_valid && cx < cw && cy < ch && scx >= 0 && scx < cw && scy >= 0 && scy < ch)
        mot[y][x] = yv[y][x] < (lo[scy][scx] >> 4) - mt || yv[y][x] > (hi[scy][scx] >> 4) + mt;
    end
    n_edge = 0;
    n_motion = 0;
    for (int y = 0; y < h; y++) begin
      bit f [MAXW];
      for (int x = 0; x < w; x++) fl_raw[x] = edg[y][x];
      for (int x = 0; x < w; x++) f[x] = filled(x, es);
      for (int x = 0; x < w; x++) edg[y][x] = f[x];
      for (int x = 0; x < w; x++) fl_raw[x] = mot[y][x];
      for (int x = 0; x < w; x++) f[x] = filled(x, ms);
      for (int x = 0; x < w; x++) mot[y][x] = f[x];
      for (int x = 0; x < w; x++) begin
        n_edge += edg[y][x];
        n_motion += mot[y][x];
      end
    end
    // background written (from the source cells), valid from the next frame
    begin
      int olo [NCY][NCX], ohi [NCY][NCX];
      for (int cy = 0; cy < ch; cy++) for (int cx = 0; cx < cw; cx++) begin
        olo[cy][cx] = lo[cy][cx];
        ohi[cy][cx] = hi[cy][cx];
      end
      for (int cy = 0; cy < ch; cy++) for (int cx = 0; cx < cw; cx++) begin
        int scx, scy, nl, nh;
        scx = cx - sx;
        scy = cy - sy;
        nl = nlo[cy][cx] << 4;
        nh = nhi[cy][cx] << 4;
        if (bg_valid && scx >= 0 && scx < cw && scy >= 0 && scy < ch) begin
          lo[cy][cx] = olo[scy][scx] + ((nl - olo[scy][scx]) >>> rate);
          hi[cy][cx] = ohi[scy][scx] + ((nh - ohi[scy][scx]) >>> rate);
        end else begin
          lo[cy][cx] = nl;
          hi[cy][cx] = nh;
        end
      end
    end
    bg_valid = 1;
    // shift search against the last frame
    est_valid = have_last;
    est_x = 0;
    est_y = 0;
    if (have_last) begin
      if (n_cl == cw) begin
        for (int i = 0; i < cw; i++) begin
          pc[i] = col[i];
          pp[i] = col_last[i];
        end
        est_x = best_shift(cw);
      end
      if (n_rl == ch) begin
        for (int i = 0; i < ch; i++) begin
          pc[i] = row[i];
          pp[i] = row_last[i];
        end
        est_y = best_shift(ch);
      end
    end
    for (int i = 0; i < cw; i++) col_last[i] = col[i];
    for (int i = 0; i < ch; i++) row_last[i] = row[i];
    n_cl = cw;
    n_rl = ch;
    have_last = 1;
  endtask
endmodule
