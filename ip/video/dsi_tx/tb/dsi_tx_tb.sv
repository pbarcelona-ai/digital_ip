// ***************
// Filename: dsi_tx_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for dsi_tx on 1, 2 and 4 lanes, each
//   decoded by dsi_bfm (header ECC and checksum checked on every
//   packet). Commands: with video off, DCS short writes (0x05, 0x15) and a
//   DCS long write (0x39) must arrive intact, each followed by EoTp. Video:
//   per frame exactly one VSS, every other line an HSS, sync bursts spaced
//   by the line period, and one RGB888 (0x3E) pixel packet per active line
//   whose bytes (R, G, B) equal the source line, in order, each in the
//   line slot after its sync packet. The PHY model has a fixed 6-clock
//   start-of-transmission time, so sync packets must follow the line period
//   to within the clock-crossing uncertainty. Prints TEST PASSED on success.
//   The test tasks are in tests/dsi_tx_tests.sv (`included).
// Date: 2026-10-02
`timescale 1ns/1ps
module dsi_tx_tb;
  logic pclk = 0, bclk = 0, prst_n = 0, brst_n = 0;
  always #5 pclk = ~pclk;
  always #4 bclk = ~bclk;
  int errors = 0;
  initial begin
    #5ms;
    $display("ERROR: simulation timeout");
    $display("TEST FAILED");
    $finish;
  end

  localparam int HA = 32, VA = 8, HTOT = 200, VTOT = 8 + 2 + 2 + 3;
  logic ven = 0, cwr = 0, bwr = 0;
  logic [24:0] cmd = '0;
  logic [7:0] cb = '0;
  logic de, hs, vs, sof, eol, vbl, wt;
  logic [15:0] x, y;
  vid_timing_gen u_vtg (
    .clk(pclk),
    .rst_n(prst_n),
    .enable_i(1'b1),
    .h_active_i(16'(HA)),
    .h_fp_i(16'd8),
    .h_sync_i(16'd8),
    .h_bp_i(16'(HTOT - HA - 16)),
    .v_active_i(16'(VA)),
    .v_fp_i(16'd2),
    .v_sync_i(16'd2),
    .v_bp_i(16'd3),
    .hs_pol_i(1'b0),
    .vs_pol_i(1'b0),
    .lock_en_i(1'b0),
    .src_ready_i(1'b1),
    .lock_max_i(16'd0),
    .de_o(de),
    .hs_o(hs),
    .vs_o(vs),
    .x_o(x),
    .y_o(y),
    .sof_o(sof),
    .eol_o(eol),
    .vblank_o(vbl),
    .waiting_o(wt)
  );
  int fcount = 0;
  logic vs_q = 1;
  always @(posedge pclk) begin
    vs_q <= vs;
    if (!vs && vs_q) fcount <= fcount + 1;
  end
  function automatic logic [23:0] pix(input int px, input int py, input int f);
    return {8'(px * 3 + py), 8'(f * 16 + py), 8'(px ^ 8'h5A)};          // {B, G, R}
  endfunction
  wire [23:0] rgb = de ? pix(x, y, fcount) : 24'h0;

  for (genvar g = 0; g < 3; g++) begin : g_l
    localparam int NL = (g == 0) ? 1 : (g == 1) ? 2 : 4;
    logic [NL*8-1:0] ld;
    logic [NL-1:0] lv;
    logic req, rdy = 0, drop, uf, busy;
    dsi_tx #(.NLANES(NL), .MAX_W(64)) dut (
      .pclk,
      .prst_n,
      .video_en_i(ven),
      .hs_pol_i(1'b0),
      .vs_pol_i(1'b0),
      .rgb_i(rgb),
      .de_i(de),
      .hs_i(hs),
      .vs_i(vs),
      .cmd_wr_i(cwr),
      .cmd_i(cmd),
      .cmd_byte_wr_i(bwr),
      .cmd_byte_i(cb),
      .line_drop_o(drop),
      .bclk,
      .brst_n,
      .vc_i(2'd0),
      .eotp_i(1'b1),
      .sync_gap_i(16'd10),
      .line_gap_i(16'd6),
      .lane_data_o(ld),
      .lane_valid_o(lv),
      .hs_req_o(req),
      .tx_ready_i(rdy),
      .cmd_busy_o(busy),
      .underflow_o(uf)
    );
    // PHY: a fixed start-of-transmission time of 6 byte clocks, as a D-PHY has
    int sot = 0;
    always @(posedge bclk) begin
      if (!req) begin
        rdy <= 1'b0;
        sot = 0;
      end
      else if (!rdy) begin
        sot++;
        if (sot == 6) rdy <= 1'b1;
      end
      if (brst_n) check(!uf, $sformatf("%0d lanes: engine underflow", NL));
    end
    always @(posedge pclk) if (prst_n) check(!drop, $sformatf("%0d lanes: line dropped", NL));
    dsi_bfm #(.NL(NL)) rx (
      .clk(bclk),
      .lane_data(ld),
      .lane_valid(lv)
    );
  end

  // test tasks: tests/dsi_tx_tests.sv
  `include "dsi_tx_tests.sv"

  // Accessors into the three receiver models
  function automatic logic [5:0] g_dt(input int g, input int p);
    return (g == 0) ? g_l[0].rx.log_dt[p] : (g == 1) ? g_l[1].rx.log_dt[p] : g_l[2].rx.log_dt[p];
  endfunction
  function automatic logic [15:0] g_data(input int g, input int p);
    return (g == 0) ? g_l[0].rx.log_data[p] : (g == 1) ? g_l[1].rx.log_data[p] : g_l[2].rx.log_data[p];
  endfunction
  function automatic int g_off(input int g, input int p);
    return (g == 0) ? g_l[0].rx.log_off[p] : (g == 1) ? g_l[1].rx.log_off[p] : g_l[2].rx.log_off[p];
  endfunction
  function automatic realtime g_t(input int g, input int p);
    return (g == 0) ? g_l[0].rx.log_t[p] : (g == 1) ? g_l[1].rx.log_t[p] : g_l[2].rx.log_t[p];
  endfunction
  function automatic logic [7:0] g_pay(input int g, input int i);
    return (g == 0) ? g_l[0].rx.pay[i] : (g == 1) ? g_l[1].rx.pay[i] : g_l[2].rx.pay[i];
  endfunction

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("dsi_tx_tb.vcd");
      $dumpvars(0, dsi_tx_tb);
    end
    repeat (5) @(posedge pclk);
    prst_n = 1;
    brst_n = 1;
    repeat (20) @(posedge pclk);
    // panel initialisation with video off
    send_cmd(0, 8'h05, 16'h0011, 0, 0);            // DCS short write: exit sleep
    send_cmd(0, 8'h15, 16'hA536, 0, 0);            // DCS short write 1 parameter: MADCTL = 0xA5
    send_cmd(1, 8'h39, 16'd5, 5, 8'h70);           // DCS long write, 5 bytes
    repeat (3000) @(posedge pclk);
    ven = 1;
    repeat (4) @(posedge vs);                     // 4 frame starts (vs active low: edges both ways)
    repeat (4) begin
      wait (!vs);
      wait (vs);
    end
    repeat (2 * HTOT) @(posedge pclk);
    check_log(0, 1, g_l[0].rx.npk, 6, 4);
    check_log(1, 2, g_l[1].rx.npk, 6, 4);
    check_log(2, 4, g_l[2].rx.npk, 6, 4);
    errors += g_l[0].rx.errors + g_l[1].rx.errors + g_l[2].rx.errors;
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
