// ***************
// Filename: symbol_overlay_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the symbol_overlay_tb testbench
//   (symbol_overlay_tb.sv), `included into that module, so they use its
//   signals directly. Tasks, in file order:
//     check            Counts an error and prints the message when the
//                      condition is false
//     set_obj          Writes object i's four registers (and the expected
//                      written state)
//     commit           Writes COMMIT: the written objects apply from the
//                      next frame start
//     new_image        A new input image (gradient with noise) in the BFM
//     run_frame        Sends one frame, waits for it at the output and
//                      compares it with the model of the active objects
//     test_id_block        ID "SOVL", VERSION ("d.dd") and DATE (BCD
//                          mm/dd/yyyy) at the base address, read only
//                          (SLVERR); the rest of the map from 0x10
//     test_registers   reset CTRL / COMMIT / STATUS,
//                      object registers read back
//     test_passthrough CTRL.ENABLE = 0: the output equals the input, one
//                      clock of latency, STATUS counts the frames
//     test_shapes      Outline, filled, crosshair and circle, solid and dashed
//                      (dash lengths 1 to 8), widths 1 to 4, colour and 50 %
//                      blend, each against the model
//     test_priority    Four overlapping objects: object 0 on top
//     test_commit      Written objects do not apply until COMMIT; COMMIT
//                      applies at the next frame start (STATUS[0] pending
//                      meanwhile); a COMMIT in the middle of a frame does not
//                      change that frame; CTRL.ENABLE is taken at the frame
//                      start
//     test_edges       Boxes reaching beyond the right / bottom edge, a box
//                      with x0 > x1 (nothing drawn), the frame corners
//     test_random      20 frames of random objects with random input gaps
//                      and output back-pressure
//     set_text         Writes text j's registers and characters (and the
//                      expected written state)
//     test_text        Every scale (1x, 2x, 4x) with and without backdrop,
//                      lengths 0 and 16, lowercase (drawn as capitals),
//                      every printable character, text over an object,
//                      text clipped at the right and bottom edges, the
//                      registers read back
//     test_text_commit Text written without COMMIT does not change the
//                      frame; a COMMIT in the middle of a frame applies from
//                      the next one
//     test_text_random 12 frames of random texts over random objects with
//                      gaps and back-pressure
//     test_circle      Shape 3 circles, solid and dashed: square, wide and
//                      tall boxes (radius = half the larger side), a line
//                      wider than the radius (filled disc), circles cut by
//                      the frame edges, a one-pixel box; the same boxes as
//                      ovals (CTRL[5]: ellipse inside the box)
//     test_frame_number FRAME_NUM sets the number the next frame shows; texts
//                      with CTRL[4] show it after their characters, one more
//                      each frame (carries 9 -> 10, 99 -> 100, 99999 -> 0);
//                      a FRAME_NUM write in the middle of a frame applies
//                      from the next one
// Date: 2026-10-13
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      if (errors < 20) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  // ctrl: [0] en [2:1] shape [3] dashed [4] blend [11:8] width [14:12] dash log2; colour {B, G, R}
  task automatic set_obj(input int i, input logic [31:0] ctrl, input int x0, input int x1, input int y0,
                         input int y1, input logic [23:0] col);
    bfm.write(10'h40 + 16 * i, ctrl);
    bfm.write(10'h44 + 16 * i, (x1 << 16) | (x0 & 16'hFFFF));
    bfm.write(10'h48 + 16 * i, (y1 << 16) | (y0 & 16'hFFFF));
    bfm.write(10'h4C + 16 * i, col);
    w_obj[i] = {8'd0, col, 16'(y1), 16'(y0), 16'(x1), 16'(x0), ctrl};
  endtask

  task automatic commit();
    bfm.write(10'h0C, 1);
    pending = 1;
  endtask

  task automatic set_enable(input bit en);
    bfm.write(10'h08, en);
    w_en = en;
  endtask

  task automatic new_image();
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
      vid.img[y][x] = {8'(4 * y + $urandom_range(7)), 8'(3 * x + 2 * y), 8'(6 * x + $urandom_range(7))};
  endtask

  // one frame: the objects committed before it apply to it
  task automatic run_frame(input string name);
    int f0, bad;
    a_fnum = fnum_pend ? set_fnum : (a_fnum + 1) % 100000;   // the frame number this frame shows
    fnum_pend = 0;
    if (pending) begin
      for (int i = 0; i < NOBJ; i++) a_obj[i] = w_obj[i];
      for (int j = 0; j < NTXT; j++) begin
        a_txt[j] = w_txt[j];
        a_chr[j] = w_chr[j];
      end
      pending = 0;
    end
    f0 = vid.frames;
    vid.send(W, H);
    while (vid.frames == f0) @(posedge clk);
    mdl.w = W;
    mdl.h = H;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) mdl.img[y][x] = vid.img[y][x];
    for (int i = 0; i < NOBJ; i++) mdl.obj[i] = a_obj[i];
    mdl.ntxt = NTXT;
    mdl.fnum = a_fnum;
    for (int j = 0; j < NTXT; j++) begin
      mdl.txt[j] = a_txt[j];
      mdl.chr[j] = a_chr[j];
    end
    mdl.draw(w_en);
    bad = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
      if (vid.out[y][x] !== mdl.out[y][x]) begin
        if (bad < 3) $display("  %s: (%0d,%0d) %h, model %h", name, x, y, vid.out[y][x], mdl.out[y][x]);
        bad++;
      end
    check(bad == 0, $sformatf("%s: %0d pixels differ from the model", name, bad));
  endtask

  task automatic test_registers();
    logic [31:0] v;
    bfm.read(10'h08, v);
    check(v == 0, $sformatf("reset CTRL %h", v));
    bfm.read(10'h10, v);
    check(v == 0, $sformatf("reset STATUS %h", v));
    set_obj(2, 32'h7F1F, 3, 33, 4, 25, 24'h123456);
    for (int r = 0; r < 4; r++) begin
      bfm.read(10'h60 + 4 * r, v);
      check(v == w_obj[2][32*r +: 32], $sformatf("OBJ2 register %0d reads %h, wrote %h", r, v, w_obj[2][32*r +: 32]));
    end
    set_obj(2, 0, 0, 0, 0, 0, 0);
    $display("[%0t] test_registers: reset values, object registers read back", $time);
  endtask

  task automatic test_passthrough();
    logic [31:0] v;
    new_image();
    run_frame("pass-through, overlay disabled");
    check(vid.out_sof_t - vid.in_sof_t == 10ns, $sformatf("latency %0t, expected one clock", vid.out_sof_t - vid.in_sof_t));
    bfm.read(10'h10, v);
    check(v[31:16] == 1, $sformatf("STATUS frames %0d after one frame", v[31:16]));
    $display("[%0t] test_passthrough: disabled overlay passes the video unchanged, latency one clock", $time);
  endtask

  task automatic test_shapes();
    int n = 0;
    set_enable(1);
    for (int shape = 0; shape < 4; shape++)
      for (int dashed = 0; dashed < 2; dashed++)
        for (int w = 1; w <= 4; w += 3)
          for (int blend = 0; blend < 2; blend++) begin
            logic [31:0] c;
            c = 1 | (shape << 1) | (dashed << 3) | (blend << 4) | (w << 8) | (((n % 4)) << 12);
            set_obj(0, c, 5 + n % 3, 30 - n % 4, 4 + n % 2, 22 + n % 3, 24'h00FF00 ^ (n << 3));
            commit();
            new_image();
            run_frame($sformatf("shape %0d dashed %0d width %0d blend %0d dash %0d", shape, dashed, w, blend, 1 << (n % 4)));
            n++;
          end
    set_obj(0, 0, 0, 0, 0, 0, 0);
    commit();
    $display("[%0t] test_shapes: %0d shape / dash / width / blend combinations match the model", $time, n);
  endtask

  task automatic test_priority();
    set_obj(0, 32'h0301, 8, 28, 6, 20, 24'h0000FF);       // outline, width 3
    set_obj(1, 32'h0003, 10, 30, 8, 24, 24'h00FF00);      // filled
    set_obj(2, 32'h0215, 0, 39, 0, 29, 24'hFF0000);       // crosshair, blend
    set_obj(3, 32'h1009, 2, 37, 2, 27, 24'hFFFFFF);       // dashed outline
    commit();
    new_image();
    run_frame("four overlapping objects");
    $display("[%0t] test_priority: object 0 drawn on top of objects 1-3", $time);
  endtask

  task automatic test_commit();
    logic [31:0] v;
    // written but not committed: the frame keeps the previous objects
    set_obj(0, 32'h0101, 1, 20, 1, 20, 24'hABCDEF);
    new_image();
    run_frame("objects written, no COMMIT");
    commit();
    bfm.read(10'h10, v);
    check(v[0], "STATUS[0] (commit pending) not set after COMMIT");
    new_image();
    run_frame("after COMMIT");
    bfm.read(10'h10, v);
    check(!v[0], "STATUS[0] still set after the frame start");
    // COMMIT in the middle of a frame: applies from the next frame
    set_obj(1, 32'h1209, 4, 35, 3, 26, 24'h00FFFF);
    new_image();
    fork
      run_frame("COMMIT in the middle of this frame");
      begin
        while (!(vid.oy == H / 2)) @(posedge clk);
        bfm.write(10'h0C, 1);
      end
    join
    pending = 1;
    new_image();
    run_frame("frame after the mid-frame COMMIT");
    // CTRL.ENABLE written during a frame: taken at the next frame start
    new_image();
    fork
      run_frame("ENABLE cleared in the middle of this frame");
      begin
        while (!(vid.oy == H / 2)) @(posedge clk);
        bfm.write(10'h08, 0);
      end
    join
    w_en = 0;
    new_image();
    run_frame("frame after ENABLE cleared");
    set_enable(1);
    $display("[%0t] test_commit: objects apply only after COMMIT, at the next frame start", $time);
  endtask

  task automatic test_edges();
    for (int i = 1; i < NOBJ; i++) set_obj(i, 0, 0, 0, 0, 0, 0);
    set_obj(0, 32'h0201, 30, 200, 20, 300, 24'h8080FF);     // beyond the right and bottom edges
    commit();
    new_image();
    run_frame("box beyond the frame edges");
    set_obj(0, 32'h0003, 30, 10, 5, 20, 24'hFFFFFF);        // x0 > x1: nothing
    set_obj(1, 32'h0001, 0, W - 1, 0, H - 1, 24'h000000);   // the whole frame outline
    commit();
    new_image();
    run_frame("x0 > x1 and the frame outline");
    $display("[%0t] test_edges: clipped boxes, empty box, frame-size outline", $time);
  endtask

  task automatic test_random();
    vid.gap_pct = 30;
    vid.bp_pct = 40;
    for (int f = 0; f < 20; f++) begin
      for (int i = 0; i < NOBJ; i++) begin
        int a, b, c, d;
        a = $urandom_range(W + 4);
        b = a + $urandom_range(W);
        c = $urandom_range(H + 4);
        d = c + $urandom_range(H);
        set_obj(i, $urandom_range(1) | ($urandom_range(3) << 1) | ($urandom_range(1) << 3) | ($urandom_range(1) << 4) |
                ($urandom_range(15) << 8) | ($urandom_range(7) << 12), a, b, c, d, $urandom);
      end
      if (f % 4 != 3) commit();                             // every fourth frame keeps the old objects
      new_image();
      run_frame($sformatf("random frame %0d", f));
    end
    vid.gap_pct = 0;
    vid.bp_pct = 0;
    $display("[%0t] test_random: 20 frames of random objects with gaps and back-pressure", $time);
  endtask

  // text j: ctrl [0] en [2:1] scale log2 [3] backdrop [12:8] length; the string's first 16 characters
  task automatic set_text(input int j, input logic [31:0] ctrl, input int x, input int y, input logic [23:0] col,
                          input string str);
    logic [127:0] c;
    c = '0;
    for (int k = 0; k < 16 && k < str.len(); k++) c[8*k +: 8] = str[k];
    bfm.write(10'h100 + 16 * j, ctrl);
    bfm.write(10'h104 + 16 * j, (y << 16) | (x & 16'hFFFF));
    bfm.write(10'h108 + 16 * j, col);
    for (int q = 0; q < 4; q++) bfm.write(10'h200 + 16 * j + 4 * q, c[32*q +: 32]);
    w_txt[j] = {8'd0, col, 16'(y), 16'(x), ctrl};
    w_chr[j] = c;
  endtask

  function automatic logic [31:0] tctrl(input int en, input int scale, input int bd, input int len);
    return en | (scale << 1) | (bd << 3) | (len << 8);
  endfunction

  task automatic test_text();
    logic [31:0] v;
    string all;
    set_enable(1);
    for (int i = 0; i < NOBJ; i++) set_obj(i, 0, 0, 0, 0, 0, 0);
    for (int sc = 0; sc < 3; sc++) for (int bd = 0; bd < 2; bd++) begin
      set_text(0, tctrl(1, sc, bd, 9), 1 + sc, 2 + bd, 24'hFFFFFF, "AB:12.z_9");
      set_text(1, tctrl(1, 0, 1 - bd, 6), W - 25, H - 7, 24'h00FFFF, "Frame7");
      commit();
      new_image();
      run_frame($sformatf("text scale %0d backdrop %0d", 1 << sc, bd));
      begin                                            // the text is really there (not only equal to the model)
        int n;
        n = 0;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) if (vid.out[y][x] == 24'hFFFFFF) n++;
        check(n >= 20 * (1 << (2 * sc)), $sformatf("only %0d text pixels drawn at scale %0d", n, 1 << sc));
        if (sc == 1 && bd == 1) begin                  // a picture of it: build/sim/symbol_overlay/text_x2.ppm
          int fd;
          fd = $fopen("text_x2.ppm", "w");
          $fwrite(fd, "P3\n%0d %0d\n255\n", W, H);
          for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
            $fwrite(fd, "%0d %0d %0d\n", vid.out[y][x][7:0], vid.out[y][x][15:8], vid.out[y][x][23:16]);
          $fclose(fd);
        end
      end
    end
    set_obj(0, 32'h0003, 0, 39, 0, 29, 24'h303030);        // filled box under the texts
    set_text(0, tctrl(1, 0, 0, 16), 0, 0, 24'h0000FF, "0123456789ABCDEF");   // length 16
    set_text(1, tctrl(1, 0, 0, 0), 5, 10, 24'h00FF00, "HIDDEN");             // length 0: nothing
    set_text(2, tctrl(1, 1, 1, 8), 30, 20, 24'hFF0000, "CLIPPED!");          // past both edges
    set_text(3, tctrl(0, 0, 0, 4), 2, 12, 24'hFFFFFF, "OFF");                // disabled
    commit();
    new_image();
    run_frame("text over an object, length 16 and 0, clipped, disabled");
    // every printable character (5 frames of 16 + 15)
    all = "";
    for (int c = 32; c < 127; c++) all = $sformatf("%s%c", all, c);
    for (int f = 0; f < 6; f++) begin
      set_text(0, tctrl(1, 0, 1, 16), 1, 1, 24'hFFFF00, all.substr(16 * f, (16 * f + 15 < all.len()) ? 16 * f + 15 : all.len() - 1));
      commit();
      new_image();
      run_frame($sformatf("printable characters %0d-%0d", 32 + 16 * f, 47 + 16 * f));
    end
    for (int r = 0; r < 3; r++) begin
      bfm.read(10'h100 + 4 * r, v);
      check(v == w_txt[0][32*r +: 32], $sformatf("TXT0 register %0d reads %h, wrote %h", r, v, w_txt[0][32*r +: 32]));
    end
    for (int q = 0; q < 4; q++) begin
      bfm.read(10'h200 + 4 * q, v);
      check(v == w_chr[0][32*q +: 32], $sformatf("TXT0 characters word %0d reads %h", q, v));
    end
    $display("[%0t] test_text: scales, backdrop, lengths, every printable character, clipping, priority", $time);
  endtask

  task automatic test_text_commit();
    set_text(0, tctrl(1, 0, 0, 5), 2, 2, 24'hFFFFFF, "FIRST");
    commit();
    new_image();
    run_frame("text before the change");
    set_text(0, tctrl(1, 0, 0, 6), 2, 2, 24'hFFFFFF, "SECOND");
    new_image();
    run_frame("text written, no COMMIT");
    new_image();
    fork
      run_frame("text COMMIT in the middle of this frame");
      begin
        while (!(vid.oy == H / 2)) @(posedge clk);
        bfm.write(10'h0C, 1);
      end
    join
    pending = 1;
    new_image();
    run_frame("frame after the text COMMIT");
    $display("[%0t] test_text_commit: text applies only after COMMIT, at the next frame start", $time);
  endtask

  task automatic test_text_random();
    vid.gap_pct = 30;
    vid.bp_pct = 40;
    for (int f = 0; f < 12; f++) begin
      for (int i = 0; i < NOBJ; i++)
        set_obj(i, $urandom_range(1) | ($urandom_range(3) << 1) | ($urandom_range(1) << 3) | ($urandom_range(3) << 8),
                $urandom_range(W), $urandom_range(W) + 5, $urandom_range(H), $urandom_range(H) + 5, $urandom);
      for (int j = 0; j < NTXT; j++) begin
        string str;
        str = "";
        for (int k = 0; k < 16; k++) str = $sformatf("%s%c", str, 32 + $urandom_range(94));
        set_text(j, tctrl($urandom_range(1), $urandom_range(3), $urandom_range(1), $urandom_range(17)),
                 $urandom_range(W), $urandom_range(H), $urandom, str);
      end
      commit();
      new_image();
      run_frame($sformatf("random texts, frame %0d", f));
    end
    vid.gap_pct = 0;
    vid.bp_pct = 0;
    $display("[%0t] test_text_random: 12 frames of random texts and objects with gaps and back-pressure", $time);
  endtask

  function automatic logic [19:0] to_bcd(input int v);
    logic [19:0] b;
    for (int d = 0; d < 5; d++) begin
      b[4*d +: 4] = 4'(v % 10);
      v = v / 10;
    end
    return b;
  endfunction

  task automatic set_frame_number(input int v);
    bfm.write(10'h014, to_bcd(v));
    set_fnum = v;
    fnum_pend = 1;
  endtask

  task automatic test_frame_number();
    logic [31:0] v;
    int starts [4] = '{1, 8, 98, 99998};
    for (int i = 0; i < NOBJ; i++) set_obj(i, 0, 0, 0, 0, 0, 0);
    set_text(0, tctrl(1, 0, 1, 13), 1, H - 7, 24'hFFFFFF, "frame number ");
    set_text(1, tctrl(1, 1, 0, 0) | 16, 2, 2, 24'h00FF00, "");                 // the number alone, 2x
    set_text(2, tctrl(0, 0, 0, 0), 0, 0, 0, "");
    set_text(3, tctrl(1, 0, 0, 2) | 16, W - 30, 10, 24'hFF00FF, "#:");
    commit();
    foreach (starts[s]) begin
      set_frame_number(starts[s]);
      for (int f = 0; f < 3; f++) begin
        new_image();
        run_frame($sformatf("frame number %0d", a_fnum + (fnum_pend ? 0 : 1)));
      end
      bfm.read(10'h014, v);
      check(v[19:0] == to_bcd(a_fnum), $sformatf("FRAME_NUM reads %h, frame showed %0d", v[19:0], a_fnum));
    end
    new_image();                                       // FRAME_NUM written in the middle of a frame: the next one shows it
    fork
      run_frame("FRAME_NUM written in the middle of this frame");
      begin
        while (!(vid.oy == H / 2)) @(posedge clk);
        bfm.write(10'h014, to_bcd(500));
      end
    join
    set_fnum = 500;
    fnum_pend = 1;
    new_image();
    run_frame("frame after the FRAME_NUM write");
    check(a_fnum == 500, "model: frame number 500 not shown");
    $display("[%0t] test_frame_number: frame number after the text, counts on, carries, set by FRAME_NUM", $time);
  endtask

  // ID block at the base address: ID, VERSION (ASCII "d.dd"), DATE (BCD mm/dd/yyyy), 0x0C reserved;
  // read only (writes ignored); the rest of the map starts at 0x10 (bfm.base)
  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    bfm.read_abs(10'h0, id);
    bfm.read_abs(10'h4, ver);
    bfm.read_abs(10'h8, date);
    bfm.read_abs(10'hC, rsv);
    check(id == "SOVL", $sformatf("ID %h (\"%s\"), expected \"SOVL\"", id, id));
    check(ver == dut.u_regs.IP_VERSION && ver[31:24] >= "0" && ver[31:24] <= "9" && ver[23:16] == "." &&
          ver[15:8] >= "0" && ver[15:8] <= "9" && ver[7:0] >= "0" && ver[7:0] <= "9",
          $sformatf("VERSION %h (\"%s\"), expected \"d.dd\" = \"%s\"", ver, ver, dut.u_regs.IP_VERSION));
    check(date == dut.u_regs.IP_DATE && date[31:28] <= 1 && date[27:24] <= 9 && date[31:24] >= 8'h01 && date[31:24] <= 8'h12 &&
          date[23:16] >= 8'h01 && date[23:16] <= 8'h31 && date[19:16] <= 9 && date[15:0] >= 16'h2000 &&
          date[15:12] <= 9 && date[11:8] <= 9 && date[7:4] <= 9 && date[3:0] <= 9,
          $sformatf("DATE %h, expected a BCD mm/dd/yyyy date = %h", date, dut.u_regs.IP_DATE));
    check(rsv == 0, $sformatf("0x0C reads %h, expected 0", rsv));
    for (int a = 0; a < 16; a += 4) begin               // ID / VERSION / DATE: SLVERR, reserved: OKAY
      bfm.write_abs(10'(a), 32'hA5A5_5A5A);
      check(bfm.last_resp == ((a < 12) ? 2'b10 : 2'b00), $sformatf("write to 0x%0h answered %b", a, bfm.last_resp));
    end
    bfm.resp_errors = 0;
    bfm.read_abs(10'h0, v);
    check(v == id, "ID changed by a write");
    bfm.read_abs(10'h4, v);
    check(v == ver, "VERSION changed by a write");
    bfm.read_abs(10'h8, v);
    check(v == date, "DATE changed by a write");
    $display("[%0t] test_id_block: ID \"%s\", VERSION \"%s\", DATE %0h/%0h/%0h", $time, id, ver, date[31:24],
             date[23:16], date[15:0]);
  endtask

  task automatic test_circle();
    int n = 0;
    // {x0, x1, y0, y1, line width}: square, wide, tall, width > radius, cut by the left / top and the
    // right / bottom edges, a one-pixel box
    int bx [7][5] = '{'{8, 28, 5, 25, 1}, '{4, 36, 10, 20, 2}, '{15, 25, 2, 28, 1}, '{14, 22, 10, 18, 9},
                      '{0, 14, 0, 10, 1}, '{25, 50, 18, 40, 3}, '{20, 20, 15, 15, 1}};
    set_enable(1);
    for (int oval = 0; oval < 2; oval++)
    for (int b = 0; b < 7; b++)
      for (int dashed = 0; dashed < 2; dashed++) begin
        logic [31:0] c;
        c = 1 | (3 << 1) | (dashed << 3) | (bx[b][4] << 8) | ((b % 3) << 12) | ((b == 3) << 4) | (oval << 5);
        set_obj(0, c, bx[b][0], bx[b][1], bx[b][2], bx[b][3], 24'hFF00FF);
        commit();
        new_image();
        run_frame($sformatf("%s box x %0d-%0d y %0d-%0d width %0d dashed %0d", oval ? "oval" : "circle", bx[b][0], bx[b][1],
                            bx[b][2], bx[b][3], bx[b][4], dashed));
        n++;
      end
    set_obj(0, 0, 0, 0, 0, 0, 0);
    commit();
    $display("[%0t] test_circle: %0d circles and ovals (solid / dashed, square / wide / tall boxes, edges) match the model", $time, n);
  endtask
