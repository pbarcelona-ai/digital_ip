// ***************
// Filename: coord_gen_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_coord_gen testbench (tb_coord_gen.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     coord_gen_ref
//     check_point
// Date: 2026-10-08
// ***************
  task automatic coord_gen_ref(
    input  longint cx_pix, input longint cy_pix,
    input  longint fx_pix, input longint fy_pix,
    input  longint k1, input longint k2, input longint k3,
    input  longint p1, input longint p2,
    input  int     model_sel,
    input  longint h11, input longint h12, input longint h13,
    input  longint h21, input longint h22, input longint h23,
    input  longint h31, input longint h32,
    input  int     x, input int y,
    output longint sx, output longint sy
  );
    longint dx, dy, nx, ny, recip_fx, recip_fy;
    longint r2, r4, r6, t1, t2, t3, factor;
    longint tangx, tangy, sxn, syn;
    longint denom_raw, denom_safe, recip_denom;
    longint xq, yq, num_x, num_y;
    begin
      recip_fx = recip_ref(fx_pix);
      recip_fy = recip_ref(fy_pix);
      dx = (longint'(x) <<< FRAC_BITS) - cx_pix;
      dy = (longint'(y) <<< FRAC_BITS) - cy_pix;
      nx = qmul_ref(dx, recip_fx);
      ny = qmul_ref(dy, recip_fy);
      r2 = qmul_ref(nx, nx) + qmul_ref(ny, ny);

      if (model_sel == 0) begin  // MODEL_RADIAL
        r4 = qmul_ref(r2, r2);
        r6 = qmul_ref(r4, r2);
        t1 = qmul_ref(k1, r2);
        t2 = qmul_ref(k2, r4);
        t3 = qmul_ref(k3, r6);
        factor = ONE_Q16 + t1 + t2 + t3;
        tangx = (qmul_ref(p1, qmul_ref(nx, ny)) <<< 1) + qmul_ref(p2, r2 + (qmul_ref(nx, nx) <<< 1));
        tangy = qmul_ref(p1, r2 + (qmul_ref(ny, ny) <<< 1)) + (qmul_ref(p2, qmul_ref(nx, ny)) <<< 1);
        sxn = qmul_ref(nx, factor) + tangx;
        syn = qmul_ref(ny, factor) + tangy;
        sx  = cx_pix + qmul_ref(sxn, fx_pix);
        sy  = cy_pix + qmul_ref(syn, fy_pix);
      end else if (model_sel == 1) begin  // MODEL_FISHEYE (division model)
        r4 = qmul_ref(r2, r2);
        denom_raw = ONE_Q16 + qmul_ref(k1, r2) + qmul_ref(k2, r4);
        denom_safe = (denom_raw <= 0) ? 64'sd1 : denom_raw;
        recip_denom = recip_ref(denom_safe);
        sx = cx_pix + qmul_ref(qmul_ref(nx, recip_denom), fx_pix);
        sy = cy_pix + qmul_ref(qmul_ref(ny, recip_denom), fy_pix);
      end else if (model_sel == 5) begin  // MODEL_PANORAMIC (division model, x only)
        denom_raw = ONE_Q16 + qmul_ref(k1, qmul_ref(nx, nx));
        denom_safe = (denom_raw <= 0) ? 64'sd1 : denom_raw;
        recip_denom = recip_ref(denom_safe);
        sx = cx_pix + qmul_ref(qmul_ref(nx, recip_denom), fx_pix);
        sy = cy_pix + qmul_ref(ny, fy_pix);
      end else if (model_sel == 3) begin  // MODEL_PERSPECTIVE (homography)
        xq = longint'(x) <<< FRAC_BITS;
        yq = longint'(y) <<< FRAC_BITS;
        denom_raw = ONE_Q16 + qmul_ref(h31, xq) + qmul_ref(h32, yq);
        denom_safe = (denom_raw <= 0) ? 64'sd1 : denom_raw;
        recip_denom = recip_ref(denom_safe);
        num_x = qmul_ref(h11, xq) + qmul_ref(h12, yq) + h13;
        num_y = qmul_ref(h21, xq) + qmul_ref(h22, yq) + h23;
        sx = qmul_ref(num_x, recip_denom);
        sy = qmul_ref(num_y, recip_denom);
      end else begin  // MODEL_AFFINE / MODEL_SCALING: reserved hooks, identity
        sxn = nx;
        syn = ny;
        sx  = cx_pix + qmul_ref(sxn, fx_pix);
        sy  = cy_pix + qmul_ref(syn, fy_pix);
      end
    end
  endtask

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

      in_x <= x[COORD_W-1:0];
      in_y <= y[COORD_W-1:0];
      in_valid <= 1'b1;
      @(posedge clk);
      in_valid <= 1'b0;
      wait_cycles = 0;
      while (!out_valid && wait_cycles < 100) begin
        @(posedge clk);
        wait_cycles = wait_cycles + 1;
      end

      total_checks = total_checks + 1;
      if (!out_valid) begin
        $display("[%s] (%0d,%0d) FAIL: out_valid not asserted within timeout", label, x, y);
        total_fail = total_fail + 1;
      end else begin
        diff_x = longint'(out_sx_q16) - exp_sx;
        if (diff_x < 0) diff_x = -diff_x;
        diff_y = longint'(out_sy_q16) - exp_sy;
        if (diff_y < 0) diff_y = -diff_y;
        // small tolerance for reciprocal-divider rounding (this
        // testbench's recip_ref is an exact integer divide; the RTL uses
        // an iterative approximation elsewhere in the design -- coord_gen
        // itself just consumes a precomputed reciprocal, so this
        // tolerance covers only qmul truncation propagation, not the
        // reciprocal's own approximation)
        if (diff_x <= 4 && diff_y <= 4) begin
          $display("[%s] (%0d,%0d) PASS  sx=%0d (exp %0d, d=%0d)  sy=%0d (exp %0d, d=%0d)",
                     label, x, y, out_sx_q16, exp_sx, diff_x, out_sy_q16, exp_sy, diff_y);
        end else begin
          $display("[%s] (%0d,%0d) FAIL  sx=%0d (exp %0d, d=%0d)  sy=%0d (exp %0d, d=%0d)",
                     label, x, y, out_sx_q16, exp_sx, diff_x, out_sy_q16, exp_sy, diff_y);
          total_fail = total_fail + 1;
        end
      end
      @(posedge clk);
    end
  endtask
