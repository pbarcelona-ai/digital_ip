// ***************
// Filename: frame_buffer.sv
// Author: Paul Barcelona
// Description: Reusable IP. Full-frame pixel store, four-way
// replicated so all four bilinear corner samples (or, in
// bicubic/slow-path modes, one row of four taps at a time) can
// be read in a single cycle. Sized to MAX_W*MAX_H; real geometry
// is runtime-programmable.
// Date: September 26, 2026
// ***************
// =============================================================================
// frame_buffer.sv
//
// Full-frame pixel store. Barrel-distortion correction is a global 2-D
// remap (an output row can, in general, need input rows anywhere in the
// frame), so unlike a simple convolution/filter this cannot be done with
// a handful of line buffers -- it needs random access to the whole frame.
//
// To sustain 1 output pixel/clock with 2x2 bilinear interpolation, the
// frame is written into FOUR replicated banks (same data, same write
// address, every write) so all four corner samples (TL/TR/BL/BR) can be
// read in the same cycle, one bank each. This trades memory for
// throughput -- a standard, well-understood technique.
//
// Sized statically to MAX_W*MAX_H (barrel_pkg); actual in-use geometry is
// programmed at runtime via IMG_WIDTH/IMG_HEIGHT (AXI-Lite), so any frame
// up to that compiled-in maximum is supported without re-synthesis.
//
// NOTE for real silicon/FPGA deployment at larger resolutions: replace
// this with an external-DDR frame store plus an on-chip read-ahead /
// tile cache (the correction is *locally* smooth, so a modest windowed
// cache around the predicted source row is sufficient in practice). The
// AXI-Stream/AXI-Lite boundary and coord_gen math are unaffected by that
// change -- only this module would be replaced.
// =============================================================================

module frame_buffer #(
  parameter int PIX_W  = barrel_pkg::PIX_W,
  parameter int DEPTH  = barrel_pkg::MAX_W * barrel_pkg::MAX_H,
  parameter int ADDR_W = barrel_pkg::ADDR_W
) (
  input  logic                  clk,

  input  logic                  wr_en,
  input  logic [ADDR_W-1:0]     wr_addr,
  input  logic [PIX_W-1:0]      wr_data,

  input  logic                  rd_en,
  input  logic [ADDR_W-1:0]     rd_addr0,   // TL
  input  logic [ADDR_W-1:0]     rd_addr1,   // TR
  input  logic [ADDR_W-1:0]     rd_addr2,   // BL
  input  logic [ADDR_W-1:0]     rd_addr3,   // BR
  output logic [PIX_W-1:0]      rd_data0,
  output logic [PIX_W-1:0]      rd_data1,
  output logic [PIX_W-1:0]      rd_data2,
  output logic [PIX_W-1:0]      rd_data3
);

  (* ram_style = "block" *) logic [PIX_W-1:0] bank0 [0:DEPTH-1];
  (* ram_style = "block" *) logic [PIX_W-1:0] bank1 [0:DEPTH-1];
  (* ram_style = "block" *) logic [PIX_W-1:0] bank2 [0:DEPTH-1];
  (* ram_style = "block" *) logic [PIX_W-1:0] bank3 [0:DEPTH-1];

  always_ff @(posedge clk) begin
    if (wr_en) begin
      bank0[wr_addr] <= wr_data;
      bank1[wr_addr] <= wr_data;
      bank2[wr_addr] <= wr_data;
      bank3[wr_addr] <= wr_data;
    end
    if (rd_en) begin
      rd_data0 <= bank0[rd_addr0];
      rd_data1 <= bank1[rd_addr1];
      rd_data2 <= bank2[rd_addr2];
      rd_data3 <= bank3[rd_addr3];
    end
  end

endmodule
