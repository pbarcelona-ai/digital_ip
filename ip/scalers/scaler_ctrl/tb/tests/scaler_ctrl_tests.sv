// ***************
// Filename: scaler_ctrl_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_scaler_ctrl testbench
//   (scaler_ctrl_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     beat           Drive one input beat with random idle cycles
//     frame          Send an input frame (optionally junk first, a restarted
//                    partial frame, or one wrong tlast)
//     capture_test   Complete capture scenario
//     expect_gen
//     pingpong_test
// Date: 2026-10-08
// ***************
  // Drive one input beat with random idle cycles
  task automatic beat(logic [PIX_W-1:0] d, bit u, bit l);
    @(negedge clk);
    while ($urandom_range(3, 0) == 0) begin
      s_tvalid = 0;
      @(negedge clk);
    end
    s_tvalid = 1;
    s_tdata = d;
    s_tuser = u;
    s_tlast = l;
    do @(posedge clk);
    while (!s_tready);
    @(negedge clk);
    s_tvalid = 0;
    s_tuser = 0;
    s_tlast = 0;
  endtask

  // Send an input frame (optionally junk first, a restarted partial
  // frame, or one wrong tlast); the expected image is kept in exp_img
  task automatic frame(int w, int h, int junk, bit bad_eol, int restart_at);
    for (int k = 0; k < junk; k++) beat(PIX_W'($urandom), 0, 0);
    if (restart_at > 0)                             // partial frame, then new SOF
      for (int k = 0; k < restart_at; k++) beat(PIX_W'($urandom), k == 0, 0);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) begin
      exp_img[y][x] = PIX_W'($urandom);
      beat(exp_img[y][x], x == 0 && y == 0, (x == w - 1) ^ (bad_eol && y == 1 && x == 0));
    end
  endtask

  // Complete capture scenario: configure, enable, send a frame, check the
  // frame-buffer writes, gen_start and STATUS, emulate gen_done, check
  // FRAME_CNT / FRAME_DONE / error bits, then disable and clear
  task automatic capture_test(int w, int h, int junk, bit bad_eol, int restart_at);
    logic [31:0] st, fc0, fc1;
    e_pre = errors;
    for (int y = 0; y < MAX_H; y++) for (int x = 0; x < MAX_W; x++) fb_cnt[y][x] = 0;
    n_writes = 0;
    n_starts = 0;
    write_after_start = 0;
    axil_read(12'h020, fc0);
    axil_write(12'h008, {16'(h), 16'(w)});
    axil_write(12'h004, 32'hE);
    axil_write(12'h000, 1);
    frame(w, h, junk, bad_eol, restart_at);
    repeat (5) @(posedge clk);
    checks += 3;
    if (n_starts != 1) begin
      errors++;
      $display("ERROR: gen_start pulses=%0d", n_starts);
    end
    if (write_after_start) begin
      errors++;
      $display("ERROR: fb write after gen_start");
    end
    if (n_writes != w * h + restart_at) begin
      errors++;
      $display("ERROR: writes %0d", n_writes);
    end
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) begin
      checks++;
      if (fb[y][x] !== exp_img[y][x]) begin
        errors++;
        $display("ERROR: fb(%0d,%0d)=%0h exp %0h", x, y, fb[y][x], exp_img[y][x]);
      end
    end
    axil_check(12'h004, 32'h21, 32'h23);   // busy, generating, not done yet
    @(negedge clk) gen_done = 1;
    @(negedge clk) gen_done = 0;
    axil_read(12'h004, st);
    checks += 4;
    if (!st[1]) begin
      errors++;
      $display("ERROR: FRAME_DONE not set");
    end
    if (st[2] !== (junk > 0 || restart_at > 0)) begin
      errors++;
      $display("ERROR: SOF_ERR=%0b", st[2]);
    end
    if (st[3] !== bad_eol) begin
      errors++;
      $display("ERROR: EOL_ERR=%0b", st[3]);
    end
    if (!st[4]) begin
      errors++;
      $display("ERROR: not back in CAPTURE with ENABLE=1");
    end
    axil_read(12'h020, fc1);
    checks++;
    if (fc1 != fc0 + 1) begin
      errors++;
      $display("ERROR: FRAME_CNT");
    end
    axil_write(12'h000, 0);
    axil_write(12'h004, 32'hE);
    axil_check(12'h004, 32'h0, 32'h3F);   // idle, sticky bits cleared
    tests++;
    $display("capture %0dx%0d junk=%0d bad_eol=%0b restart=%0d : %s", w, h, junk, bad_eol,
             restart_at, errors == e_pre ? "pass" : "FAIL");
  endtask

  task automatic expect_gen(input int buf_exp, input string what);
    int n0, t;
    n0 = n_starts;
    t = 0;
    while (n_starts == n0 && t < 50) begin
      @(posedge clk);
      t++;
    end
    checks++;
    if (n_starts == n0) begin
      errors++;
      $display("ERROR: no gen_start for %s", what);
    end
    else if (gen_buf !== buf_exp) begin
      errors++;
      $display("ERROR: %s generated from buffer %0d, expected %0d", what, gen_buf, buf_exp);
    end
  endtask

  task automatic pingpong_test();
    int stall;
    n_starts = 0;
    axil_write(12'h008, {16'd4, 16'd5});
    axil_write(12'h004, 32'hE);
    axil_write(12'h000, 1);
    frame(5, 4, 0, 0, 0);                            // A -> buffer 0
    expect_gen(0, "frame A");
    frame(5, 4, 0, 0, 0);                            // B -> buffer 1, no stall
    for (int y = 0; y < 4; y++) for (int x = 0; x < 5; x++) img_b[y][x] = exp_img[y][x];
    checks++;
    if (n_starts != 1) begin
      errors++;
      $display("ERROR: B started generation early");
    end
    send_bg = 1;                                     // C: must stall
    stall = 0;
    repeat (40) begin
      @(posedge clk);
      if (s_tvalid && !s_tready) stall++;
    end
    checks++;
    if (stall < 30) begin
      errors++;
      $display("ERROR: C not stalled while both buffers busy");
    end
    @(negedge clk) gen_done = 1; // A done
    @(negedge clk) gen_done = 0;
    expect_gen(1, "frame B");
    wait (!send_bg);                                 // C captured -> buffer 0
    repeat (3) @(posedge clk);
    for (int y = 0; y < 4; y++) for (int x = 0; x < 5; x++) begin
      checks += 2;
      if (fbp[1][y][x] !== img_b[y][x]) begin
        errors++;
        $display("ERROR: buffer 1 != frame B at (%0d,%0d)", x, y);
      end
      if (fbp[0][y][x] !== exp_img[y][x]) begin
        errors++;
        $display("ERROR: buffer 0 != frame C at (%0d,%0d)", x, y);
      end
    end
    @(negedge clk) gen_done = 1; // B done
    @(negedge clk) gen_done = 0;
    expect_gen(0, "frame C");
    @(negedge clk) gen_done = 1; // C done
    @(negedge clk) gen_done = 0;
    axil_check(12'h020, 3);                          // FRAME_CNT
    axil_write(12'h000, 0);
    repeat (5) @(posedge clk);
    axil_check(12'h004, 32'h2, 32'h33);              // idle, FRAME_DONE set
    tests++;
    $display("ping-pong sequencing : %s", errors == 0 ? "pass" : "FAIL");
  endtask
