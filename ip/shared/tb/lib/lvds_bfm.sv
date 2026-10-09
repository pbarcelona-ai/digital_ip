// ***************
// Filename: lvds_bfm.sv
// Author: FPGA Cores 4 U
// Description: LVDS (FPD-Link / OpenLDI, 7:1) receiver bus functional
//   model. Deserialises NDATA data lanes plus the clock lane (lane NDATA)
//   on the serial bit clock, bit 6 first, and aligns on the clock lane
//   word 1100011. Every aligned 7-bit period gives one 28-bit word
//   {lane3, lane2, lane1, lane0} (word, word_q, words, word_done); a clock
//   lane word other than 1100011 one period after the previous one counts
//   as clk_errors. With decode = 1 the words are decoded as single-link
//   VESA 24 bpp (r = {l3[1:0], l0[5:0]}, g = {l3[3:2], l1[4:0], l0[6]},
//   b = {l3[5:4], l2[3:0], l1[6:5]}, hsync l2[4], vsync l2[5], de l2[6])
//   into frame[MAXH][MAXW] ({b, g, r}): a vsync rising edge starts a
//   frame, the end of every data enable run ends a line (line_done), the
//   height-th line completes a frame (frame_done; frames counts complete
//   frames at the next vsync). Decoding starts after LOCK_WORDS aligned
//   words.
// Date: 2026-10-09
`timescale 1ns/1ps

module lvds_bfm #(
  parameter int NDATA      = 4,               // data lanes (lane NDATA is the clock lane)
  parameter int MAXW       = 64,
  parameter int MAXH       = 32,
  parameter int LOCK_WORDS = 20               // aligned words before decoding starts
) (
  input  logic             ser_clk,           // serial bit clock (7x the pixel clock)
  input  logic [NDATA:0]   lanes              // serial lanes, [NDATA] = clock lane
);
  bit          decode = 1;                    // VESA 24 bpp pixel decode
  // word level
  logic [6:0]  sr [NDATA + 1];
  logic [27:0] word;
  logic [27:0] word_q[$];
  int          words = 0, clk_errors = 0, since = -1;
  event        word_done;
  // pixel level
  logic [23:0] frame [MAXH][MAXW];
  int          height = MAXH;                // lines per frame
  int          x = 0, y = 0, frames = 0;
  bit          vs_q = 0;
  event        line_done, frame_done;
  initial for (int c = 0; c <= NDATA; c++) sr[c] = '0;

  always @(posedge ser_clk) begin
    for (int c = 0; c <= NDATA; c++) sr[c] = {sr[c][5:0], lanes[c]};
    if (since >= 0) since++;
    if (sr[NDATA] == 7'b1100011) begin
      word = '0;
      for (int c = 0; c < NDATA && c < 4; c++) word[7*c +: 7] = sr[c];
      word_q.push_back(word);
      words++;
      since = 0;
      -> word_done;
      if (decode && words > LOCK_WORDS) pixel(word);
    end else if (since == 7) begin
      clk_errors++;                           // no clock word one period after the last one
      since = -1;
    end
  end

  task automatic pixel(input logic [27:0] w);
    logic [6:0] l0, l1, l2, l3;
    logic [7:0] r, g, b;
    l0 = w[6:0];
    l1 = w[13:7];
    l2 = w[20:14];
    l3 = w[27:21];
    r = {l3[1], l3[0], l0[5:0]};
    g = {l3[3], l3[2], l1[4:0], l0[6]};
    b = {l3[5], l3[4], l2[3:0], l1[6:5]};
    if (l2[5] && !vs_q) begin                 // vsync rising edge: a new frame
      if (y == height) frames++;
      y = 0;
      x = 0;
    end
    vs_q = l2[5];
    if (l2[6]) begin
      if (y < MAXH && x < MAXW) frame[y][x] = {b, g, r};
      x++;
    end else if (x != 0) begin
      x = 0;
      y++;
      -> line_done;
      if (y == height) -> frame_done;
    end
  endtask
endmodule
