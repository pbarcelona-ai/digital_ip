// ***************
// Filename: scaler_trilinear_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_scaler_trilinear testbench
//   (scaler_trilinear_tb.sv), moved out of it and `included into that
//   module, so they use its signals, parameters and models directly. Tasks,
//   in file order:
//     build_pyramid  Build the reference pyramid from img[][] with the 2x2 box
//                    filter
//     derive_regs    Footprint -> probe count, LOD and probe step/start
//                    registers
//     ip_configure   Per test
// Date: 2026-10-08
// ***************
  // Build the reference pyramid from img[][] with the 2x2 box filter
  task automatic build_pyramid();
    lw[0] = in_w;
    lh[0] = in_h;
    for (int y = 0; y < in_h; y++) for (int x = 0; x < in_w; x++) mip[0][y][x] = img[y][x];
    for (int k = 1; k < LEVELS; k++) begin
      lw[k] = (lw[k-1] > 1) ? lw[k-1] / 2 : 1;
      lh[k] = (lh[k-1] > 1) ? lh[k-1] / 2 : 1;
      for (int y = 0; y < lh[k]; y++)
        for (int x = 0; x < lw[k]; x++)
          for (int c = 0; c < CHANNELS; c++) begin
            int s = 2;
            for (int j = 0; j < 2; j++)
              for (int i = 0; i < 2; i++)
                s += comp(mip[k-1][clampi(2*y+j, 0, lh[k-1]-1)][clampi(2*x+i, 0, lw[k-1]-1)], c);
            mip[k][y][x][c*COMP_W +: COMP_W] = COMP_W'(s >> 2);
          end
    end
  endtask

  // Footprint -> probe count, LOD and probe step/start registers
  task automatic derive_regs();
    real sx = real'(reg_step_x) / 65536.0, sy = real'(reg_step_y) / 65536.0;
    real fmaj = (sx > sy) ? sx : sy, fmin = (sx > sy) ? sy : sx;
    real lod, d;
    if (fmaj < 1.0) fmaj = 1.0;
    if (fmin < 1.0) fmin = 1.0;
    alog2 = 0;
    if (ANISO_MAX > 0) begin
      alog2 = int'($floor(log2r(fmaj / fmin) + 0.5));
      if (alog2 > ANISO_MAX) alog2 = ANISO_MAX;
      if (alog2 < 0) alog2 = 0;
    end
    lod = log2r(fmaj / real'(1 << alog2));
    if (lod < 0.0) lod = 0.0;
    lod_reg = int'($floor(lod * 256.0 + 0.5));
    d = fmaj / real'(1 << alog2);                        // probe spacing (level-0 px)
    pstep_x = 0;
    pstep_y = 0;
    if (alog2 > 0) begin
      if (sx >= sy) pstep_x = int'($floor(d * 65536.0 + 0.5));
      else          pstep_y = int'($floor(d * 65536.0 + 0.5));
    end
    pstart_x = -((pstep_x * ((1 << alog2) - 1)) >>> 1);
    pstart_y = -((pstep_y * ((1 << alog2) - 1)) >>> 1);
  endtask

  // Per test: derive and program the mip registers, check level sizes
  task automatic ip_configure();
    derive_regs();
    if (lod_override >= 0) lod_reg = lod_override;
    build_pyramid();
    axil_write(12'h040, lod_reg);
    axil_write(12'h044, alog2);
    axil_write(12'h048, pstep_x);
    axil_write(12'h04C, pstep_y);
    axil_write(12'h050, pstart_x);
    axil_write(12'h054, pstart_y);
    axil_check(12'h040, lod_reg);
    axil_check(12'h044, alog2);
    axil_check(12'h050, pstart_x);
    for (int k = 0; k < LEVELS; k++) axil_check(12'h060 + 4 * k, {16'(lh[k]), 16'(lw[k])});
  endtask
