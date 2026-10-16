// ***************
// Filename: fb_wr_if.sv
// Author: FPGA Cores 4 U
// Description: Frame-store write port by coordinates: one pixel per clock at (x, y), as a capture
//   block (scaler_ctrl) drives a frame store (banked_framebuf). Modules take widths as parameters
//   (no $bits on interface members: Icarus); connect a port with the plain instance name
//   (.p(u_if)). A top-level module for synthesis keeps discrete ports (ip/scripts/syn_wrap.py
//   writes the wrapper).
// Date: 2026-10-16
interface fb_wr_if #(
  parameter int PIX_W = 24
) ();
  logic en;                             // write strobe
  logic [15:0] x;                       // pixel column
  logic [15:0] y;                       // pixel row
  logic [PIX_W-1:0] data;               // pixel
  logic buf_sel;                        // buffer written (two-buffer stores)
  // PIX_W: pixel width
  // width PIX_W = data

  modport source (output en, x, y, data, buf_sel);
  modport store (input en, x, y, data, buf_sel);
  modport monitor (input en, x, y, data, buf_sel);
endinterface
