// ***************
// Filename: vid_timing_gen_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the vid_timing_gen_tb testbench
//   (vid_timing_gen_tb.sv), moved out of it and `included into that module,
//   so they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check          Counts an error and prints the message when the condition
//                    is false
//     measure_frame  Measure one frame starting at sof (the first active
//                    pixel)
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      if (errors < 30) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  // Measure one frame starting at sof (the first active pixel)
  task automatic measure_frame(input int extra_exp);
    int line, h, n_de, vs_start_line, vs_lines, waits;
    bit hs_a, hs_q, vs_a, vs_q, first_vs;
    int htot, vtot;
    htot = ha + hf + hs + hb;
    vtot = va + vf + vs + vb + extra_exp;
    while (!sof) @(posedge clk);
    line = 0;
    h = 0;
    n_de = 0;
    vs_start_line = -1;
    vs_lines = 0;
    waits = 0;
    hs_q = 0;
    vs_q = 0;
    for (int i = 0; i < htot * vtot; i++) begin
      hs_a = (hso == hp);
      vs_a = (vso == vp);
      // horizontal: active 0..ha-1, sync ha+hf .. ha+hf+hs-1
      check(de == (h < ha && line < va), $sformatf("de at h %0d line %0d", h, line));
      if (de) begin
        check(x == h && y == line, $sformatf("x/y %0d/%0d at %0d/%0d", x, y, h, line));
        n_de++;
      end
      check(sof == (h == 0 && line == 0), $sformatf("sof at %0d/%0d", h, line));
      check(eol == (h == ha - 1 && line < va), $sformatf("eol at %0d/%0d", h, line));
      check(vbl == (line >= va), $sformatf("vblank at line %0d", line));
      check(hs_a == (h >= ha + hf && h < ha + hf + hs), $sformatf("hsync at h %0d line %0d", h, line));
      if (vs_a && !vs_q) begin
        vs_start_line = line;
        check(h == ha + hf, $sformatf("vsync starts at h %0d, not at the hsync leading edge %0d", h, ha + hf));
      end
      if (!vs_a && vs_q) check(h == ha + hf, $sformatf("vsync ends at h %0d, not at the hsync leading edge", h));
      if (vs_a && h == ha + hf) vs_lines++;
      if (wt && h == 0) waits++;
      vs_q = vs_a;
      @(posedge clk);
      h++;
      if (h == htot) begin
        h = 0;
        line++;
      end
    end
    check(n_de == ha * va, $sformatf("%0d active pixels, exp %0d", n_de, ha * va));
    check(vs_start_line == va + vf && vs_lines == vs, $sformatf("vsync line %0d x%0d, exp %0d x%0d", vs_start_line, vs_lines, va + vf, vs));
    check(waits == extra_exp, $sformatf("%0d genlock lines, exp %0d", waits, extra_exp));
    check(sof, "next frame did not start on time");
  endtask
