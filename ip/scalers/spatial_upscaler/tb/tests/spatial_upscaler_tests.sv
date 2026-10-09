// ***************
// Filename: spatial_upscaler_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_spatial_upscaler testbench
//   (spatial_upscaler_tb.sv), moved out of it and `included into that
//   module, so they use its signals, parameters and models directly. Tasks,
//   in file order:
//     program_table  Configuration
//     ip_configure   Programs the IP-specific registers before each test (hook
//                    of the shared scaler suite)
// Date: 2026-10-08
// ***************
  // ---------------------------------------------------------------- configuration
  task automatic program_table(input int base, input real scale, input bit vert);
    gen_coefs(KERNEL_LANCZOS, 3.0, 0.0, TAPS, PHASE_BITS, COEF_FRAC, COEF_W, scale);
    for (int p = 0; p < PHASES; p++)
      for (int t = 0; t < TAPS; t++) begin
        if (vert) tab_v[p][t] = gen_tab[p][t];
        else      tab_h[p][t] = gen_tab[p][t];
        axil_write(base + 4 * (16 * p + t), 32'(gen_tab[p][t]));
      end
  endtask

  task automatic ip_configure();
    if (out_w > OUT_MAX_W || out_h > OUT_MAX_H) begin
      $display("TB_RESULT: FAIL (output %0dx%0d exceeds testbench limit %0dx%0d)",
               out_w, out_h, OUT_MAX_W, OUT_MAX_H);
      $finish;
    end
    program_table(16'h1000, real'(in_w) / real'(out_w), 1'b0);
    program_table(16'h2000, real'(in_h) / real'(out_h), 1'b1);
    axil_write(16'h4008, {16'(out_h), 16'(out_w)});   // sharpener size = scaler output
    axil_write(16'h4040, sharp);
    axil_write(16'h4004, 32'hE);
    axil_write(16'h4000, 32'h1);                      // enable sharpener
    axil_check(16'h4008, {16'(out_h), 16'(out_w)});
    for (int y = 0; y < out_h; y++)                   // stage-1 reference image
      for (int x = 0; x < out_w; x++)
        mid[y][x] = lanczos_pixel(x, y);
  endtask
