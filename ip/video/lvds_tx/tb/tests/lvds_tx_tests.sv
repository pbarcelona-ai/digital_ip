// ***************
// Filename: lvds_tx_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the lvds_tx_tb testbench (lvds_tx_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check  Counts an error and prints the message when the condition is
//            false
//     take   Rebuild frames from the decoded stream
//     mode
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  // Rebuild frames from the decoded stream
  task automatic take(input logic [26:0] d);
    if (d[25] && !vs_prev) begin                        // vsync leading edge: frame done
      if (de_seen) begin check(nlines == VA, $sformatf("frame with %0d lines", nlines)); nframes++; end
      nlines = 0; ly = 0;
    end
    vs_prev = d[25];
    if (d[24]) begin
      logic [23:0] e, m; int f;
      f = int'(d[15:10]);                               // frame number from G[7:2]
      e = pix(lx, ly, f);
      m = b18 ? 24'hFCFCFC : 24'hFFFFFF;
      check((d[23:0] & m) == (e & m), $sformatf("%s pixel (%0d,%0d) = %h exp %h", dual ? "dual" : "single", lx, ly, d[23:0] & m, e & m));
      lx++; npix++; de_seen = 1;
    end else if (lx != 0) begin
      check(lx == HA, $sformatf("line of %0d pixels", lx));
      lx = 0; ly++; nlines++;
    end
  endtask

  task automatic mode(input bit d2, input bit bb, input bit jj, input string name);
    dual = d2; b18 = bb; jei = jj;
    lx = 0; ly = 0; npix = 0; nlines = 0; nframes = 0; de_seen = 0; vs_prev = 1;
    repeat (4) @(posedge vs);
    repeat (5) @(posedge clk);
    check(nframes >= 2, $sformatf("%s: %0d complete frames", name, nframes));
    $display("%s: %0d frames of %0dx%0d decoded", name, nframes, HA, VA);
  endtask
