// ***************
// Filename: feature_detect_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the feature_detect_tb testbench
//   (feature_detect_tb.sv), `included into that module, so they use its
//   signals directly. The structural checks of the block; every pixel's
//   feature bits and every register after each frame are compared with the
//   golden model by the cocotb test (tb/python/feature_detect_tb.py).
//   Tasks, in file order:
//     check              Counts an error and prints the message when the
//                        condition is false
//     flat / square      Test scenes: a flat grey, a square of a given luma
//     run_frame          Sends one frame (random stalls of the observed
//                        stream when asked), waits for done_o, checks that
//                        every beat came out again on m_axis in order
//     test_id_block      ID "FEAT", VERSION ("d.dd") and DATE (BCD
//                        mm/dd/yyyy) at the base address, read only
//                        (SLVERR); the rest of the map from 0x10
//     test_registers     Reset values (EDGE 0x00080080, MOTION 0x00002214,
//                        STATUS, FRAMES) and read back
//     test_forward       CTRL.EN = 0: every beat forwarded, no feature bit,
//                        no frame counted; EN = 1 with stalls: forwarded,
//                        FRAMES and done_o count the frame, a square gives
//                        edges (EDGE_COUNT), none at threshold 2040
//     test_restart       The background is valid after a frame; a RESTART
//                        written between frames acts at the next frame start
//                        (STATUS.BG_VALID low during that frame, valid again
//                        after it)
// Date: 2026-10-21
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      if (errors < 20) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic flat(input int v);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) vid.img[y][x] = {3{8'(v)}};
  endtask
  task automatic square(input int x0, input int y0, input int s, input int v);
    for (int y = y0; y < y0 + s && y < H; y++) for (int x = x0; x < x0 + s && x < W; x++) vid.img[y][x] = {3{8'(v)}};
  endtask

  // one frame: sent, every beat seen again on m_axis (in order), done_o waited for when the frame is processed
  task automatic run_frame(input string name, input bit processed);
    int d0, n0, bad;
    d0 = dones;
    n0 = fwd_n;
    fwd_bad = 0;
    vid.send(W, H);
    repeat (8) @(posedge clk);
    if (processed) begin
      for (int t = 0; t < 20000 && dones == d0; t++) @(posedge clk);
      check(dones == d0 + 1, $sformatf("%s: done_o %0d times", name, dones - d0));
    end else begin
      repeat (200) @(posedge clk);
      check(dones == d0, $sformatf("%s: done_o without a processed frame", name));
    end
    check(fwd_n - n0 == W * H, $sformatf("%s: %0d beats forwarded, sent %0d", name, fwd_n - n0, W * H));
    bad = fwd_bad;
    check(bad == 0, $sformatf("%s: %0d forwarded beats differ from the input", name, bad));
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
    bfm.write(8'h34, 32'h0000_7805);
    bfm.read(8'h34, v);
    check(v == 32'h0000_7805, $sformatf("SKY_CFG reads %h", v));
    bfm.write(8'h0C, (H << 16) | W);
    bfm.read(8'h0C, v);
    check(v == ((H << 16) | W), $sformatf("FRAME_SIZE reads %h", v));
    $display("[%0t] test_registers: reset values, read back", $time);
  endtask

  task automatic test_forward();
    logic [31:0] v;
    flat(120);
    square(10, 8, 12, 220);
    bfm.write(8'h08, 0);                                  // not processed
    feat_seen = 0;
    run_frame("EN = 0", 0);
    check(feat_seen == 0, "feature bits while the frame is not processed");
    bfm.read(8'h24, v);
    check(v == 0, $sformatf("FRAMES %0d without a processed frame", v));
    bfm.write(8'h08, 32'h7);                              // EN, edges, motion
    stall_pct = 30;
    run_frame("EN = 1, stalls", 1);
    stall_pct = 0;
    bfm.read(8'h24, v);
    check(v == 1, $sformatf("FRAMES %0d after one frame", v));
    bfm.read(8'h28, v);
    check(v > 0, "no edges around the square");
    bfm.write(8'h10, 32'h0000_07F8);                      // threshold 2040: no edge
    run_frame("threshold 2040", 1);
    bfm.read(8'h28, v);
    check(v == 0, $sformatf("EDGE_COUNT %0d at threshold 2040", v));
    bfm.write(8'h10, 32'h0008_0080);
    $display("[%0t] test_forward: beats forwarded in order, frames and edges counted", $time);
  endtask

  task automatic test_restart();
    logic [31:0] v;
    bfm.read(8'h20, v);
    check(v[1], "background not valid after processed frames");
    bfm.write(8'h08, 32'h17);                             // RESTART: at the next frame start
    bfm.read(8'h20, v);
    check(v[1], "background cleared before the next frame start");
    fork
      run_frame("frame after RESTART", 1);
      begin
        for (int t = 0; t < 100000 && !(vid.sent > 0 && dut.u_core.in_frame); t++) @(posedge clk);
        check(dut.u_core.in_frame, "the frame after RESTART did not start");
        @(posedge clk);
        check(!dut.u_core.bg_valid, "background still valid in the frame after RESTART");
      end
    join
    bfm.read(8'h20, v);
    check(v[1], "background not valid after the refilling frame");
    $display("[%0t] test_restart: RESTART acts at the next frame start", $time);
  endtask
