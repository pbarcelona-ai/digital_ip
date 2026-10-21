// ***************
// Filename: frame_buffer.sv
// Author: FPGA Cores 4 U
// Description: Reusable IP. On-chip full-frame pixel store of
//   vision_system, four-way replicated so all four bilinear corner samples
//   (or one row of four bicubic taps) are read in a single clock. Golden
//   model: model/frame_buffer_model.py (tb/python).
//   - Write: wr_en writes wr_data at wr_addr into all four copies.
//   - Read: rd_en reads copy k at rd_addrk; rd_data0..3 are registered
//     (one clock of latency) and hold until the next rd_en. A read of an
//     address written in the same clock returns the old word.
//   - DEPTH words per copy (default MAX_W * MAX_H); addresses must be
//     below DEPTH: vision_system frames are at most DEPTH pixels
//     (IMG_WIDTH * IMG_HEIGHT <= FB_DEPTH).
//   Resources: 4 x DEPTH x PIX_W bits of block RAM (4 x 720 x 720 x 24 =
//   49.8 Mbit at the default, more than most FPGAs hold: hardware builds
//   use small frames or the DDR frame store of
//   docs/ddr_npu_architecture_study.md section 8, which replaces this
//   store with an on-chip row cache).
//   Clock - clk. No reset (memory only). Clock-domain crossings - none.
//   Latency - 1 clock (read). Errors - none (addresses must be < DEPTH).
// Date: 2026-10-21
// =============================================================================
// frame_buffer.sv
//
// Barrel-distortion correction is a global 2-D remap (an output row can,
// in general, need input rows anywhere in the frame), so unlike a simple
// convolution/filter this cannot be done with a handful of line buffers
// -- it needs random access to the whole frame. Replicating the store
// trades memory for one-clock four-sample reads.
// =============================================================================

module frame_buffer #(
  parameter int PIX_W  = barrel_pkg::PIX_W,
  parameter int DEPTH  = barrel_pkg::MAX_W * barrel_pkg::MAX_H,
  parameter int ADDR_W = barrel_pkg::ADDR_W
) (
  input  logic                  clk,         // clock

  input  logic                  wr_en,       // write wr_data at wr_addr (all copies)
  input  logic [ADDR_W-1:0]     wr_addr,     // write address (< DEPTH)
  input  logic [PIX_W-1:0]      wr_data,     // pixel

  input  logic                  rd_en,       // read the four addresses (data the next clock)
  input  logic [ADDR_W-1:0]     rd_addr0,    // read address 0: TL (bilinear) / tap 0 (bicubic row)
  input  logic [ADDR_W-1:0]     rd_addr1,    // read address 1: TR / tap 1
  input  logic [ADDR_W-1:0]     rd_addr2,    // read address 2: BL / tap 2
  input  logic [ADDR_W-1:0]     rd_addr3,    // read address 3: BR / tap 3
  output logic [PIX_W-1:0]      rd_data0,    // pixel at rd_addr0
  output logic [PIX_W-1:0]      rd_data1,    // pixel at rd_addr1
  output logic [PIX_W-1:0]      rd_data2,    // pixel at rd_addr2
  output logic [PIX_W-1:0]      rd_data3    // pixel at rd_addr3
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
