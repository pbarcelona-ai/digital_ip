// ***************
// Filename: clk_gen_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the clk_gen_tb testbench (clk_gen_tb.sv),
//   `included into that module, so they use its signals directly. Tasks,
//   in file order:
//     check          Counts an error and prints the message when the
//                    condition is false
//     test_lock      CPU loop locks first, then the output loop
//     test_frequency Exact long-term frequencies of all five clocks
//     test_alignment Every pixel rising edge is a TMDS and an LVDS rising
//                    edge (serializer clocks phase aligned)
//     test_enable    Output enables stop / restart the byte clock without
//                    short pulses, the other outputs keep running
//     test_reset     arst_n drops both locks at once; both relock
// Date: 2026-10-09
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic test_lock();
    realtime t0 = $realtime, tc = -1, tk = -1;
    while (!clk_locked && $realtime - t0 < 40us) begin
      @(posedge ref_clk);
      if (cpu_locked && tc < 0) tc = $realtime - t0;
      check(!(clk_locked && !cpu_locked), "output loop locked before the CPU loop");
    end
    tk = $realtime - t0;
    check(cpu_locked && clk_locked, "no lock within 40 us");
    $display("[%0t] CPU loop locked after %0.2f us, output loop after %0.2f us", $time, tc / 1000.0, tk / 1000.0);
  endtask

  task automatic test_frequency();
    localparam int NREF = 2000;                      // 60 us
    int c[5];
    // edges per reference cycle: CPU 6, core 3, TMDS 30, LVDS 21, byte 3.75
    int exp[5] = '{NREF * 6, NREF * 3, NREF * 30, NREF * 21, NREF * 15 / 4};
    @(posedge ref_clk);
    c = ec;
    repeat (NREF) @(posedge ref_clk);
    for (int k = 0; k < 5; k++) begin
      c[k] = ec[k] - c[k];
      check(c[k] >= exp[k] - 1 && c[k] <= exp[k] + 1,
            $sformatf("clock %0d: %0d edges in %0d reference cycles, expected %0d", k, c[k], NREF, exp[k]));
      $display("clock %0d: %0d edges in %0d reference cycles (expected %0d)", k, c[k], NREF, exp[k]);
    end
    check(cpu_locked && clk_locked, "lock lost during the frequency check");
  endtask

  task automatic test_alignment();
    realtime tp;
    int bad = 0;
    repeat (300) begin
      @(posedge ck[0]);
      tp = $realtime;
      #0.001;
      if (t_tmds != tp || t_lvds != tp) bad++;
    end
    check(bad == 0, $sformatf("%0d of 300 pixel edges without coincident TMDS / LVDS edges", bad));
  endtask

  task automatic test_enable();
    int e3, e1;
    minhi = 1e9;
    repeat (3) begin
      @(posedge cpu_clk);
      #1.3 en[3] = 0;                                // asynchronous to the byte clock
      #10;
      e3 = ec[4];
      e1 = ec[1];
      #200;
      check(ec[4] == e3, $sformatf("byte clock: %0d edges while disabled", ec[4] - e3));
      check(ck[3] == 0, "disabled byte clock not low");
      check(ec[1] > e1, "pixel clock stopped with the byte clock");
      en[3] = 1;
      #40 check(ec[4] > e3, "byte clock does not restart");
    end
    check(minhi >= 3.995, $sformatf("byte clock: short high pulse %0.3f ns (half period 4 ns)", minhi));
  endtask

  task automatic test_reset();
    arst_n = 0;
    #1 check(!cpu_locked && !clk_locked, "locks must drop at once on arst_n");
    #100 arst_n = 1;
    test_lock();
  endtask
