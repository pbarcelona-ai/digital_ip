// ***************
// Filename: dpll_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the dpll_tb testbench (dpll_tb.sv),
//   `included into that module, so they use its signals directly. Tasks,
//   in file order:
//     check          Counts an error and prints the message when the
//                    condition is false
//     test_lock      Both loops lock within 1000 reference cycles
//     test_frequency Exact long-term output frequencies (integer and
//                    fractional ratio, +3 % / -2 % oscillator error)
//     test_alignment Every /8 rising edge coincides with a /4 rising edge
//     test_duty      50 % duty cycle of the /5 output
//     test_gating    en_i stops and restarts an output without short pulses
//     test_relock    The loop locks again after a reset
// Date: 2026-10-09
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic test_lock();
    int n = 0;
    while (!(lk_i && lk_f) && n < 1000) begin
      @(posedge ref_clk);
      n++;
    end
    check(lk_i && lk_f, $sformatf("no lock after %0d reference cycles (int %b frac %b)", n, lk_i, lk_f));
    $display("[%0t] locked after %0d reference cycles", $time, n);
  endtask

  task automatic test_frequency();
    localparam int NREF = 3000;
    int c[5];
    int exp[5] = '{NREF * 16 / 4, NREF * 16 / 8, NREF * 16 / 5, NREF * 25 / 6, NREF * 25 / 9};
    @(posedge ref_clk);
    c = ec;
    repeat (NREF) @(posedge ref_clk);
    for (int k = 0; k < 5; k++) begin
      c[k] = ec[k] - c[k];
      check(c[k] >= exp[k] - 1 && c[k] <= exp[k] + 1,
            $sformatf("output %0d: %0d edges in %0d reference cycles, expected %0d", k, c[k], NREF, exp[k]));
      $display("output %0d: %0d edges in %0d reference cycles (expected %0d)", k, c[k], NREF, exp[k]);
    end
    check(lk_i && lk_f, "lock lost during the frequency check");
  endtask

  task automatic test_alignment();
    realtime t8;
    int bad = 0;
    repeat (200) begin
      @(posedge ck_i[1]);
      t8 = $realtime;
      #0.001;
      if (t4 != t8) bad++;
    end
    check(bad == 0, $sformatf("%0d of 200 /8 rising edges without a coincident /4 edge", bad));
  endtask

  task automatic test_duty();
    realtime r, f, hi = 0, lo = 0, mx = 0;
    repeat (100) begin
      @(posedge ck_i[2]) r = $realtime;
      @(negedge ck_i[2]) f = $realtime;
      hi = f - r;
      @(posedge ck_i[2]) lo = $realtime - f;
      if (hi - lo > mx) mx = hi - lo;
      if (lo - hi > mx) mx = lo - hi;
    end
    check(mx <= 0.005, $sformatf("/5 output: high / low differ by %0.3f ns", mx));
  endtask

  task automatic test_gating();
    int edges;
    minhi = 1e9;
    repeat (3) begin
      #7.3 en_i[0] = 0;                              // asynchronous to the output
      #20 check(ck_i[0] == 0, "gated output not low");
      edges = ec[0];
      #100;
      check(ec[0] == edges, $sformatf("%0d edges while gated", ec[0] - edges));
      #3.1 en_i[0] = 1;
      #20 check(ec[0] > edges, "output does not restart");
    end
    check(minhi >= 2.495, $sformatf("short high pulse %0.3f ns (half period 2.5 ns)", minhi));
  endtask

  task automatic test_relock();
    rst_n <= 0;
    repeat (4) @(posedge ref_clk);
    check(!lk_i && !lk_f, "locked_o must drop in reset");
    rst_n <= 1;
    test_lock();
  endtask
