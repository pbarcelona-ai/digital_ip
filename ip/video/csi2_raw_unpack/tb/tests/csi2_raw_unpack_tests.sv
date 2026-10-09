// ***************
// Filename: csi2_raw_unpack_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the csi2_raw_unpack_tb testbench
//   (csi2_raw_unpack_tb.sv), moved out of it and `included into that module,
//   so they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check      Counts an error and prints the message when the condition is
//                false
//     run_prep
//     run_frame
//     run_loss   Frame 0 loses one word in the middle of its second line
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  task automatic run_prep(input logic [5:0] f, input int w, input int h, input int gp, input int bp);
    int bpg, ppg;
    fmt = f; line_w = w; nlines = h; npix = w * h; gap_pct = gp; bp_pct = bp;
    ppg = (f == 6'h2B) ? 4 : (f == 6'h2C) ? 2 : 1; bpg = (f == 6'h2B) ? 5 : (f == 6'h2C) ? 3 : 1;
    line_bytes = w / ppg * bpg;
    for (int i = 0; i < npix; i++) src[i] = (f == 6'h2B) ? $urandom_range(1023) : (f == 6'h2C) ? $urandom_range(4095) : $urandom_range(255);
    for (int y = 0; y < h; y++)
      for (int gi = 0; gi < w / ppg; gi++) begin
        int base, o; base = y * w + gi * ppg; o = y * line_bytes + gi * bpg;
        if (f == 6'h2B) begin
          for (int k = 0; k < 4; k++) fb[o + k] = src[base + k][9:2];
          fb[o + 4] = {src[base+3][1:0], src[base+2][1:0], src[base+1][1:0], src[base][1:0]};
        end else if (f == 6'h2C) begin
          fb[o] = src[base][11:4]; fb[o + 1] = src[base+1][11:4]; fb[o + 2] = {src[base+1][3:0], src[base][3:0]};
        end else fb[o] = src[base][7:0];
      end
  endtask

  task automatic run_frame(input logic [5:0] f, input int w, input int h, input int gp, input int bp);
    run_prep(f, w, h, gp, bp);
    fork g_u[0].drive(); g_u[1].drive(); g_u[2].drive(); g_u[3].drive(); join
    repeat (50) @(posedge clk);
    check(g_u[0].nout == npix && g_u[1].nout == npix && g_u[2].nout == npix && g_u[3].nout == npix,
          $sformatf("fmt %02h %0dx%0d: pixels out %0d %0d %0d %0d, exp %0d", f, w, h, g_u[0].nout, g_u[1].nout, g_u[2].nout, g_u[3].nout, npix));
    $display("fmt 0x%02h %0dx%0d (%0d bytes/line): %0d pixels per instance", f, w, h, line_bytes, g_u[0].nout);
  endtask

  // Frame 0 loses one word in the middle of its second line; frame 1 must be exact
  task automatic run_loss(input logic [5:0] f, input int w, input int h);
    run_prep(f, w, h, 10, 20);
    lose = 1; check_on = 0;
    fork g_u[0].drive(2); g_u[1].drive(2); g_u[2].drive(2); g_u[3].drive(2); join
    repeat (50) @(posedge clk);
    check(g_u[0].nout == npix && g_u[1].nout == npix && g_u[2].nout == npix && g_u[3].nout == npix,
          $sformatf("after a lost word: pixels of the next frame %0d %0d %0d %0d, exp %0d", g_u[0].nout, g_u[1].nout, g_u[2].nout, g_u[3].nout, npix));
    $display("fmt 0x%02h %0dx%0d: frame with a lost word, next frame exact", f, w, h);
    lose = 0; check_on = 1;
  endtask
