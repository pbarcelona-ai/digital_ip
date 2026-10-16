// ***************
// Filename: track_ref.sv
// Author: FPGA Cores 4 U
// Description: Testbench reference models of object_tracker and
//   symbol_overlay, written from their specifications (register
//   descriptions), not from the RTL. Called hierarchically:
//     w, h           frame size (at most MAXW x MAXH), set by the caller
//     img[][]        the frame ({B, G, R}, R in [7:0]) both models work on
//     measure(...)   object_tracker of img in a search window: n (object
//                    pixels), x0 / x1 / y0 / y1 (their box; nothing found:
//                    x0 = y0 = 65535, x1 = y1 = 0), sx / sy (sums of x, y);
//                    luma threshold, runs of at least min_run
//     measure_cfg(...) the same with every detector setting: CTRL (POL,
//                    MODE, MIN_RUN), THRESH, RUN (MIN_W / MAX_W), Y_RANGE,
//                    CB_RANGE, CR_RANGE, SAT_MIN (colour mode: Y, Cb =
//                    128 + (B - Y) / 2, Cr = 128 + (R - Y) / 2 in their
//                    ranges and |Cb - 128| + |Cr - 128| >= SAT_MIN); a run is
//                    judged when it ends (MIN_W <= length <= MAX_W) by its
//                    whole length, also where it crosses the window's edge;
//                    its pixels inside the window are measured. Blobs
//                    (blob_cfg = BLOB_CFG: GAP, GAP_Y, KEEP): the counted runs
//                    grouped into NBLOB slots as object_tracker groups them
//                    (two terms: A = the luma / colour test combined with the
//                    motion bits fm[][] per CTRL.FEAT_A, B = the edge bits
//                    fe[][] with RUN_B when CTRL.TERM_B, each its own run
//                    filter, closing A then B on the same pixel, slots
//                    split between them):
//                    bn[i] (0: none), bx0 / bx1 / by0 / by1[i]
//     obj[i]         symbol_overlay object i {COLOR, Y, X, CTRL} (128 bits,
//                    the register layout), txt[j] text j {COLOR, POS, CTRL}
//                    (96 bits) and chr[j] its 16 characters (128 bits, byte k
//                    = character k), ntxt texts: draw(en) -> out[][]: img with
//                    every enabled object drawn (object 0 on top; shape 3:
//                    a circle round the box centre, radius = half the
//                    larger side, or with CTRL[5] an oval (ellipse) inside
//                    the box, LINE_W wide inside it, dashed by
//                    min(|dx|, |dy|)), then the
//                    texts (text 0 on top; overlay_font_pkg glyphs in 4 x 6
//                    cells, scaled 2^scale, backdrop = video halved; a text
//                    with CTRL[4] is followed by the frame number fnum, a
//                    decimal number)
//   find_dark(thr, run) is the testbench's own ground truth of a dark target:
//   the box of the pixels darker than thr in horizontal runs of at least
//   run pixels, in the whole frame (gx0 .. gy1, gn pixels).
// Date: 2026-10-15
`timescale 1ns/1ps
module track_ref #(
  parameter int MAXW = 320,
  parameter int MAXH = 240,
  parameter int NOBJ = 4,
  parameter int NBLOB = 8
);
  int w = MAXW, h = MAXH;
  bit [23:0] img [MAXH][MAXW];
  bit [23:0] out [MAXH][MAXW];
  logic [127:0] obj [NOBJ];
  logic [95:0] txt [8];
  logic [127:0] chr [8];
  int ntxt = 0;
  int fnum = 0;
  int n, x0, x1, y0, y1;
  longint sx, sy;
  int gn, gx0, gx1, gy0, gy1;
  int blob_cfg = 32'h0202;                         // BLOB_CFG: [7:0] GAP, [15:8] GAP_Y, [31:16] KEEP
  int run_b = 0;                                   // RUN_B: term B's run band
  bit term_b;
  bit fe [MAXH][MAXW];                             // feature_detect's bits of img: edge, motion (0 when unused)
  bit fm [MAXH][MAXW];
  bit bv [NBLOB];
  int bn [NBLOB], bx0 [NBLOB], bx1 [NBLOB], by0 [NBLOB], by1 [NBLOB];
  int blost;

  function automatic int luma(input logic [23:0] p);
    return (int'(p[7:0]) + 2 * int'(p[15:8]) + int'(p[23:16])) / 4;
  endfunction

  // chroma as object_tracker defines it: 128 + (B - Y) / 2, 128 + (R - Y) / 2 (the halving rounds down)
  function automatic int half_down(input int v);
    return (v >= 0) ? v / 2 : -((-v + 1) / 2);
  endfunction
  function automatic int chroma_b(input logic [23:0] p);
    return 128 + half_down(int'(p[23:16]) - luma(p));
  endfunction
  function automatic int chroma_r(input logic [23:0] p);
    return 128 + half_down(int'(p[7:0]) - luma(p));
  endfunction
  function automatic int sat(input logic [23:0] p);
    int a, b;
    a = chroma_b(p) - 128;
    b = chroma_r(p) - 128;
    return (a < 0 ? -a : a) + (b < 0 ? -b : b);
  endfunction

  // object pixels: in the window, luma beyond thr (below: dark), in a run of >= min_run along the line
  task automatic measure(input int wx0, input int wy0, input int wx1, input int wy1, input int thr,
                         input bit dark, input int min_run);
    measure_cfg(wx0, wy0, wx1, wy1, 32'(dark) << 1 | (min_run & 15) << 8, thr, 0, 16'hFF00, 16'hFF00, 16'hFF00, 0);
  endtask

  // every setting: ctrl [1] POL [2] MODE [11:8] MIN_RUN, run [11:0] MIN_W [27:16] MAX_W, ranges [7:0] min
  // [15:8] max; a run of object pixels counts when it ends if MIN_W (or MIN_RUN) <= length <= MAX_W
  task automatic measure_cfg(input int wx0, input int wy0, input int wx1, input int wy1, input int ctrl,
                             input int thr, input int runw, input int yr, input int cbr, input int crr,
                             input int satmin);
    int run [2], need [2], mx [2];
    bit o [2];
    term_b = (ctrl >> 14) & 1;
    need[0] = runw & 12'hFFF;
    if (need[0] == 0) need[0] = (ctrl >> 8) & 15;
    if (need[0] < 1) need[0] = 1;
    mx[0] = (runw >> 16) & 12'hFFF;
    need[1] = run_b & 12'hFFF;
    if (need[1] < 1) need[1] = 1;
    mx[1] = (run_b >> 16) & 12'hFFF;
    n = 0;
    sx = 0;
    sy = 0;
    x0 = 65535;
    y0 = 65535;
    x1 = 0;
    y1 = 0;
    for (int i = 0; i < NBLOB; i++) begin
      bv[i] = 0;
      bn[i] = 0;
    end
    blost = 0;
    for (int y = 0; y < h; y++) begin
      run[0] = 0;
      run[1] = 0;
      // per pixel, the runs closing there in the order object_tracker takes them: term A, then term B; a
      // run that reaches the end of the line closes on its last pixel
      for (int x = 0; x < w; x++) begin
        bit base;
        base = pix_obj(img[y][x], ctrl, thr, yr, cbr, crr, satmin);
        case ((ctrl >> 12) & 3)
          1: o[0] = base | fm[y][x];
          2: o[0] = base & fm[y][x];
          3: o[0] = fm[y][x];
          default: o[0] = base;
        endcase
        o[1] = term_b & fe[y][x];
        for (int t = 0; t < 2; t++) begin
          int ra, rb, len;
          len = 0;
          if (o[t]) begin
            run[t]++;
            if (x == w - 1) begin
              len = run[t];
              ra = x - run[t] + 1;
              rb = x;
            end
          end else if (run[t] > 0) begin
            len = run[t];
            ra = x - run[t];
            rb = x - 1;
            run[t] = 0;
          end
          if (len > 0 && len >= need[t] && (mx[t] == 0 || len <= mx[t]) && y >= wy0 && y <= wy1) begin
            int a, b;
            a = (ra < wx0) ? wx0 : ra;           // its part inside the window
            b = (rb > wx1) ? wx1 : rb;
            if (a <= b) begin
              for (int k = a; k <= b; k++) add(k, y);
              blob_run(a, b, y, t);
            end
          end
        end
      end
    end
    for (int i = 0; i < NBLOB; i++) if (!bv[i] || bn[i] < ((blob_cfg >> 16) & 16'hFFFF)) bn[i] = 0;
  endtask
  // a counted run a..b of line y of term (0 A, 1 B) into the blobs (object_tracker's one-pass grouping)
  task automatic blob_run(input int a, input int b, input int y, input int term);
    int gap, gap_y, keep, t, lo, hi;
    bit hit [NBLOB];
    lo = (term_b && term == 1) ? NBLOB / 2 : 0;    // with term B: slots split between the terms
    hi = (term_b && term == 0) ? NBLOB / 2 : NBLOB;
    gap = blob_cfg & 255;
    gap_y = (blob_cfg >> 8) & 255;
    keep = (blob_cfg >> 16) & 16'hFFFF;
    t = -1;
    for (int i = 0; i < NBLOB; i++) begin
      hit[i] = i >= lo && i < hi && bv[i] && a <= bx1[i] + gap && b + gap >= bx0[i] && y <= by1[i] + gap_y + 1;
      if (hit[i] && t < 0) t = i;
    end
    if (t >= 0) begin
      if (a < bx0[t]) bx0[t] = a;
      if (b > bx1[t]) bx1[t] = b;
      by1[t] = y;
      bn[t] += b - a + 1;
      for (int i = 0; i < NBLOB; i++) if (hit[i] && i != t) begin
        if (bx0[i] < bx0[t]) bx0[t] = bx0[i];
        if (bx1[i] > bx1[t]) bx1[t] = bx1[i];
        if (by0[i] < by0[t]) by0[t] = by0[i];
        bn[t] += bn[i];
        bv[i] = 0;
        bn[i] = 0;
      end
      return;
    end
    for (int i = lo; i < hi; i++) if (t < 0 && (!bv[i] || (y > by1[i] + gap_y + 1 && bn[i] < keep))) t = i;
    if (t < 0) begin
      if (blost < 255) blost++;
      return;
    end
    bv[t] = 1;
    bx0[t] = a;
    bx1[t] = b;
    by0[t] = y;
    by1[t] = y;
    bn[t] = b - a + 1;
  endtask
  function automatic bit pix_obj(input logic [23:0] p, input int ctrl, input int thr, input int yr, input int cbr,
                                 input int crr, input int satmin);
    int yy, b, r;
    yy = luma(p);
    if (!ctrl[2]) return ctrl[1] ? yy < thr : yy > thr;
    b = chroma_b(p);
    r = chroma_r(p);
    return yy >= (yr & 255) && yy <= ((yr >> 8) & 255) && b >= (cbr & 255) && b <= ((cbr >> 8) & 255) &&
           r >= (crr & 255) && r <= ((crr >> 8) & 255) && sat(p) >= (satmin & 255);
  endfunction
  task automatic add(input int x, input int y);
    n++;
    sx += x;
    sy += y;
    if (x < x0) x0 = x;
    if (x > x1) x1 = x;
    if (y < y0) y0 = y;
    if (y > y1) y1 = y;
  endtask

  task automatic find_dark(input int thr, input int run);
    measure(0, 0, w - 1, h - 1, thr, 1'b1, run);
    gn = n;
    gx0 = x0;
    gx1 = x1;
    gy0 = y0;
    gy1 = y1;
  endtask

  // symbol_overlay: shape 0 outline (LINE_W wide, inside the box), 1 filled, 2 crosshair through the
  // centre; dashed: 2^DASH_LOG2 on / off from x0 (horizontal strokes) or y0 (vertical strokes)
  task automatic draw(input bit en);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) out[y][x] = img[y][x];
    if (!en) return;
    for (int i = NOBJ - 1; i >= 0; i--) begin
      int c, bx0, bx1, by0, by1, lw, dl, shape, cx, cy;
      logic [23:0] col;
      c = obj[i][31:0];
      bx0 = obj[i][47:32];
      bx1 = obj[i][63:48];
      by0 = obj[i][79:64];
      by1 = obj[i][95:80];
      col = obj[i][119:96];
      if (c[0]) begin
        shape = (c >> 1) & 3;
        lw = (c >> 8) & 15;
        if (lw == 0) lw = 1;
        dl = 1 << ((c >> 12) & 7);
        cx = (bx0 + bx1) / 2;
        cy = (by0 + by1) / 2;
        if (shape == 3 && (bx0 > bx1 || by0 > by1)) ;  // empty box: nothing
        else if (shape == 3) begin                    // circle round the centre: R = half the larger side
          int r, ri, dx, dy, m;                       // oval (CTRL[5]): semi-axes half the width, half the height
          longint d2, ra, rb, ia, ib;
          bit ins;
          r = ((bx1 - bx0 > by1 - by0) ? bx1 - bx0 : by1 - by0) / 2;
          ri = r - lw;
          ra = (bx1 - bx0) / 2;
          rb = (by1 - by0) / 2;
          ia = ra - lw;
          ib = rb - lw;
          for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) begin
            dx = x - cx;
            dy = y - cy;
            m = (dx < 0 ? -dx : dx) < (dy < 0 ? -dy : dy) ? (dx < 0 ? -dx : dx) : (dy < 0 ? -dy : dy);
            if (c[5]) ins = longint'(dx * dx) * rb * rb + longint'(dy * dy) * ra * ra <= ra * ra * rb * rb &&
                               (ia < 0 || ib < 0 || longint'(dx * dx) * ib * ib + longint'(dy * dy) * ia * ia > ia * ia * ib * ib);
            else begin
              d2 = dx * dx + dy * dy;
              ins = d2 <= r * r && (ri < 0 || d2 > ri * ri);
            end
            if (ins && (!c[3] || (m / dl) % 2 == 0)) begin
              if (c[4]) for (int k = 0; k < 3; k++) out[y][x][8*k +: 8] = 8'((int'(out[y][x][8*k +: 8]) + int'(col[8*k +: 8])) / 2);
              else out[y][x] = col;
            end
          end
        end
        else for (int y = by0; y <= by1 && y < h; y++) for (int x = bx0; x <= bx1 && x < w; x++) begin
          bit h, v, hon, von, d;
          hon = !c[3] || ((x - bx0) / dl) % 2 == 0;
          von = !c[3] || ((y - by0) / dl) % 2 == 0;
          case (shape)
            0: begin
              h = y - by0 < lw || by1 - y < lw;
              v = x - bx0 < lw || bx1 - x < lw;
            end
            1: begin
              h = 1;
              v = 1;
              hon = 1;
              von = 1;
            end
            default: begin
              h = y >= cy - lw / 2 && y < cy - lw / 2 + lw;
              v = x >= cx - lw / 2 && x < cx - lw / 2 + lw;
            end
          endcase
          d = (h && hon) || (v && von);
          if (d) begin
            if (c[4]) for (int k = 0; k < 3; k++) out[y][x][8*k +: 8] = 8'((int'(out[y][x][8*k +: 8]) + int'(col[8*k +: 8])) / 2);
            else out[y][x] = col;
          end
        end
      end
    end
    for (int j = ntxt - 1; j >= 0; j--) begin
      int c, tx, ty, len, sc, fpx, nlen;
      string num;
      logic [23:0] col;
      c = txt[j][31:0];
      tx = txt[j][47:32];
      ty = txt[j][63:48];
      col = txt[j][87:64];
      len = (c >> 8) & 31;
      if (len > 16) len = 16;
      sc = (c >> 1) & 3;
      if (sc > 2) sc = 2;
      fpx = 1 << sc;                                  // font pixel size in video pixels
      num = $sformatf("%0d", fnum);
      nlen = c[4] ? num.len() : 0;
      if (c[0]) for (int k = 0; k < len + nlen; k++) begin
        logic [14:0] g;
        if (k < len) g = overlay_font_pkg::glyph(chr[j][8*k +: 8]);
        else g = overlay_font_pkg::glyph(num[k - len]);
        for (int r = 0; r < 6; r++) for (int q = 0; q < 4; q++)       // the 4 x 6 cell of character k
          for (int yy = 0; yy < fpx; yy++) for (int xx = 0; xx < fpx; xx++) begin
            int x, y;
            x = tx + (4 * k + q) * fpx + xx;
            y = ty + r * fpx + yy;
            if (x < w && y < h) begin
              if (q < 3 && r < 5 && g[r * 3 + q]) out[y][x] = col;
              else if (c[3]) out[y][x] = {1'b0, out[y][x][23:17], 1'b0, out[y][x][15:9], 1'b0, out[y][x][7:1]};
            end
          end
      end
    end
  endtask
endmodule
