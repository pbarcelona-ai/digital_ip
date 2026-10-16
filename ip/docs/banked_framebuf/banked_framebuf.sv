// ***************
// Filename: banked_framebuf.sv
// Author: FPGA Cores 4 U
// Description: Frame store with a TAPSxTAPS window read per clock.
//   The image is split over B x B RAM banks (B = next power of two >=
//   TAPS). Pixel (x,y) lives in bank (y mod B, x mod B) at address
//   (y div B)*BW + (x div B), so any B consecutive rows/columns hit B
//   different banks and a whole window needs one access per bank.
//   Edges are clamp-to-edge. The clamped taps of a window still form a
//   contiguous range of <= TAPS coordinates, so the clamped window is
//   also conflict free.
//   Read pipeline (registers advance only when rd_adv = 1):
//     stage A : per-bank addresses and tap->bank selects registered
//     stage B : RAM read data registered
//     rd_win  : combinational tap mux from the stage-B registers
//   rd_win therefore belongs to the rd_x0/rd_y0 given two rd_adv cycles
//   earlier. Tap (row j, column i) is rd_win[((j*TAPS)+i)*PIX_W +: PIX_W].
//   Write port: one pixel per clock at (wr_x, wr_y).
//   NBUF = 2 keeps two independent frames (wr_buf / rd_buf select them) for
//   ping-pong operation. RING > 0 turns the store into a line buffer of RING
//   rows: image row y is kept in slot y % RING (RING a power of two >= B, so
//   the bank of a row does not change), coordinates stay logical and are
//   still clamped against img_h; the caller guarantees that a row is not
//   read after it has been overwritten.
// Date: 2026-09-26

module banked_framebuf #(
  parameter int PIX_W = 24,     // bits per pixel
  parameter int TAPS  = 4,      // window size (TAPS x TAPS)
  parameter int MAX_W = 1920,   // largest image width stored
  parameter int MAX_H = 1080,   // largest image height stored
  parameter int NBUF  = 1,      // 1 or 2 independent frame buffers
  parameter int RING  = 0       // > 0: store only RING rows (power of 2,
                                //   >= bank count); row y lives in slot y % RING
)(
  input  logic                         clk,
  // write port (one pixel per clock)
  input  logic                         wr_en,   // write strobe
  input  logic [15:0]                  wr_x,    // pixel column
  input  logic [15:0]                  wr_y,    // pixel row
  input  logic [PIX_W-1:0]             wr_data, // pixel value
  input  logic                         wr_buf,  // buffer written (NBUF = 2)
  // window read port
  input  logic                         rd_adv,  // advance read pipeline
  input  logic                         rd_buf,  // buffer read (NBUF = 2)
  input  logic signed [17:0]           rd_x0,   // left column of window
  input  logic signed [17:0]           rd_y0,   // top row of window
  input  logic [15:0]                  img_w,   // valid image size (>= 1)
  input  logic [15:0]                  img_h,
  output logic [TAPS*TAPS*PIX_W-1:0]   rd_win   // window, row-major taps
);
