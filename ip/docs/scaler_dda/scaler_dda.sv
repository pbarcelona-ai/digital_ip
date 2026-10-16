// ***************
// Filename: scaler_dda.sv
// Author: FPGA Cores 4 U
// Description: Output raster scan / source coordinate generator.
//   Scans the output image in raster order and produces, for every output
//   pixel, the source coordinate in signed 16.16 fixed point:
//     src_x(ox) = OFFS_X + ox * STEP_X
//     src_y(oy) = OFFS_Y + oy * STEP_Y
//   The products are replaced by exact accumulation (a digital
//   differential analyser), so hardware and reference models agree bit
//   for bit. Also outputs SOF / EOL / EOF flags. Outputs are registered
//   and only advance when adv = 1, so the block can head a stall-able
//   pipeline. 'start' re-initialises the scan for a new frame. 'hold'
//   inserts bubbles without advancing the scan; nxt_y exposes the source
//   y of the next pixel (used for line-buffer flow control).
// Date: 2026-09-26

module scaler_dda (
  input  logic               clk,
  input  logic               rst_n,      // async reset, active low
  input  logic               start,      // 1-cycle pulse: begin a new frame
  input  logic               adv,        // pipeline advance
  input  logic               hold,       // 1: emit a bubble instead of a pixel
  input  logic [15:0]        out_w,      // output width  (pixels)
  input  logic [15:0]        out_h,      // output height (lines)
  input  logic [31:0]        step_x,     // unsigned 16.16
  input  logic [31:0]        step_y,     // unsigned 16.16
  input  logic signed [31:0] offs_x,     // signed 16.16
  input  logic signed [31:0] offs_y,     // signed 16.16
  output logic               busy,       // pixels left to issue
  output logic signed [31:0] nxt_y,      // source y of the next pixel to emit
  output logic               o_valid,    // o_* hold a valid pixel
  output logic signed [31:0] o_x,        // source x, signed 16.16
  output logic signed [31:0] o_y,        // source y, signed 16.16
  output logic               o_sof,      // first pixel of frame
  output logic               o_eol,      // last pixel of a line
  output logic               o_eof       // last pixel of frame
);
