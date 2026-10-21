// ***************
// Filename: object_tracker_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the object_tracker_tb testbench
//   (object_tracker_tb.sv), `included into that module, so they use its
//   signals directly. Tasks, in file order:
//     check              Counts an error and prints the message when the
//                        condition is false
//     configure          Writes CTRL, FRAME_SIZE, THRESH and the window (and
//                        the expected settings)
//     scene              A test image: light background with a little noise,
//                        a dark (or bright) rectangle, optional single-pixel
//                        specks and a 1-pixel-wide line
//     run_frame          Sends one frame, then compares COUNT, BOX_X, BOX_Y,
//                        SUM_X, SUM_Y, FRAMES and the blobs (BLOB_X / BLOB_Y /
//                        BLOB_N, STATUS.BLOB_LOST) with the model; done_o
//                        must pulse once
//     test_id_block        ID "OTRK", VERSION ("d.dd") and DATE (BCD
//                          mm/dd/yyyy) at the base address, read only
//                          (SLVERR); the rest of the map from 0x10
//     test_registers     control registers read back, reset results
//                        (COUNT 0, empty box)
//     test_dark_object   A dark rectangle on a light scene: exact box, count
//                        and sums (whole-frame window)
//     test_bright_object CTRL.POL = 0: a bright object on a dark scene
//     test_window        Window smaller than the object (box clipped to it);
//                        a window written in the middle of a frame applies
//                        from the next frame
//     test_run_filter    Single-pixel specks and a 1-pixel-wide line are
//                        ignored with MIN_RUN 2 and counted with MIN_RUN 0 /
//                        1; MIN_RUN 15 with runs of 14, 15 and 16 pixels
//     test_empty         No object: COUNT 0, box x min > x max
//     test_disable       CTRL.ENABLE = 0: no frame measured, no done_o
//     test_status        STATUS[0] during a frame, STATUS[1] for a
//                        whole-frame window, STATUS[31:16] = FRAMES
//     test_random        24 random scenes, thresholds, polarities, run
//                        lengths and windows with random stalls
//     colour_regs        Writes RUN, Y_RANGE, CB_RANGE, CR_RANGE, SAT_MIN (and
//                        the expected settings)
//     test_colour        CTRL.MODE = 1: a skin-tone patch (face) and a
//                        saturated red patch (car paint) on a grey scene;
//                        each colour range picks only its own patch, SAT_MIN
//                        rejects the grey; reset ranges read back
//     test_run_band      RUN.MIN_W / MAX_W: of runs 6, 12 and 30 pixels wide,
//                        a band keeps only those inside it (a run is judged
//                        when it ends, at a non-object pixel or the end of
//                        the line, by its whole length: a run longer than
//                        MAX_W reaching into the window is not counted)
//     test_scratch       SCRATCH[0..27] read back what was written, each its
//                        own word
//     test_blobs         Three dark objects, specks and a U shape: one blob
//                        each, small ones dropped (KEEP), the U joined into
//                        one, GAP, GAP_Y; more objects than slots (BLOB_LOST);
//                        random scenes and BLOB_CFG against the model
//     test_terms         Two terms (feat_i = the pixel's LSBs): CTRL.FEAT_A 0-3
//                        (test, test or motion, test and motion, motion),
//                        CTRL.TERM_B with RUN_B (edges, own blob slots), RUN_B
//                        read back, random features and settings with stalls
//     test_random_colour 16 random colour scenes and settings with stalls
// Date: 2026-10-21
// ***************
  int e_runb = 0;                                    // RUN_B expected
  int e_blob = 32'h0202;                             // BLOB_CFG expected (reset: GAP 2, GAP_Y 2, KEEP 0)
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      if (errors < 20) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic configure(input bit en, input bit dark, input int run, input int thr, input int wx0,
                           input int wy0, input int wx1, input int wy1);
    bfm.write(8'h0C, (H << 16) | W);
    bfm.write(8'h10, thr);
    bfm.write(8'h14, (wx1 << 16) | wx0);
    bfm.write(8'h18, (wy1 << 16) | wy0);
    bfm.write(8'h08, en | (dark << 1) | (run << 8));
    e_ctrl = en | (dark << 1) | (run << 8);
    e_en = en;
    e_dark = dark;
    e_run = run;
    e_thr = thr;
    e_win = '{wx0, wy0, wx1, wy1};
  endtask

  // background bg +- 4, a rectangle of value obj, nspeck single pixels and (line) a vertical 1-pixel line
  task automatic scene(input int bg, input int obj, input int x0, input int y0, input int x1, input int y1,
                       input int nspeck, input bit line);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      logic [7:0] v;
      v = 8'(bg + $urandom_range(8) - 4);
      if (x >= x0 && x <= x1 && y >= y0 && y <= y1) v = 8'(obj + $urandom_range(6) - 3);
      if (line && x == W - 5 && y > 3 && y < H - 3) v = 8'(obj);
      vid.img[y][x] = {v, v, v};
    end
    for (int k = 0; k < nspeck; k++) begin                // single pixels, never next to the line (a 2-pixel run)
      int sx;
      sx = 2 * $urandom_range(W / 2 - 1);
      if (sx >= W - 6 && sx <= W - 4) sx -= 8;
      vid.img[$urandom_range(H - 1)][sx] = {3{8'(obj)}};
    end
  endtask

  task automatic run_frame(input string name);
    int f0, d0;
    logic [31:0] n, bx, by, sx, sy, fr;
    bfm.read(8'h1C, fr);
    f0 = fr;
    d0 = dones;
    vid.send(W, H);
    repeat (4) @(posedge clk);
    mdl.w = W;
    mdl.h = H;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) mdl.img[y][x] = vid.img[y][x];
    mdl.blob_cfg = e_blob;
    mdl.run_b = e_runb;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      mdl.fe[y][x] = feat_on & vid.img[y][x][16];
      mdl.fm[y][x] = feat_on & vid.img[y][x][8];
    end
    mdl.measure_cfg(e_win[0], e_win[1], e_win[2], e_win[3], e_ctrl, e_thr, e_runw, e_yr, e_cbr, e_crr, e_sat);
    bfm.read(8'h20, n);
    bfm.read(8'h24, bx);
    bfm.read(8'h28, by);
    bfm.read(8'h2C, sx);
    bfm.read(8'h30, sy);
    bfm.read(8'h1C, fr);
    if (!e_en) begin
      check(fr == f0 && dones == d0, $sformatf("%s: disabled tracker measured a frame", name));
      return;
    end
    check(fr == f0 + 1, $sformatf("%s: FRAMES %0d, expected %0d", name, fr, f0 + 1));
    check(dones == d0 + 1, $sformatf("%s: %0d done_o pulses, expected 1", name, dones - d0));
    check(n == mdl.n && bx == {16'(mdl.x1), 16'(mdl.x0)} && by == {16'(mdl.y1), 16'(mdl.y0)},
          $sformatf("%s: COUNT %0d box x %0d-%0d y %0d-%0d, model %0d x %0d-%0d y %0d-%0d", name, n, bx[15:0], bx[31:16],
                    by[15:0], by[31:16], mdl.n, mdl.x0, mdl.x1, mdl.y0, mdl.y1));
    check(sx == 32'(mdl.sx) && sy == 32'(mdl.sy), $sformatf("%s: SUM %0d / %0d, model %0d / %0d", name, sx, sy, mdl.sx, mdl.sy));
    for (int i = 0; i < 8; i++) begin
      logic [31:0] q;
      bfm.read(9'(9'h130 + 4 * i), n);                // BLOB_N / BLOB_X / BLOB_Y[i] (base 0x10)
      bfm.read(9'(9'h0F0 + 4 * i), bx);
      bfm.read(9'(9'h110 + 4 * i), by);
      if (mdl.bn[i] == 0) check(n == 0 && bx == 32'h0 && by == 32'h0,
                                $sformatf("%s: blob %0d: %0d pixels %h %h, model none", name, i, n, bx, by));
      else check(n == mdl.bn[i] && bx == {16'(mdl.bx1[i]), 16'(mdl.bx0[i])} && by == {16'(mdl.by1[i]), 16'(mdl.by0[i])},
                 $sformatf("%s: blob %0d: %0d pixels x %0d-%0d y %0d-%0d, model %0d x %0d-%0d y %0d-%0d", name, i, n,
                           bx[15:0], bx[31:16], by[15:0], by[31:16], mdl.bn[i], mdl.bx0[i], mdl.bx1[i], mdl.by0[i],
                           mdl.by1[i]));
      if (i == 0) begin
        bfm.read(8'h34, q);
        check(q[15:8] == 8'(mdl.blost), $sformatf("%s: STATUS.BLOB_LOST %0d, model %0d", name, q[15:8], mdl.blost));
      end
    end
  endtask

  task automatic test_registers();
    logic [31:0] v;
    bfm.read(8'h20, v);
    check(v == 0, $sformatf("reset COUNT %0d", v));
    bfm.read(8'h24, v);
    check(v == 32'h0000_FFFF, $sformatf("reset BOX_X %h (empty: x min > x max)", v));
    configure(0, 1, 3, 77, 1, 2, 30, 20);
    bfm.read(8'h08, v);
    check(v == 32'h0302, $sformatf("CTRL reads %h", v));
    bfm.read(8'h10, v);
    check(v == 77, $sformatf("THRESH reads %0d", v));
    bfm.read(8'h14, v);
    check(v == {16'd30, 16'd1}, $sformatf("WIN_X reads %h", v));
    $display("[%0t] test_registers: reset results, control registers read back", $time);
  endtask

  task automatic test_dark_object();
    configure(1, 1, 2, 80, 0, 0, W - 1, H - 1);
    scene(200, 40, 12, 8, 21, 27, 0, 0);
    run_frame("dark rectangle");
    check(mdl.x0 == 12 && mdl.x1 == 21 && mdl.y0 == 8 && mdl.y1 == 27 && mdl.n == 200, "model: dark rectangle not found");
    scene(180, 30, 0, 0, 5, 3, 0, 0);
    run_frame("dark rectangle at the top-left corner");
    scene(180, 30, W - 6, H - 4, W - 1, H - 1, 0, 0);
    run_frame("dark rectangle at the bottom-right corner");
    $display("[%0t] test_dark_object: exact box, count and sums", $time);
  endtask

  task automatic test_bright_object();
    configure(1, 0, 2, 150, 0, 0, W - 1, H - 1);
    scene(30, 230, 20, 5, 40, 15, 0, 0);
    run_frame("bright rectangle, POL = 0");
    $display("[%0t] test_bright_object: bright object on a dark scene", $time);
  endtask

  task automatic test_window();
    int s0;
    configure(1, 1, 2, 80, 15, 10, 30, 20);
    scene(200, 40, 10, 5, 35, 30, 0, 0);
    run_frame("window inside the object");
    check(mdl.x0 == 15 && mdl.x1 == 30 && mdl.y0 == 10 && mdl.y1 == 20, "model: box not clipped to the window");
    // window written while a frame is being measured: that frame keeps the old one
    scene(200, 40, 4, 4, 40, 30, 0, 0);
    s0 = vid.sent;
    fork
      run_frame("window changed in the middle of this frame");
      begin
        for (int t = 0; t < 200000 && vid.sent < s0 + W * H / 2; t++) @(posedge clk);
        bfm.write(8'h14, (44 << 16) | 2);
        bfm.write(8'h18, (34 << 16) | 2);
      end
    join
    e_win = '{2, 2, 44, 34};
    run_frame("frame after the window change");
    $display("[%0t] test_window: results clipped to the window, a new window applies at the next frame", $time);
  endtask

  task automatic test_run_filter();
    configure(1, 1, 2, 80, 0, 0, W - 1, H - 1);
    scene(200, 40, 0, 0, -1, -1, 12, 1);                  // no rectangle: specks and a 1-pixel line
    run_frame("specks and a thin line, MIN_RUN 2");
    check(mdl.n == 0, $sformatf("model: run filter kept %0d pixels", mdl.n));
    for (int r = 0; r <= 1; r++) begin
      configure(1, 1, r, 80, 0, 0, W - 1, H - 1);
      run_frame($sformatf("specks and a thin line, MIN_RUN %0d", r));
      check(mdl.n > 0, "model: specks not counted without the run filter");
    end
    configure(1, 1, 15, 80, 0, 0, W - 1, H - 1);
    scene(200, 40, 2, 2, 15, 2, 0, 0);                    // 14 pixels
    for (int x = 2; x <= 16; x++) vid.img[6][x] = {3{8'd40}};    // 15 pixels
    for (int x = 20; x <= 35; x++) vid.img[10][x] = {3{8'd40}};  // 16 pixels
    run_frame("runs of 14, 15 and 16 pixels, MIN_RUN 15");
    check(mdl.n == 31 && mdl.y0 == 6 && mdl.y1 == 10, $sformatf("model: MIN_RUN 15 kept %0d pixels", mdl.n));
    $display("[%0t] test_run_filter: short runs ignored, MIN_RUN 0, 1, 2 and 15", $time);
  endtask

  task automatic test_empty();
    configure(1, 1, 2, 80, 0, 0, W - 1, H - 1);
    scene(200, 200, 0, 0, -1, -1, 0, 0);
    run_frame("no object");
    $display("[%0t] test_empty: COUNT 0, empty box", $time);
  endtask

  task automatic test_disable();
    configure(0, 1, 2, 80, 0, 0, W - 1, H - 1);
    scene(200, 40, 10, 10, 20, 20, 0, 0);
    run_frame("tracker disabled");
    $display("[%0t] test_disable: no measurement while CTRL.ENABLE = 0", $time);
  endtask

  task automatic test_status();
    logic [31:0] v, fr;
    int s0;
    configure(1, 1, 2, 80, 0, 0, W - 1, H - 1);
    scene(200, 40, 10, 10, 20, 20, 0, 0);
    s0 = vid.sent;
    fork
      run_frame("STATUS, whole-frame window");
      begin
        for (int t = 0; t < 200000 && vid.sent < s0 + 10; t++) @(posedge clk);
        bfm.read(8'h34, v);
        check(v[1:0] == 2'b11, $sformatf("STATUS %b during a whole-frame frame, expected 11", v[1:0]));
      end
    join
    bfm.read(8'h34, v);
    bfm.read(8'h1C, fr);
    check(v[0] == 0 && v[31:16] == fr[15:0], $sformatf("STATUS %h after the frame, FRAMES %0d", v, fr));
    configure(1, 1, 2, 80, 1, 0, W - 1, H - 1);
    run_frame("STATUS, window narrower than the frame");
    bfm.read(8'h34, v);
    check(v[1] == 0, "STATUS[1] set for a window narrower than the frame");
    $display("[%0t] test_status: in-frame and whole-window flags, frame count", $time);
  endtask

  task automatic test_random();
    stall_pct = 30;
    vid.gap_pct = 20;
    for (int f = 0; f < 24; f++) begin
      int a, b, c, d, dark, bg, ob;
      dark = $urandom_range(1);
      bg = dark ? 150 + $urandom_range(100) : $urandom_range(100);
      ob = dark ? $urandom_range(100) : 150 + $urandom_range(100);
      a = $urandom_range(W - 1);
      b = a + $urandom_range(W - 1 - a);
      c = $urandom_range(H - 1);
      d = c + $urandom_range(H - 1 - c);
      scene(bg, ob, a, c, b, d, $urandom_range(10), $urandom_range(1));
      a = $urandom_range(W - 1);
      c = $urandom_range(H - 1);
      configure(1, dark, $urandom_range(5), 110 + $urandom_range(30), a, c, a + $urandom_range(W), c + $urandom_range(H));
      run_frame($sformatf("random frame %0d", f));
    end
    stall_pct = 0;
    vid.gap_pct = 0;
    $display("[%0t] test_random: 24 random scenes and settings with stalls", $time);
  endtask

  // ID block at the base address: ID, VERSION (ASCII "d.dd"), DATE (BCD mm/dd/yyyy), 0x0C reserved;
  // read only (writes ignored); the rest of the map starts at 0x10 (bfm.base)
  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    bfm.read_abs(8'h0, id);
    bfm.read_abs(8'h4, ver);
    bfm.read_abs(8'h8, date);
    bfm.read_abs(8'hC, rsv);
    check(id == "OTRK", $sformatf("ID %h (\"%s\"), expected \"OTRK\"", id, id));
    check(ver == dut.u_regs.IP_VERSION && ver[31:24] >= "0" && ver[31:24] <= "9" && ver[23:16] == "." &&
          ver[15:8] >= "0" && ver[15:8] <= "9" && ver[7:0] >= "0" && ver[7:0] <= "9",
          $sformatf("VERSION %h (\"%s\"), expected \"d.dd\" = \"%s\"", ver, ver, dut.u_regs.IP_VERSION));
    check(date == dut.u_regs.IP_DATE && date[31:28] <= 1 && date[27:24] <= 9 && date[31:24] >= 8'h01 && date[31:24] <= 8'h12 &&
          date[23:16] >= 8'h01 && date[23:16] <= 8'h31 && date[19:16] <= 9 && date[15:0] >= 16'h2000 &&
          date[15:12] <= 9 && date[11:8] <= 9 && date[7:4] <= 9 && date[3:0] <= 9,
          $sformatf("DATE %h, expected a BCD mm/dd/yyyy date = %h", date, dut.u_regs.IP_DATE));
    check(rsv == 0, $sformatf("0x0C reads %h, expected 0", rsv));
    for (int a = 0; a < 16; a += 4) begin               // ID / VERSION / DATE: SLVERR, reserved: OKAY
      bfm.write_abs(8'(a), 32'hA5A5_5A5A);
      check(bfm.last_resp == ((a < 12) ? 2'b10 : 2'b00), $sformatf("write to 0x%0h answered %b", a, bfm.last_resp));
    end
    bfm.resp_errors = 0;
    bfm.read_abs(8'h0, v);
    check(v == id, "ID changed by a write");
    bfm.read_abs(8'h4, v);
    check(v == ver, "VERSION changed by a write");
    bfm.read_abs(8'h8, v);
    check(v == date, "DATE changed by a write");
    $display("[%0t] test_id_block: ID \"%s\", VERSION \"%s\", DATE %0h/%0h/%0h", $time, id, ver, date[31:24],
             date[23:16], date[15:0]);
  endtask

  // colour-mode settings: RUN, Y_RANGE, CB_RANGE, CR_RANGE, SAT_MIN (offsets from the map after the ID block)
  task automatic colour_regs(input int runw, input int yr, input int cbr, input int crr, input int satmin);
    bfm.write(8'h38, runw);
    bfm.write(8'h3C, yr);
    bfm.write(8'h40, cbr);
    bfm.write(8'h44, crr);
    bfm.write(8'h48, satmin);
    e_runw = runw;
    e_yr = yr;
    e_cbr = cbr;
    e_crr = crr;
    e_sat = satmin;
  endtask

  // grey scene (luma bg +- 4) with a rectangle of colour col ({B, G, R}) at x0..x1, y0..y1
  task automatic colour_patch(input logic [23:0] col, input int x0, input int y0, input int x1, input int y1);
    for (int y = y0; y <= y1; y++) for (int x = x0; x <= x1; x++) vid.img[y][x] = col;
  endtask

  task automatic test_colour();
    logic [31:0] v;
    bfm.read(8'h3C, v);
    check(v == 32'hFF00, $sformatf("Y_RANGE resets to %h, expected 0000FF00 (every luma)", v));
    bfm.read(8'h48, v);
    check(v == 0, $sformatf("SAT_MIN resets to %h", v));
    scene(120, 120, 0, 0, -1, -1, 0, 0);
    colour_patch(24'h5A7DD2, 4, 4, 13, 15);              // skin tone {B, G, R} = (90, 125, 210)
    colour_patch(24'h2020D0, 24, 20, 41, 27);            // saturated red paint
    configure(1, 0, 2, 0, 0, 0, W - 1, H - 1);
    bfm.write(8'h08, 32'h205);                           // enabled, MODE = 1 (colour), MIN_RUN 2
    e_ctrl = 32'h205;
    colour_regs(0, 16'hE628, 16'h7F4D, 16'hAD85, 8'd10);  // skin: Y 40-230, Cb 77-127, Cr 133-173
    run_frame("colour mode: skin-tone ranges");
    check(mdl.n == 120 && mdl.x0 == 4 && mdl.x1 == 13 && mdl.y0 == 4 && mdl.y1 == 15,
          $sformatf("model: skin ranges found %0d pixels x %0d-%0d y %0d-%0d, expected the 10 x 12 patch", mdl.n,
                    mdl.x0, mdl.x1, mdl.y0, mdl.y1));
    colour_regs(0, 16'hF014, 16'hFF00, 16'hFFAF, 8'd75);  // red paint: Cr >= 175, saturation >= 75
    run_frame("colour mode: saturated red");
    check(mdl.n == 144 && mdl.x0 == 24 && mdl.y0 == 20, $sformatf("model: red ranges found %0d pixels", mdl.n));
    colour_regs(0, 16'hFF00, 16'hFF00, 16'hFF00, 8'd200); // nothing is that saturated
    run_frame("colour mode: SAT_MIN above every pixel");
    check(mdl.n == 0, "model: SAT_MIN 200 kept pixels");
    colour_regs(0, 16'hFF00, 16'hFF00, 16'hFF00, 8'd0);   // every pixel
    run_frame("colour mode: full ranges");
    check(mdl.n == W * H, $sformatf("model: full ranges kept %0d of %0d pixels", mdl.n, W * H));
    colour_regs(0, 16'hFF00, 16'hFF00, 16'hFF00, 8'd0);
    configure(1, 1, 2, 80, 0, 0, W - 1, H - 1);
    $display("[%0t] test_colour: skin and red ranges each find their own patch, SAT_MIN, full ranges", $time);
  endtask

  task automatic test_run_band();
    logic [31:0] v;
    configure(1, 1, 2, 80, 0, 0, W - 1, H - 1);
    scene(200, 200, 0, 0, -1, -1, 0, 0);
    for (int x = 2; x <= 7; x++) vid.img[3][x] = {3{8'd40}};      // 6 pixels
    for (int x = 10; x <= 21; x++) vid.img[9][x] = {3{8'd40}};    // 12 pixels
    for (int x = 10; x <= 39; x++) vid.img[15][x] = {3{8'd40}};   // 30 pixels
    for (int x = W - 8; x < W; x++) vid.img[20][x] = {3{8'd40}};  // 8 pixels up to the end of the line
    colour_regs(32'h000F_0008, 16'hFF00, 16'hFF00, 16'hFF00, 0);   // 8 .. 15
    run_frame("RUN band 8-15");
    check(mdl.n == 20 && mdl.y0 == 9 && mdl.y1 == 20, $sformatf("model: band 8-15 kept %0d pixels", mdl.n));
    colour_regs(32'h0000_0010, 16'hFF00, 16'hFF00, 16'hFF00, 0);   // 16 and wider
    run_frame("RUN min 16, no max");
    check(mdl.n == 30 && mdl.y0 == 15 && mdl.y1 == 15, $sformatf("model: min 16 kept %0d pixels", mdl.n));
    colour_regs(32'h0007_0000, 16'hFF00, 16'hFF00, 16'hFF00, 0);   // MIN_W 0: CTRL.MIN_RUN 2, max 7
    run_frame("RUN max 7, MIN_RUN 2");
    check(mdl.n == 6 && mdl.y0 == 3 && mdl.y1 == 3, $sformatf("model: max 7 kept %0d pixels", mdl.n));
    configure(1, 1, 2, 80, 12, 0, 30, H - 1);                     // the window cuts the runs
    colour_regs(32'h000F_0008, 16'hFF00, 16'hFF00, 16'hFF00, 0);
    run_frame("RUN band 8-15, runs cut by the window");
    // judged by the whole run: the 30-pixel run (too long) is not counted where it crosses the window,
    // the 12-pixel run is counted only inside it
    check(mdl.n == 21 - 12 + 1 && mdl.y0 == 9 && mdl.y1 == 9 && mdl.x0 == 12 && mdl.x1 == 21,
          $sformatf("model: band 8-15 in window 12-30 kept %0d pixels, y %0d-%0d", mdl.n, mdl.y0, mdl.y1));
    bfm.read(8'h38, v);
    check(v == 32'h000F_0008, $sformatf("RUN reads %h", v));
    colour_regs(0, 16'hFF00, 16'hFF00, 16'hFF00, 0);
    $display("[%0t] test_run_band: runs judged at their end against MIN_W / MAX_W by their whole length", $time);
  endtask

  task automatic test_scratch();
    logic [31:0] v;
    for (int i = 0; i < 28; i++) bfm.write(8'(8'h50 + 4 * i), 32'hC0DE_0000 + 32'(i * 17));
    for (int i = 0; i < 28; i++) begin
      bfm.read(8'(8'h50 + 4 * i), v);
      check(v == 32'hC0DE_0000 + 32'(i * 17), $sformatf("SCRATCH[%0d] reads %h", i, v));
    end
    $display("[%0t] test_scratch: 28 scratch words read back", $time);
  endtask

  task automatic blob_cfg(input int gap, input int keep, input int gap_y = -1);
    e_blob = (keep << 16) | (((gap_y < 0) ? gap : gap_y) << 8) | gap;
    bfm.write(8'h4C, e_blob);
  endtask
  task automatic dark_rect(input int x0, input int y0, input int x1, input int y1);
    for (int y = y0; y <= y1; y++) for (int x = x0; x <= x1; x++) vid.img[y][x] = {3{8'd30}};
  endtask
  task automatic test_blobs();
    logic [31:0] v;
    bfm.read(8'h4C, v);
    check(v == 32'h0000_0202, $sformatf("BLOB_CFG reset %h", v));
    configure(1, 1, 2, 80, 0, 0, W - 1, H - 1);
    scene(200, 200, 0, 0, -1, -1, 0, 0);
    dark_rect(2, 2, 9, 12);                                      // three objects
    dark_rect(20, 4, 27, 8);
    dark_rect(34, 20, 45, 33);
    dark_rect(14, 30, 15, 30);                                   // a 2-pixel speck
    blob_cfg(2, 8);
    run_frame("blobs: three objects, a speck");
    check(mdl.bn[0] == 88 && mdl.bn[1] == 40 && mdl.bn[2] == 168 && mdl.bn[3] == 0,
          $sformatf("model: blobs %0d %0d %0d %0d", mdl.bn[0], mdl.bn[1], mdl.bn[2], mdl.bn[3]));
    // a U shape: two arms first seen as two blobs, joined by the bottom bar
    scene(200, 200, 0, 0, -1, -1, 0, 0);
    dark_rect(4, 4, 6, 20);
    dark_rect(16, 4, 18, 20);
    dark_rect(4, 21, 18, 23);
    run_frame("blobs: U shape joined");
    check(mdl.bn[0] == 3 * 17 * 2 + 15 * 3 && mdl.bx0[0] == 4 && mdl.bx1[0] == 18 && mdl.by0[0] == 4 && mdl.by1[0] == 23,
          $sformatf("model: U blob %0d pixels", mdl.bn[0]));
    // GAP 0: objects 1 column apart stay separate; GAP 2 joins them
    scene(200, 200, 0, 0, -1, -1, 0, 0);
    dark_rect(4, 4, 10, 10);
    dark_rect(12, 4, 18, 10);
    blob_cfg(0, 0);
    run_frame("blobs: GAP 0");
    check(mdl.bn[0] == 49 && mdl.bn[1] == 49, $sformatf("model: GAP 0 keeps two blobs: %0d %0d %0d %0d", mdl.bn[0], mdl.bn[1], mdl.bn[2], mdl.bn[3]));
    blob_cfg(2, 0);
    run_frame("blobs: GAP 2");
    check(mdl.bn[0] == 98 && mdl.bn[1] == 0, "model: GAP 2 joins them");
    // GAP_Y: a roof and a body 6 lines apart (the windows) join with GAP_Y 6, not with GAP_Y 2
    scene(200, 200, 0, 0, -1, -1, 0, 0);
    dark_rect(10, 4, 30, 6);
    dark_rect(4, 13, 36, 20);
    blob_cfg(2, 0, 2);
    run_frame("blobs: GAP_Y 2, roof and body apart");
    check(mdl.bn[0] == 63 && mdl.bn[1] == 264, "model: GAP_Y 2 keeps the roof apart");
    blob_cfg(2, 0, 6);
    run_frame("blobs: GAP_Y 6, roof and body one object");
    check(mdl.bn[0] == 327 && mdl.bn[1] == 0, "model: GAP_Y 6 joins roof and body");
    // ten objects in the first lines take every slot (KEEP 0): the rest is lost
    scene(200, 200, 0, 0, -1, -1, 0, 0);
    for (int k = 0; k < 10; k++) dark_rect(1 + 5 * k, 2, 3 + 5 * k, 6);
    run_frame("blobs: more objects than slots");
    check(mdl.blost > 0, "model: BLOB_LOST counts the runs not grouped");
    // KEEP frees the slots of closed specks: a later object still gets one
    scene(200, 200, 0, 0, -1, -1, 0, 0);
    for (int k = 0; k < 8; k++) dark_rect(2 + 5 * k, 1, 3 + 5 * k, 1);   // 8 specks fill every slot
    dark_rect(10, 20, 30, 30);
    blob_cfg(1, 10);
    run_frame("blobs: specks dropped, slot reused");
    check(mdl.bn[0] + mdl.bn[1] + mdl.bn[2] + mdl.bn[3] + mdl.bn[4] + mdl.bn[5] + mdl.bn[6] + mdl.bn[7] == 21 * 11 &&
          mdl.blost == 0, $sformatf("model: the object blob kept: %0d %0d %0d %0d lost %0d", mdl.bn[0], mdl.bn[1], mdl.bn[2], mdl.bn[3], mdl.blost));
    stall_pct = 20;
    vid.gap_pct = 10;
    for (int f = 0; f < 12; f++) begin
      scene(200, 200, 0, 0, -1, -1, 4, 0);
      for (int k = 0; k < 1 + $urandom_range(10); k++) begin
        int a, b;
        a = $urandom_range(W - 2);
        b = $urandom_range(H - 2);
        dark_rect(a, b, a + $urandom_range(W - 1 - a) / 2, b + $urandom_range(H - 1 - b) / 2);
      end
      blob_cfg($urandom_range(4), $urandom_range(30), $urandom_range(6));
      if ($urandom_range(1)) configure(1, 1, $urandom_range(3), 80, $urandom_range(10), $urandom_range(8),
                                       W - 1 - $urandom_range(10), H - 1 - $urandom_range(8));
      else configure(1, 1, $urandom_range(3), 80, 0, 0, W - 1, H - 1);
      run_frame($sformatf("blobs: random frame %0d", f));
    end
    stall_pct = 0;
    vid.gap_pct = 0;
    blob_cfg(2, 0);
    configure(1, 1, 2, 80, 0, 0, W - 1, H - 1);
    $display("[%0t] test_blobs: separate objects, small ones dropped, U joined, GAP, BLOB_LOST, random", $time);
  endtask

  task automatic test_random_colour();
    stall_pct = 25;
    vid.gap_pct = 15;
    for (int f = 0; f < 16; f++) begin
      int a, b;
      for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
        vid.img[y][x] = {8'($urandom_range(255)), 8'($urandom_range(255)), 8'($urandom_range(255))};
      for (int k = 0; k < 3; k++) begin
        logic [23:0] c;
        c = {8'($urandom_range(255)), 8'($urandom_range(255)), 8'($urandom_range(255))};
        a = $urandom_range(W - 1);
        b = $urandom_range(H - 1);
        colour_patch(c, a, b, a + $urandom_range(W - 1 - a), b + $urandom_range(H - 1 - b));
      end
      a = $urandom_range(W / 2);
      b = $urandom_range(H / 2);
      configure(1, 0, $urandom_range(4), 0, a, b, a + $urandom_range(W), b + $urandom_range(H));
      e_ctrl = 32'h5 | ($urandom_range(4) << 8);
      bfm.write(8'h08, e_ctrl);
      begin
        int l0, l1, c0, c1, r0, r1;
        l0 = $urandom_range(150);
        l1 = l0 + $urandom_range(255 - l0);
        c0 = 60 + $urandom_range(60);
        c1 = c0 + $urandom_range(255 - c0);
        r0 = 60 + $urandom_range(60);
        r1 = r0 + $urandom_range(255 - r0);
        colour_regs(($urandom_range(1) ? (32'($urandom_range(3, 20)) << 16) : 0) | $urandom_range(4),
                    (l1 << 8) | l0, (c1 << 8) | c0, (r1 << 8) | r0, $urandom_range(60));
      end
      run_frame($sformatf("random colour frame %0d", f));
    end
    colour_regs(0, 16'hFF00, 16'hFF00, 16'hFF00, 0);
    stall_pct = 0;
    vid.gap_pct = 0;
    $display("[%0t] test_random_colour: 16 random colour scenes and settings with stalls", $time);
  endtask

  task automatic write_ctrl(input int v);
    e_ctrl = v;
    bfm.write(8'h08, v);
  endtask
  // two terms: feat_i from the pixel's LSBs (edge = B[0], motion = G[0])
  task automatic feat_pixel(input int x, input int y, input bit e, input bit m);
    vid.img[y][x][16] = e;
    vid.img[y][x][8] = m;
  endtask
  task automatic test_terms();
    logic [31:0] v;
    feat_on = 1;
    configure(1, 1, 2, 80, 0, 0, W - 1, H - 1);
    blob_cfg(2, 0);
    // a dark square (term A, luma), a moving square of light pixels (motion) and an edge outline (term B)
    scene(200, 200, 0, 0, -1, -1, 0, 0);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) feat_pixel(x, y, 0, 0);
    dark_rect(4, 4, 11, 11);
    for (int y = 20; y < 28; y++) for (int x = 4; x < 12; x++) feat_pixel(x, y, 0, 1);
    for (int x = 24; x < 44; x++) begin
      feat_pixel(x, 6, 1, 0);
      feat_pixel(x, 18, 1, 0);
    end
    for (int y = 6; y < 19; y++) begin
      feat_pixel(24, y, 1, 0);
      feat_pixel(25, y, 1, 0);
      feat_pixel(42, y, 1, 0);
      feat_pixel(43, y, 1, 0);
    end
    for (int fa = 0; fa < 4; fa++) begin
      write_ctrl(3 | (2 << 8) | (fa << 12));
      run_frame($sformatf("FEAT_A %0d", fa));
    end
    check(mdl.n == 64, $sformatf("model: FEAT_A 3 (motion only) kept %0d pixels", mdl.n));
    e_runb = 32'h0000_0002;                            // edges in runs of 2+
    bfm.write(9'h0C0, e_runb);
    bfm.read(9'h0C0, v);
    check(v == e_runb, $sformatf("RUN_B reads %h", v));
    write_ctrl(3 | (2 << 8) | (1 << 12) | (1 << 14));   // dark or moving, and edges (term B)
    run_frame("FEAT_A 1 + TERM_B");
    check(mdl.bn[0] > 0 && mdl.bn[1] > 0 && mdl.bn[4] > 0, $sformatf("model: terms A (2 blobs) and B (1 blob): %0d %0d %0d",
                                                                       mdl.bn[0], mdl.bn[1], mdl.bn[4]));
    e_runb = 32'h0004_0002;                            // edge runs of 2-4: the long top / bottom lines dropped
    bfm.write(9'h0C0, e_runb);
    run_frame("TERM_B band 2-4");
    // random features, settings and windows with stalls
    stall_pct = 20;
    vid.gap_pct = 10;
    for (int f = 0; f < 16; f++) begin
      for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
        logic [7:0] g;
        g = 8'($urandom_range(255));
        vid.img[y][x] = {8'($urandom_range(255)), g, 8'($urandom_range(255))};
      end
      for (int k = 0; k < 3; k++) begin                 // feature patches
        int a, b, c, d;
        a = $urandom_range(W - 1);
        b = $urandom_range(H - 1);
        c = a + $urandom_range(W - 1 - a);
        d = b + $urandom_range(H - 1 - b);
        for (int y = b; y <= d; y++) for (int x = a; x <= c; x++) feat_pixel(x, y, $urandom_range(3) != 0, $urandom_range(1));
      end
      e_runb = (($urandom_range(1) ? $urandom_range(3, 30) : 0) << 16) | $urandom_range(4);
      bfm.write(9'h0C0, e_runb);
      blob_cfg($urandom_range(3), $urandom_range(20), $urandom_range(4));
      configure(1, $urandom_range(1), $urandom_range(3), $urandom_range(255), $urandom_range(8), $urandom_range(8),
                W - 1 - $urandom_range(8), H - 1 - $urandom_range(8));
      write_ctrl(1 | ($urandom_range(1) << 1) | ($urandom_range(1) << 2) | ($urandom_range(3) << 8) |
                 ($urandom_range(3) << 12) | ($urandom_range(1) << 14));
      run_frame($sformatf("terms: random frame %0d", f));
    end
    stall_pct = 0;
    vid.gap_pct = 0;
    feat_on = 0;
    e_runb = 0;
    bfm.write(9'h0C0, 0);
    write_ctrl(0);
    $display("[%0t] test_terms: FEAT_A 0-3, TERM_B with RUN_B, separate blob slots, random features", $time);
  endtask

