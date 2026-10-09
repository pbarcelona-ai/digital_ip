// ***************
// Filename: scaler_dda_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_scaler_dda testbench
//   (scaler_dda_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     run  One frame
// Date: 2026-10-08
// ***************
  // One frame: start the DDA, advance with random stalls and check each
  // emitted pixel against the closed-form coordinate and flags
  task automatic run(int w, int h, int sx, int sy, int ox0, int oy0, int stall_pct);
    int n = 0, ox = 0, oy = 0;
    @(negedge clk);
    out_w = w; out_h = h; step_x = sx; step_y = sy; offs_x = ox0; offs_y = oy0;
    start = 1;
    @(negedge clk) start = 0;
    while (n < w * h) begin
      adv  = ($urandom_range(99, 0) >= stall_pct);
      hold = ($urandom_range(99, 0) < stall_pct / 2);
      if (busy) begin
        checks++;
        if (nxt_y !== 32'(longint'(oy0) + longint'(oy) * sy)) begin
          errors++; if (errors < 8) $display("ERROR: nxt_y %0h at row %0d", nxt_y, oy);
        end
      end
      @(posedge clk); #1;
      if (adv && o_valid) begin
        longint ex = longint'(ox0) + longint'(ox) * sx;
        longint ey = longint'(oy0) + longint'(oy) * sy;
        checks++;
        if (o_x !== 32'(ex) || o_y !== 32'(ey) || o_sof !== (n == 0) ||
            o_eol !== (ox == w - 1) || o_eof !== (n == w * h - 1)) begin
          errors++;
          if (errors < 8) $display("ERROR: px %0d (%0d,%0d) got x=%0h y=%0h sof%0b eol%0b eof%0b",
                                   n, ox, oy, o_x, o_y, o_sof, o_eol, o_eof);
        end
        n++;
        if (ox == w - 1) begin ox = 0; oy++; end else ox++;
      end
      @(negedge clk);
    end
    adv = 1; hold = 0; @(posedge clk); #1;
    checks++;
    if (busy || o_valid) begin errors++; $display("ERROR: DDA still busy/valid after frame"); end
    @(negedge clk) adv = 0;
  endtask
