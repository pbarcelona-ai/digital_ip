// ***************
// Filename: csi2_rx_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for csi2_rx with 1, 2 and 4 lanes.
//   Checks the CRC model against the two CSI-2 specification examples, then
//   sends frames of RAW10 lines (lengths that are not multiples of the lane
//   count), an embedded-data packet and a packet on another virtual channel
//   (both must be dropped), a header with a single-bit error (corrected),
//   a header with a double-bit error (dropped, ecc_error), a payload bit
//   error (delivered, crc_error), and repeats with random lane skew and
//   trailing filler bytes. Every delivered line, tuser and the status
//   pulse counts are checked. Prints TEST PASSED on success.
//   The test tasks are in tests/csi2_rx_tests.sv (`included).
// Date: 2026-10-01
`timescale 1ns/1ps
module csi2_rx_tb;
  `define B g_rx[0].drv
  logic clk = 0, rst_n = 0;
  always #4 clk = ~clk;
  int errors = 0;

  // ---------------- three receivers, one per lane count ----------------
  localparam int NCFG = 3;
  localparam int MAXL = 64, MAXB = 128;          // expected lines kept per receiver
  byte unsigned exp_data [NCFG][MAXL][MAXB];
  int  exp_len [NCFG][MAXL];
  bit exp_sof [NCFG][MAXL];
  int  exp_wr [NCFG], exp_rd [NCFG];
  int  cnt_fs [NCFG], cnt_fe [NCFG], cnt_line [NCFG], cnt_corr [NCFG], cnt_err [NCFG], cnt_crc [NCFG], cnt_ovf [NCFG], got [NCFG];

  for (genvar g = 0; g < NCFG; g++) begin : g_rx
    localparam int NL = (g == 0) ? 1 : (g == 1) ? 2 : 4;
    logic [NL*8-1:0] ld;
    logic [NL-1:0] lv;
    logic [NL*8-1:0] td;
    logic [NL-1:0] tk;
    logic tl, tu, tv;
    logic fs, fe, ln, ec, ee, ce, ov;
    csi2_bfm #(.NL(NL)) drv (
      .clk,
      .lane_data(ld),
      .lane_valid(lv)
    );
    csi2_rx #(.NLANES(NL)) dut (
      .clk,
      .rst_n,
      .lane_data_i(ld),
      .lane_valid_i(lv),
      .vc_i(2'd0),
      .dt_i(6'h2B),
      .m_axis_tdata(td),
      .m_axis_tkeep(tk),
      .m_axis_tlast(tl),
      .m_axis_tuser(tu),
      .m_axis_tvalid(tv),
      .m_axis_tready(1'b1),
      .frame_start_o(fs),
      .frame_end_o(fe),
      .line_o(ln),
      .ecc_corrected_o(ec),
      .ecc_error_o(ee),
      .crc_error_o(ce),
      .overflow_o(ov)
    );
    byte unsigned cur [MAXB];
    int ncur = 0;
    bit first_word = 1, cur_sof;
    always @(posedge clk) if (rst_n) begin
      cnt_fs[g] += fs;
      cnt_fe[g] += fe;
      cnt_line[g] += ln;
      cnt_corr[g] += ec;
      cnt_err[g] += ee;
      cnt_crc[g] += ce;
      cnt_ovf[g] += ov;
      if (tv) begin
        if (first_word) begin
          cur_sof = tu;
          first_word = 0;
        end
        else check(!tu, $sformatf("%0d lanes: tuser after the first word of a line", NL));
        for (int i = 0; i < NL; i++) begin
          if (tk[i]) begin
            cur[ncur] = td[8*i +: 8];
            ncur++;
          end
          if (i > 0) check(!(tk[i] && !tk[i-1]), $sformatf("%0d lanes: tkeep not contiguous", NL));
        end
        if (tl) begin
          if (exp_rd[g] == exp_wr[g]) check(0, $sformatf("%0d lanes: unexpected line", NL));
          else begin
            int e;
            e = exp_rd[g] % MAXL;
            exp_rd[g]++;
            check(ncur == exp_len[g][e], $sformatf("%0d lanes: line length %0d exp %0d", NL, ncur, exp_len[g][e]));
            for (int i = 0; i < ncur && i < exp_len[g][e]; i++)
              if (cur[i] != exp_data[g][e][i]) begin
                check(0, $sformatf("%0d lanes: byte %0d = %02h exp %02h", NL, i, cur[i], exp_data[g][e][i]));
                break;
              end
            check(cur_sof == exp_sof[g][e], $sformatf("%0d lanes: tuser %0b exp %0b", NL, cur_sof, exp_sof[g][e]));
          end
          got[g]++;
          ncur = 0;
          first_word = 1;
        end
      end
    end
  end

  // test tasks: tests/csi2_rx_tests.sv
  `include "csi2_rx_tests.sv"

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("csi2_rx_tb.vcd");
      $dumpvars(0, csi2_rx_tb);
    end
    // CSI-2 specification CRC examples
    begin
      logic [191:0] v1, v2;
      logic [15:0] c1;
      v1 = 192'hFF000002B9DCF372BBD4B85AC875C27C81F805DFFF000001;
      v2 = 192'hFF0000001EF01EC74F8278C582E08C70D23C78E9FF000001;
      `B.csi_pay.delete();
      for (int i = 23; i >= 0; i--) `B.csi_pay.push_back(v1[8*i +: 8]);
      c1 = `B.csi_crc();
      `B.csi_pay.delete();
      for (int i = 23; i >= 0; i--) `B.csi_pay.push_back(v2[8*i +: 8]);
      check(c1 == 16'h00F0 && `B.csi_crc() == 16'hE569, "CRC model does not match the CSI-2 specification examples");
    end
    for (int g = 0; g < NCFG; g++) begin
      exp_wr[g] = 0;
      exp_rd[g] = 0;
      cnt_fs[g] = 0;
      cnt_fe[g] = 0;
      cnt_line[g] = 0;
      cnt_corr[g] = 0;
      cnt_err[g] = 0;
      cnt_crc[g] = 0;
      cnt_ovf[g] = 0;
      got[g] = 0;
    end
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);

    for (int g = 0; g < NCFG; g++) begin
      int nl;
      nl = (g == 0) ? 1 : (g == 1) ? 2 : 4;
      set_phy(g, 0, 0);
      frame(g, 5, 0);                     // clean
      frame(g, 4, 1);                     // corrected header
      frame(g, 4, 2);                     // uncorrectable header: line dropped
      frame(g, 4, 3);                     // payload error: crc_error
      set_phy(g, (nl > 1) ? 5 : 0, 3);    // lane skew and trailing filler
      frame(g, 6, 0);
      frame(g, 4, 1);
      repeat (20) @(posedge clk);
      check(exp_rd[g] == exp_wr[g], $sformatf("%0d lanes: %0d lines not received", nl, exp_wr[g] - exp_rd[g]));
      check(cnt_fs[g] == 6 && cnt_fe[g] == 6, $sformatf("%0d lanes: FS %0d FE %0d, exp 6", nl, cnt_fs[g], cnt_fe[g]));
      check(cnt_corr[g] == 2 && cnt_err[g] == 1, $sformatf("%0d lanes: ecc corrected %0d errors %0d, exp 2 / 1", nl, cnt_corr[g], cnt_err[g]));
      check(cnt_crc[g] == 1, $sformatf("%0d lanes: crc errors %0d, exp 1", nl, cnt_crc[g]));
      check(cnt_line[g] == got[g] && cnt_ovf[g] == 0, $sformatf("%0d lanes: line pulses %0d, lines %0d, overflow %0d", nl, cnt_line[g], got[g], cnt_ovf[g]));
      $display("%0d lane(s): %0d lines received, FS/FE %0d/%0d, ECC corrected %0d, ECC errors %0d, CRC errors %0d",
               nl, got[g], cnt_fs[g], cnt_fe[g], cnt_corr[g], cnt_err[g], cnt_crc[g]);
    end
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
