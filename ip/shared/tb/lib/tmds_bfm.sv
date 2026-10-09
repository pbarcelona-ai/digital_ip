// ***************
// Filename: tmds_bfm.sv
// Author: FPGA Cores 4 U
// Description: TMDS (DVI / HDMI) serial link receiver bus functional
//   model: the physical layer in front of hdmi_bfm. Deserialises the three
//   data channels and the clock channel (lanes[3]) on the serial bit clock,
//   LSB first, and aligns on the clock channel symbol 0000011111. Every
//   aligned 10-bit period gives one symbol per channel on ch0 / ch1 / ch2
//   and in sym_q ({ch2, ch1, ch0}; syms, sym_done); a clock channel
//   symbol other than 0000011111 one period after the previous one counts
//   as clk_errors. sym_clk is a recovered symbol clock (high in the middle
//   of each symbol period) for a symbol level decoder such as hdmi_bfm;
//   locked goes high after LOCK_SYMS aligned symbols.
// Date: 2026-10-09
`timescale 1ns/1ps

module tmds_bfm #(
  parameter int LOCK_SYMS = 20                // aligned symbols before locked
) (
  input  logic       ser_clk,                 // serial bit clock (10x the pixel clock)
  input  logic [3:0] lanes,                   // ch0, ch1, ch2, clock channel
  output logic [9:0] ch0,
  output logic [9:0] ch1,
  output logic [9:0] ch2,
  output logic       sym_clk,
  output logic       locked
);
  logic [9:0]  sr [4];
  logic [29:0] sym_q[$];
  int          syms = 0, clk_errors = 0, since = -1;
  event        sym_done;
  initial begin
    for (int c = 0; c < 4; c++) sr[c] = '0;
    ch0 = '0;
    ch1 = '0;
    ch2 = '0;
    sym_clk = 0;
    locked = 0;
  end

  always @(posedge ser_clk) begin
    for (int c = 0; c < 4; c++) sr[c] = {lanes[c], sr[c][9:1]};
    if (since >= 0) since++;
    if (sr[3] == 10'b0000011111) begin
      ch0 <= sr[0];
      ch1 <= sr[1];
      ch2 <= sr[2];
      sym_q.push_back({sr[2], sr[1], sr[0]});
      syms++;
      since = 0;
      locked <= (syms > LOCK_SYMS);
      -> sym_done;
    end else if (since == 10) begin
      clk_errors++;                           // no clock symbol one period after the last one
      since = -1;
    end
    sym_clk <= (since >= 4 && since < 9);
  end
endmodule
