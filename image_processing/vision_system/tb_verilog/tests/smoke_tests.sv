// ***************
// Filename: smoke_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_smoke testbench (tb_smoke.sv), moved
//   out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check_point  Drives one (x,y) point through the DUT and checks it
//                  against coord_gen_ref(), tolerating a small ULP-level
//                  difference from the iterative reciprocal divider (same
//                  tolerance convention the rest of this project's testbenches
//                  use for bit-exactness in pixel space -- here in Q16.16
//                  coordinate space the DUT and reference should agree far
//                  more tightly since there's no 8-bit pixel quantization
//                  involved)
// Date: 2026-10-08
// ***************
  // Drives one (x,y) point through the DUT and checks it against
  // coord_gen_ref(), tolerating a small ULP-level difference from the
  // iterative reciprocal divider (same tolerance convention the rest of
  // this project's testbenches use for bit-exactness in pixel space --
  // here in Q16.16 coordinate space the DUT and reference should agree
  // far more tightly since there's no 8-bit pixel quantization involved).
  task automatic check_point(input string label, input int x, input int y);
    longint exp_sx, exp_sy;
    longint diff_x, diff_y;
    int wait_cycles;
    begin
      coord_gen_ref(cfg.cx_pix, cfg.cy_pix, cfg.fx_pix, cfg.fy_pix,
                     cfg.k1, cfg.k2, cfg.k3, cfg.p1, cfg.p2,
                     int'(cfg.model_sel),
                     cfg.h11, cfg.h12, cfg.h13, cfg.h21, cfg.h22, cfg.h23, cfg.h31, cfg.h32,
                     x, y, exp_sx, exp_sy);

      in_x <= x[COORD_W-1:0]; in_y <= y[COORD_W-1:0]; in_valid <= 1'b1;
      @(posedge clk);
      in_valid <= 1'b0;
      // Poll for out_valid rather than a fixed cycle count -- the fast
      // path (MODEL_RADIAL/AFFINE/SCALING) and the slow per-pixel-divide
      // path (MODEL_FISHEYE/PANORAMIC/PERSPECTIVE) have very different
      // latencies (9 vs. ~38 cycles), both fixed but not worth hardcoding
      // two separate wait counts into this testbench.
      wait_cycles = 0;
      while (!out_valid && wait_cycles < 100) begin
        @(posedge clk);
        wait_cycles = wait_cycles + 1;
      end

      if (!out_valid) begin
        $display("[%s] (%0d,%0d) FAIL: out_valid not asserted within timeout", label, x, y);
        total_fail = total_fail + 1;
      end else begin
        diff_x = longint'(out_sx_q16) - exp_sx; if (diff_x < 0) diff_x = -diff_x;
        diff_y = longint'(out_sy_q16) - exp_sy; if (diff_y < 0) diff_y = -diff_y;
        if (diff_x <= 4 && diff_y <= 4) begin
          $display("[%s] (%0d,%0d) PASS  sx=%0d (exp %0d, d=%0d)  sy=%0d (exp %0d, d=%0d)",
                     label, x, y, out_sx_q16, exp_sx, diff_x, out_sy_q16, exp_sy, diff_y);
        end else begin
          $display("[%s] (%0d,%0d) FAIL  sx=%0d (exp %0d, d=%0d)  sy=%0d (exp %0d, d=%0d)",
                     label, x, y, out_sx_q16, exp_sx, diff_x, out_sy_q16, exp_sy, diff_y);
          total_fail = total_fail + 1;
        end
      end
      total_checks = total_checks + 1;
      // one idle cycle between checks -- coord_gen tolerates sparse valid
      // inputs by design (same property the bicubic gather FSM's request
      // pacing relies on), so this also incidentally exercises that.
      @(posedge clk);
    end
  endtask
