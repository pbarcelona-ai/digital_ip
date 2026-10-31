// ***************
// Filename: npu_lane_mem.sv
// Author: FPGA Cores 4 U
// Description: Lane memory of the NPU engines' row buffers. Version 1.0.0.
//   LANES independent memories of DEPTH entries of W bits; lane i has one
//   write port (we_i[i], waddr_i[i], wdata_i[i], written at the clock edge)
//   and one read port (raddr_i[i] -> rdata_o[i]): asynchronous (REG_RD 0,
//   distributed RAM) or registered (REG_RD 1: the entry the clock after its
//   address, block RAM; a read of the entry written in the same clock
//   returns the old one). A byte
//   array that is read or written many bytes per clock (a 32-byte DMA
//   chunk, a pixel's bytes at any position) is kept as lane i = the bytes
//   at positions i mod LANES, entry = position / LANES: each lane is a
//   plain one-write one-read memory, never one memory with LANES ports.
//   Parameters: LANES, DEPTH, W, REG_RD. Clock - clk. Reset - none (memory
//   contents; every entry is written before it is read). Clock-domain
//   crossings - none.
// Date: 2026-10-26
module npu_lane_mem #(
  parameter int LANES = 32,                      // lanes
  parameter int DEPTH = 64,                      // entries per lane
  parameter int W     = 8,                       // bits per entry
  parameter bit REG_RD = 1'b0                    // registered read (block RAM)
) (
  input  logic                         clk,      // clock
  input  logic [LANES-1:0]             we_i,     // lane i written
  input  logic [LANES-1:0][$clog2(DEPTH)-1:0] waddr_i,   // its entry
  input  logic [LANES-1:0][W-1:0]      wdata_i,  // its data
  input  logic [LANES-1:0][$clog2(DEPTH)-1:0] raddr_i,   // lane i's read entry
  output logic [LANES-1:0][W-1:0]      rdata_o   // its data
);
  for (genvar i = 0; i < LANES; i++) begin : g_lane
    logic [W-1:0] mem [DEPTH];
    always_ff @(posedge clk) begin
      if (we_i[i]) mem[waddr_i[i]] <= wdata_i[i];
    end
    if (REG_RD) begin : g_reg
      always_ff @(posedge clk) rdata_o[i] <= mem[raddr_i[i]];
    end else begin : g_async
      assign rdata_o[i] = mem[raddr_i[i]];
    end
  end
endmodule
