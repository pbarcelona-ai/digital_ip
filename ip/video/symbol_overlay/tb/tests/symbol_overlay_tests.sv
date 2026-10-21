// ***************
// Filename: symbol_overlay_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the symbol_overlay_tb testbench
//   (symbol_overlay_tb.sv), `included into that module, so they use its
//   signals directly. The structural checks of the block; every pixel of
//   every symbol, label and text is compared with the golden model by the
//   cocotb test (tb/python/symbol_overlay_tb.py). Tasks, in file order:
//     check             Counts an error and prints the message when the
//                       condition is false
//     set_obj           Writes object i's registers (first bank)
//     commit            Writes COMMIT
//     new_image         A new input image (gradient with noise) in the BFM
//     run_frame         Sends one frame and waits for it at the output
//     check_box         Compares the output frame with the input and one
//                       filled box (or none) drawn over it
//     test_id_block     ID "SOVL", VERSION ("d.dd") and DATE (BCD
//                       mm/dd/yyyy) at the base address, read only
//                       (SLVERR); the rest of the map from 0x10
//     test_registers    Reset CTRL / STATUS / FRAME_NUM; object, label and
//                       text registers read back
//     test_passthrough  CTRL.ENABLE = 0: the output equals the input with
//                       gaps and back-pressure; STATUS counts the frames
//     test_commit       A filled box written without COMMIT does not apply;
//                       COMMIT applies at the next frame start (STATUS[0]
//                       pending meanwhile); a COMMIT in the middle of a frame
//                       applies from the next one; CTRL.ENABLE is taken at
//                       every frame start
//     test_frame_number FRAME_NUM reads the current frame's number: one more
//                       each frame (carries), a write sets the next frame's
//     bcd_next          The next BCD frame number
// Date: 2026-10-20
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      if (errors < 20) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  // ctrl: [0] en [2:1] shape [3] dashed [4] blend ...; colour {B, G, R}; register offsets after bfm.base
  task automatic set_obj(input int i, input logic [31:0] ctrl, input int x0, input int x1, input int y0,
                         input int y1, input logic [23:0] col, input logic [31:0] lab);
    bfm.write(10'h40 + 10'(16 * i), ctrl);
    bfm.write(10'h44 + 10'(16 * i), (x1 << 16) | (x0 & 16'hFFFF));
    bfm.write(10'h48 + 10'(16 * i), (y1 << 16) | (y0 & 16'hFFFF));
    bfm.write(10'h4C + 10'(16 * i), col);
    bfm.write(10'h250 + 10'(4 * i), lab);
  endtask

  task automatic commit();
    bfm.write(10'h0C, 1);
  endtask

  task automatic new_image();
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
      vid.img[y][x] = {8'(4 * y + $urandom_range(7)), 8'(3 * x + 2 * y), 8'(6 * x + $urandom_range(7))};
  endtask

  task automatic run_frame();
    int f0;
    f0 = vid.frames;
    vid.send(W, H);
    while (vid.frames == f0) @(posedge clk);
  endtask

  // the output: the input, with a filled box (x0..x1, y0..y1, colour col) when on
  task automatic check_box(input string name, input bit on, input int x0, input int x1, input int y0,
                           input int y1, input logic [23:0] col);
    int bad;
    logic [23:0] e;
    bad = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      e = (on && x >= x0 && x <= x1 && y >= y0 && y <= y1) ? col : vid.img[y][x];
      if (vid.out[y][x] !== e) begin
        if (bad < 3) $display("  %s: (%0d,%0d) %h, expected %h", name, x, y, vid.out[y][x], e);
        bad++;
      end
    end
    check(bad == 0, $sformatf("%s: %0d pixels differ", name, bad));
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
    check(date == dut.u_regs.IP_DATE && date[31:24] >= 8'h01 && date[31:24] <= 8'h12 && date[23:16] >= 8'h01 &&
          date[23:16] <= 8'h31 && date[15:0] >= 16'h2000,
          $sformatf("DATE %h, expected a BCD mm/dd/yyyy date = %h", date, dut.u_regs.IP_DATE));
    check(rsv == 0, $sformatf("0x0C reads %h, expected 0", rsv));
    for (int a = 0; a < 16; a += 4) begin               // ID / VERSION / DATE: SLVERR, reserved: OKAY
      bfm.write_abs(10'(a), 32'hA5A5_5A5A);
      check(bfm.last_resp == ((a < 12) ? 2'b10 : 2'b00), $sformatf("write to 0x%0h answered %b", a, bfm.last_resp));
    end
    bfm.resp_errors = 0;
    bfm.read_abs(10'h0, v);
    check(v == id, "ID changed by a write");
    $display("[%0t] test_id_block: ID \"%s\", VERSION \"%s\", DATE %0h/%0h/%0h", $time, id, ver, date[31:24],
             date[23:16], date[15:0]);
  endtask

  task automatic test_registers();
    logic [31:0] v;
    bfm.read(10'h08, v);
    check(v == 0, $sformatf("reset CTRL %h", v));
    bfm.read(10'h10, v);
    check(v == 0, $sformatf("reset STATUS %h", v));
    bfm.read(10'h14, v);
    check(v == 0, $sformatf("reset FRAME_NUM %h", v));
    set_obj(2, 32'h0000_FF1F, 3, 33, 4, 25, 24'h123456, 32'h0033_3250);
    bfm.read(10'h60, v);
    check(v == 32'hFF1F, $sformatf("OBJ_CTRL 2 reads %h", v));
    bfm.read(10'h64, v);
    check(v == {16'd33, 16'd3}, $sformatf("OBJ_X 2 reads %h", v));
    bfm.read(10'h68, v);
    check(v == {16'd25, 16'd4}, $sformatf("OBJ_Y 2 reads %h", v));
    bfm.read(10'h6C, v);
    check(v == 32'h123456, $sformatf("OBJ_COLOR 2 reads %h", v));
    bfm.read(10'h258, v);
    check(v == 32'h0033_3250, $sformatf("OBJ_LABEL 2 reads %h", v));
    bfm.write(10'h150, 32'h0000_0A1F);
    bfm.read(10'h150, v);
    check(v == 32'h0A1F, $sformatf("TXT_CTRL 1 reads %h", v));
    bfm.write(10'h21C, 32'h4443_4241);
    bfm.read(10'h21C, v);
    check(v == 32'h4443_4241, $sformatf("TXT_CHARS 7 reads %h", v));
    set_obj(2, 0, 0, 0, 0, 0, 0, 0);
    bfm.write(10'h150, 0);
    $display("[%0t] test_registers: reset values, object / label / text registers read back", $time);
  endtask

  task automatic test_passthrough();
    logic [31:0] v;
    new_image();
    vid.gap_pct = 20;
    vid.bp_pct = 30;
    run_frame();
    check_box("pass-through, overlay disabled", 0, 0, 0, 0, 0, 0);
    vid.gap_pct = 0;
    vid.bp_pct = 0;
    bfm.read(10'h10, v);
    check(v[31:16] == 1, $sformatf("STATUS frames %0d after one frame", v[31:16]));
    $display("[%0t] test_passthrough: disabled overlay passes the video unchanged", $time);
  endtask

  task automatic test_commit();
    logic [31:0] v;
    bfm.write(10'h08, 1);                                  // ENABLE
    set_obj(0, 32'h0103, 5, 12, 3, 9, 24'hFF8040, 0);       // filled box
    new_image();
    run_frame();
    check_box("box written, no COMMIT", 0, 0, 0, 0, 0, 0);
    commit();
    bfm.read(10'h10, v);
    check(v[0], "STATUS[0] not pending after COMMIT");
    new_image();
    run_frame();
    check_box("box after COMMIT", 1, 5, 12, 3, 9, 24'hFF8040);
    bfm.read(10'h10, v);
    check(!v[0], "STATUS[0] still pending after the frame start");
    set_obj(0, 32'h0103, 20, 30, 10, 20, 24'h00FF00, 0);    // COMMIT in the middle of a frame: from the next one
    new_image();
    fork
      run_frame();
      begin
        while (!(vid.oy == H / 2)) @(posedge clk);
        commit();
      end
    join
    check_box("COMMIT in the middle of this frame", 1, 5, 12, 3, 9, 24'hFF8040);
    new_image();
    run_frame();
    check_box("the frame after the COMMIT", 1, 20, 30, 10, 20, 24'h00FF00);
    bfm.write(10'h08, 0);                                  // ENABLE clear: taken at the next frame start
    new_image();
    run_frame();
    check_box("ENABLE cleared", 0, 0, 0, 0, 0, 0);
    bfm.write(10'h08, 1);
    new_image();
    run_frame();
    check_box("ENABLE set again: the committed box", 1, 20, 30, 10, 20, 24'h00FF00);
    $display("[%0t] test_commit: COMMIT applies at the next frame start, ENABLE per frame", $time);
  endtask

  task automatic test_frame_number();
    logic [31:0] v, f;
    bfm.read(10'h14, f);
    new_image();
    run_frame();
    bfm.read(10'h14, v);
    check(v[19:0] == bcd_next(f[19:0]), $sformatf("FRAME_NUM %h after %h", v[19:0], f[19:0]));
    bfm.write(10'h14, 32'h0009_9999);
    bfm.read(10'h14, v);
    check(v[19:0] == bcd_next(f[19:0]), "FRAME_NUM changed by the write before the frame start");
    new_image();
    run_frame();
    bfm.read(10'h14, v);
    check(v[19:0] == 20'h99999, $sformatf("FRAME_NUM %h, wrote 99999 for this frame", v[19:0]));
    new_image();
    run_frame();
    bfm.read(10'h14, v);
    check(v[19:0] == 20'h00000, $sformatf("FRAME_NUM %h after 99999 (carry to 0)", v[19:0]));
    $display("[%0t] test_frame_number: one more each frame, set by FRAME_NUM, carries", $time);
  endtask

  function automatic logic [19:0] bcd_next(input logic [19:0] b);
    logic [19:0] r;
    logic cy;
    r = b;
    cy = 1'b1;
    for (int d = 0; d < 5; d++) if (cy) begin
      if (r[4*d +: 4] == 4'd9) r[4*d +: 4] = 4'd0;
      else begin
        r[4*d +: 4] = r[4*d +: 4] + 4'd1;
        cy = 1'b0;
      end
    end
    return r;
  endfunction
