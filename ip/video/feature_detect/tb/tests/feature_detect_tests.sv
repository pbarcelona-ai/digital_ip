// ***************
// Filename: feature_detect_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the feature_detect_tb testbench
//   (feature_detect_tb.sv), `included into that module, so they use its
//   signals directly. Tasks, in file order:
//     check              Counts an error and prints the message when the
//                        condition is false
//     set_ctrl / set_edge / set_motion / set_size
//                        Write CTRL, EDGE, MOTION, FRAME_SIZE (and the
//                        expected settings; CTRL.RESTART restarts the model)
//     texture / square   Test scenes: a blocky random texture (optionally
//                        shifted by whole cells), a square of a given luma
//     run_frame          Sends one frame, waits for done_o, steps the model
//                        with the shift feature_detect used and compares
//                        every pixel's edge and motion bits, EDGE_COUNT,
//                        MOTION_COUNT and SHIFT_EST
//     test_id_block      ID "FEAT", VERSION ("d.dd") and DATE (BCD
//                        mm/dd/yyyy) at the base address, read only
//                        (SLVERR); the rest of the map from 0x10
//     test_registers     reset values (EDGE 0x00080080, MOTION 0x00002214,
//                        no frame, background not valid) and read back
//     test_edges         A bright square and a vertical and a horizontal
//                        line on a flat scene: edges only around them, at
//                        thresholds 64, 200 and 2040 (none)
//     test_edge_span     The same scene with EDGE.SPAN 0, 1, 3 and 15
//     test_motion        A square moving over a still texture: no motion on
//                        the first frame (background filling), then motion
//                        where the square is and was
//     test_restart       CTRL.RESTART: the next frame fills the background
//                        again (no motion), the frame after it detects
//     test_rate          A square that stops: its motion fades as the
//                        background learns it, faster at RATE 1 than RATE 3
//     test_pan_auto      A texture panning 1 cell right and 1 down per frame
//                        with CTRL.AUTO_SHIFT: SHIFT_EST finds it, the next
//                        frames use it, and only the moving square moves
//     test_manual_shift  The pan with SHIFT written by the CPU (AUTO off)
//     test_disable       CTRL.EN = 0: no frame counted, no done_o
//     test_random        Random scenes, thresholds, spans, rates and shifts
//                        with stalls
// Date: 2026-10-14
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      if (errors < 20) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic set_ctrl(input int v);
    bfm.write(8'h08, v);
    e_ctrl = v & 'hF;
    if (v & 'h10) mdl.restart();
  endtask
  task automatic set_edge(input int t, input int span);
    e_edge = (span << 16) | t;
    bfm.write(8'h10, e_edge);
  endtask
  task automatic set_motion(input int t, input int span, input int rate);
    e_motion = (rate << 12) | (span << 8) | t;
    bfm.write(8'h14, e_motion);
  endtask
  task automatic set_size(input int w, input int h);
    W = w;
    H = h;
    bfm.write(8'h0C, (h << 16) | w);
  endtask

  // blocky random texture: 4 x 4 blocks of random grey (seeded), content shifted right by sx and down
  // by sy pixels (the seed fixes the pattern, so shifting it moves the same texture)
  int tex [MAXH + 64][MAXW + 64];
  task automatic make_texture(input int seed, input int lo, input int hi);
    int s;
    s = seed;
    for (int y = 0; y < MAXH + 64; y += 4) for (int x = 0; x < MAXW + 64; x += 4) begin
      int v;
      v = lo + $urandom(s) % (hi - lo + 1);
      s = s * 1103515245 + 12345;
      for (int dy = 0; dy < 4; dy++) for (int dx = 0; dx < 4; dx++) tex[y + dy][x + dx] = v;
    end
  endtask
  task automatic texture(input int sx, input int sy);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      logic [7:0] v;
      v = 8'(tex[y - sy + 32][x - sx + 32]);
      vid.img[y][x] = {v, v, v};
    end
  endtask
  task automatic flat(input int v);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) vid.img[y][x] = {3{8'(v)}};
  endtask
  task automatic square(input int x0, input int y0, input int s, input int v);
    for (int y = y0; y < y0 + s && y < H; y++) for (int x = x0; x < x0 + s && x < W; x++)
      if (x >= 0 && y >= 0) vid.img[y][x] = {3{8'(v)}};
  endtask

  task automatic run_frame(input string name);
    int d0, be, bm, mism;
    logic [31:0] ce, cm, est;
    d0 = dones;
    vid.send(W, H);
    for (int t = 0; t < 4000 && dones == d0; t++) @(posedge clk);
    check(dones == d0 + 1, $sformatf("%s: %0d done_o pulses, expected 1", name, dones - d0));
    mdl.w = W;
    mdl.h = H;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) mdl.img[y][x] = vid.img[y][x];
    mdl.step(e_ctrl, e_edge, e_motion, used_x, used_y);
    be = 0;
    bm = 0;
    mism = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      if (cap[y][x][0] !== mdl.edg[y][x]) be++;
      if (cap[y][x][1] !== mdl.mot[y][x]) bm++;
      if ((cap[y][x][0] !== mdl.edg[y][x] || cap[y][x][1] !== mdl.mot[y][x]) && mism < 3) begin
        mism++;
        if (errors + mism < 8) $display("  %s: pixel (%0d,%0d) edge %b motion %b, model %b %b", name, x, y, cap[y][x][0],
                                        cap[y][x][1], mdl.edg[y][x], mdl.mot[y][x]);
      end
    end
    check(be == 0 && bm == 0, $sformatf("%s: %0d edge and %0d motion bits differ from the model", name, be, bm));
    bfm.read(8'h28, ce);
    bfm.read(8'h2C, cm);
    check(ce == mdl.n_edge && cm == mdl.n_motion, $sformatf("%s: EDGE_COUNT %0d MOTION_COUNT %0d, model %0d %0d", name, ce, cm,
                                                           mdl.n_edge, mdl.n_motion));
    if (mdl.est_valid) begin
      bfm.read(8'h1C, est);
      check($signed(est[7:0]) == mdl.est_x && $signed(est[15:8]) == mdl.est_y,
            $sformatf("%s: SHIFT_EST %0d,%0d, model %0d,%0d", name, $signed(est[7:0]), $signed(est[15:8]), mdl.est_x, mdl.est_y));
    end
  endtask

  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    bfm.read_abs(8'h0, id);
    bfm.read_abs(8'h4, ver);
    bfm.read_abs(8'h8, date);
    bfm.read_abs(8'hC, rsv);
    check(id == "FEAT", $sformatf("ID %h (\"%s\"), expected \"FEAT\"", id, id));
    check(ver == dut.u_regs.IP_VERSION && ver[31:24] >= "0" && ver[31:24] <= "9" && ver[23:16] == "." &&
          ver[15:8] >= "0" && ver[15:8] <= "9" && ver[7:0] >= "0" && ver[7:0] <= "9",
          $sformatf("VERSION %h (\"%s\"), expected \"d.dd\" = \"%s\"", ver, ver, dut.u_regs.IP_VERSION));
    check(date == dut.u_regs.IP_DATE && date[31:24] >= 8'h01 && date[31:24] <= 8'h12 && date[23:16] >= 8'h01 &&
          date[23:16] <= 8'h31 && date[15:0] >= 16'h2000,
          $sformatf("DATE %h, expected a BCD mm/dd/yyyy date = %h", date, dut.u_regs.IP_DATE));
    check(rsv == 0, $sformatf("0x0C reads %h, expected 0", rsv));
    for (int a = 0; a < 16; a += 4) begin               // ID / VERSION / DATE: SLVERR, reserved: OKAY
      bfm.write_abs(8'(a), 32'hA5A5_5A5A);
      check(bfm.last_resp == ((a < 12) ? 2'b10 : 2'b00), $sformatf("write to 0x%0h answered %b", a, bfm.last_resp));
    end
    bfm.resp_errors = 0;
    bfm.read_abs(8'h0, v);
    check(v == id, "ID changed by a write");
    $display("[%0t] test_id_block: ID \"%s\", VERSION \"%s\", DATE %0h/%0h/%0h", $time, id, ver, date[31:24],
             date[23:16], date[15:0]);
  endtask

  task automatic test_registers();
    logic [31:0] v;
    bfm.read(8'h10, v);
    check(v == 32'h0008_0080, $sformatf("EDGE reset %h", v));
    bfm.read(8'h14, v);
    check(v == 32'h0000_2214, $sformatf("MOTION reset %h", v));
    bfm.read(8'h20, v);
    check(v == 0, $sformatf("STATUS reset %h", v));
    bfm.read(8'h24, v);
    check(v == 0, $sformatf("FRAMES reset %h", v));
    bfm.write(8'h18, 32'h0000_FE03);
    bfm.read(8'h18, v);
    check(v == 32'h0000_FE03, $sformatf("SHIFT reads %h", v));
    bfm.write(8'h18, 0);
    set_size(MAXW, MAXH);
    bfm.read(8'h0C, v);
    check(v == ((MAXH << 16) | MAXW), $sformatf("FRAME_SIZE reads %h", v));
    $display("[%0t] test_registers: reset values, read back", $time);
  endtask

  task automatic edge_scene();
    flat(120);
    square(10, 8, 12, 220);
    for (int y = 4; y < H - 4; y++) vid.img[y][40] = {3{8'd20}};    // a vertical line
    for (int x = 30; x < W - 4; x++) vid.img[36][x] = {3{8'd200}};  // a horizontal one
  endtask
  int int_t [3] = '{64, 200, 2040};
  task automatic test_edges();
    set_size(MAXW, MAXH);
    set_ctrl(32'h13);                                   // on, edges, restart
    foreach (int_t[i]) begin
      set_edge(int_t[i], 8);
      edge_scene();
      run_frame($sformatf("edges, threshold %0d", int_t[i]));
      if (int_t[i] == 2040) check(mdl.n_edge == 0, "model: threshold 2040 finds no edge");
      else check(mdl.n_edge > 0 && !mdl.edg[2][2] && !mdl.edg[H - 1][W - 1] && !mdl.edg[30][20],
                 $sformatf("model: edges at threshold %0d: %0d pixels", int_t[i], mdl.n_edge));
    end
    $display("[%0t] test_edges: square and lines at thresholds 64, 200, 2040", $time);
  endtask
  task automatic test_edge_span();
    int n [4];
    int sp [4] = '{0, 1, 3, 15};
    set_ctrl(32'h3);
    for (int k = 0; k < 4; k++) begin
      set_edge(128, sp[k]);
      edge_scene();
      run_frame($sformatf("edge span %0d", sp[k]));
      n[k] = mdl.n_edge;
    end
    check(n[0] == n[1] && n[2] > n[1] && n[3] > n[2], $sformatf("model: spans 0/1/3/15 give %0d %0d %0d %0d edge pixels",
                                                                 n[0], n[1], n[2], n[3]));
    $display("[%0t] test_edge_span: spans 0 and 1 equal, 3 and 15 wider", $time);
  endtask

  task automatic test_motion();
    make_texture(7, 60, 160);
    set_edge(128, 8);
    set_motion(20, 2, 2);
    set_ctrl(32'h17);                                   // on, edges, motion, restart
    for (int f = 0; f < 6; f++) begin
      texture(0, 0);
      square(4 + 6 * f, 20, 10, 250);
      run_frame($sformatf("moving square, frame %0d", f));
      if (f == 0) check(mdl.n_motion == 0, "model: no motion while the background fills");
      else check(mdl.mot[25][4 + 6 * f + 9] && !mdl.mot[5][50], $sformatf("model: frame %0d: motion on the square's new edge only", f));
    end
    $display("[%0t] test_motion: a square moving over a still texture", $time);
  endtask

  task automatic test_restart();
    set_ctrl(32'h17);
    texture(0, 0);
    square(30, 20, 10, 250);
    run_frame("after RESTART");
    check(mdl.n_motion == 0, "model: no motion right after RESTART");
    square(10, 10, 10, 250);
    run_frame("second frame after RESTART");
    check(mdl.n_motion > 0, "model: motion again on the second frame");
    $display("[%0t] test_restart: background filled again, then detecting", $time);
  endtask

  task automatic test_rate();
    int m [6], last [4];
    for (int r = 1; r <= 3; r += 2) begin
      set_motion(20, 2, r);
      set_ctrl(32'h17);
      for (int f = 0; f < 6; f++) begin
        texture(0, 0);
        square((f < 2) ? 4 * f : 8, 20, 10, 250);   // moves, then stays at x 8
        run_frame($sformatf("rate %0d, frame %0d", r, f));
        m[f] = mdl.n_motion;
      end
      last[r] = m[5];
      if (r == 1) check(m[5] < m[2], $sformatf("model: rate 1: motion fades (%0d -> %0d)", m[2], m[5]));
    end
    check(last[1] < last[3], $sformatf("model: rate 1 fades faster than rate 3 (%0d, %0d left)", last[1], last[3]));
    set_motion(20, 2, 2);
    $display("[%0t] test_rate: a stopped square fades into the background (RATE 1, 3)", $time);
  endtask

  task automatic test_pan_auto();
    logic [31:0] v;
    make_texture(11, 40, 200);
    set_ctrl(32'h1F);                                   // on, edges, motion, auto shift, restart
    for (int f = 0; f < 7; f++) begin
      texture(4 * f, 4 * f);                            // 1 cell right and down per frame
      square(50 - 4 * f, 30, 4, 255);
      run_frame($sformatf("pan, frame %0d", f));
      if (f >= 1) check(mdl.est_x == 1 && mdl.est_y == 1, $sformatf("model: frame %0d: shift found %0d,%0d", f, mdl.est_x,
                                                                      mdl.est_y));
    end
    bfm.read(8'h30, v);
    check(v[7:0] == 1 && v[15:8] == 1, $sformatf("SHIFT_USED %h, expected 1,1", v));
    $display("[%0t] test_pan_auto: a panning texture, shift found and applied", $time);
  endtask

  task automatic test_manual_shift();
    set_ctrl(32'h17);                                   // auto off
    bfm.write(8'h18, 32'h0000_0101);                    // 1, 1
    for (int f = 0; f < 4; f++) begin
      texture(4 * f, 4 * f);
      run_frame($sformatf("manual shift, frame %0d", f));
    end
    bfm.write(8'h18, 0);
    $display("[%0t] test_manual_shift: SHIFT written by the CPU", $time);
  endtask

  task automatic test_disable();
    logic [31:0] f0, f1;
    int d0;
    bfm.read(8'h24, f0);
    d0 = dones;
    set_ctrl(32'h0);
    vid.send(W, H);
    repeat (200) @(posedge clk);
    bfm.read(8'h24, f1);
    check(f1 == f0 && dones == d0, "disabled: a frame was counted");
    $display("[%0t] test_disable: no frame while CTRL.EN = 0", $time);
  endtask

  task automatic test_random();
    stall_pct = 25;
    vid.gap_pct = 15;
    for (int run = 0; run < 3; run++) begin
      int sx, sy;
      set_size(32 + 4 * $urandom_range(8), 24 + 4 * $urandom_range(6));
      make_texture(100 + run, $urandom_range(80), 120 + $urandom_range(135));
      set_edge($urandom_range(40, 400), $urandom_range(15));
      set_motion($urandom_range(5, 40), $urandom_range(6), $urandom_range(4));
      set_ctrl(32'h17 | ($urandom_range(1) << 3));
      sx = $urandom_range(2);
      sy = $urandom_range(2);
      bfm.write(8'h18, ((sy & 255) << 8) | (sx & 255));
      for (int f = 0; f < 5; f++) begin
        texture(4 * sx * f, 4 * sy * f);
        square($urandom_range(W - 1), $urandom_range(H - 1), $urandom_range(3, 12), $urandom_range(255));
        run_frame($sformatf("random run %0d frame %0d", run, f));
      end
    end
    bfm.write(8'h18, 0);
    stall_pct = 0;
    vid.gap_pct = 0;
    $display("[%0t] test_random: random scenes, settings and shifts with stalls", $time);
  endtask
