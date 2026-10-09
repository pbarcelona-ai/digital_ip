// ***************
// Filename: dsi_tx_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the dsi_tx_tb testbench (dsi_tx_tb.sv), moved
//   out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check      Counts an error and prints the message when the condition is
//                false
//     send_cmd
//     check_log  Check one receiver's log from packet index p0
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  task automatic send_cmd(input bit lng, input logic [7:0] dt, input logic [15:0] d, input int nbytes, input logic [7:0] base);
    for (int i = 0; i < nbytes; i++) begin @(posedge pclk); bwr <= 1; cb <= 8'(base + i); end
    @(posedge pclk); bwr <= 0; cwr <= 1; cmd <= {lng, dt, d};
    @(posedge pclk); cwr <= 0;
  endtask

  // Check one receiver's log from packet index p0
  task automatic check_log(input int g, input int nl, input int npk, input int p0, input int frames);
    int p, burst_syncs, pix_lines, vss, f0, last_sync; realtime tprev; bit seen_vss;
    // ---- commands: 05 / 15 short, 39 long, each followed by EoTp in its burst
    begin
      logic [5:0] dts [6]; dts = '{6'h05, 6'h08, 6'h15, 6'h08, 6'h39, 6'h08};
      for (int k = 0; k < 6; k++) check(g_dt(g, k) == dts[k], $sformatf("%0d lanes: command packet %0d DT %02h exp %02h", nl, k, g_dt(g, k), dts[k]));
      check(g_data(g, 0) == 16'h0011 && g_data(g, 2) == 16'hA536 && g_data(g, 4) == 16'd5, $sformatf("%0d lanes: command data", nl));
      for (int k = 0; k < 5; k++) check(g_pay(g, g_off(g, 4) + k) == 8'(8'h70 + k), $sformatf("%0d lanes: DCS long byte %0d", nl, k));
    end
    // ---- video
    vss = 0; pix_lines = 0; seen_vss = 0; tprev = 0; last_sync = -1;
    for (p = p0; p < npk; p++) begin
      logic [5:0] dt; dt = g_dt(g, p);
      if (dt == 6'h01 || dt == 6'h21) begin
        if (dt == 6'h01) begin
          if (seen_vss) check(burst_syncs == VTOT, $sformatf("%0d lanes: %0d sync packets in a frame, exp %0d", nl, burst_syncs, VTOT));
          vss++; seen_vss = 1; burst_syncs = 0;
        end
        if (tprev != 0) check(g_t(g, p) - tprev > HTOT * 10 - 80 && g_t(g, p) - tprev < HTOT * 10 + 80,
                              $sformatf("%0d lanes: sync packets %0t ns apart, line is %0d ns", nl, g_t(g, p) - tprev, HTOT * 10));
        tprev = g_t(g, p); burst_syncs++; last_sync = p;
      end else if (dt == 6'h3E && !seen_vss) begin
        // video was enabled in the middle of a frame: lines before the first VSS are partial
      end else if (dt == 6'h3E) begin
        int f, ly, bad; logic [7:0] gb;
        check(last_sync == p - 2 && g_dt(g, p - 1) == 6'h08, $sformatf("%0d lanes: pixel packet not in a line slot", nl));
        check(g_data(g, p) == 3 * HA, $sformatf("%0d lanes: pixel packet WC %0d", nl, g_data(g, p)));
        gb = g_pay(g, g_off(g, p) + 1); f = gb / 16; ly = gb % 16;
        bad = -1;
        for (int i = 0; i < 3 * HA; i++) begin
          logic [23:0] e; logic [7:0] eb; e = pix(i / 3, ly, f);
          eb = (i % 3 == 0) ? e[7:0] : (i % 3 == 1) ? e[15:8] : e[23:16];
          if (bad < 0 && g_pay(g, g_off(g, p) + i) != eb) bad = i;
        end
        check(bad < 0, $sformatf("%0d lanes: frame %0d line %0d byte %0d differs", nl, f, ly, bad));
        check(ly == pix_lines % VA, $sformatf("%0d lanes: line %0d out of order (exp %0d)", nl, ly, pix_lines % VA));
        pix_lines++;
      end else if (dt != 6'h08) check(0, $sformatf("%0d lanes: unexpected DT %02h in video", nl, dt));
    end
    check(vss >= frames, $sformatf("%0d lanes: %0d VSS packets, exp >= %0d", nl, vss, frames));
    check(pix_lines >= (frames - 1) * VA, $sformatf("%0d lanes: %0d pixel lines", nl, pix_lines));
    $display("%0d lane(s): commands ok, %0d frames with VSS / HSS per line, %0d pixel lines matched", nl, vss, pix_lines);
  endtask
