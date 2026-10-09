// ***************
// Filename: scaler_polyphase_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tb_scaler_polyphase testbench
//   (scaler_polyphase_tb.sv), moved out of it and `included into that
//   module, so they use its signals, parameters and models directly. Tasks,
//   in file order:
//     program_table         Derive a table for 'scale', write it over AXI-Lite
//                           (H at 0x1000, V at 0x2000), keep a copy for the
//                           model and spot-check read-back
//     ip_configure          Per test
//     check_default_tables  The tables must power up with bilinear weights
// Date: 2026-10-08
// ***************
  // Derive a table for 'scale', write it over AXI-Lite (H at 0x1000,
  // V at 0x2000), keep a copy for the model and spot-check read-back.
  task automatic program_table(input int base, input real scale, input bit vert);
    gen_coefs(kind, kpa, kpb, TAPS, PHASE_BITS, COEF_FRAC, COEF_W, aa ? scale : 1.0);
    for (int p = 0; p < PHASES; p++)
      for (int t = 0; t < TAPS; t++) begin
        if (vert) tab_v[p][t] = gen_tab[p][t];
        else      tab_h[p][t] = gen_tab[p][t];
        axil_write(base + 4 * (16 * p + t), 32'(gen_tab[p][t]));
      end
    // spot-check read-back (sign extension)
    for (int k = 0; k < 4; k++) begin
      int p = $urandom_range(PHASES - 1, 0), t = $urandom_range(TAPS - 1, 0);
      axil_check(base + 4 * (16 * p + t), 32'(gen_tab[p][t]));
    end
  endtask

  // Per test: tables derived from the X and Y scale factors
  task automatic ip_configure();
    program_table(16'h1000, real'(in_w) / real'(out_w), 1'b0);
    program_table(16'h2000, real'(in_h) / real'(out_h), 1'b1);
  endtask

  // The tables must power up with bilinear weights
  task automatic check_default_tables();
    // reset content = bilinear
    for (int p = 0; p < PHASES; p += 13) begin
      axil_check(16'h1000 + 4 * (16 * p + CTR),     32'(((PHASES - p) << COEF_FRAC) / PHASES));
      axil_check(16'h2000 + 4 * (16 * p + CTR + 1), 32'((p << COEF_FRAC) / PHASES));
    end
  endtask
