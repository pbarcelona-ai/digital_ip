// ***************
// Filename: frame_buffer_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of frame_buffer for the comparison with its
//   model (frame_buffer_tb.py): the same ports, DEPTH / ADDR_W passed
//   through (the memories stay below the test's toplevel, which Icarus's
//   VPI needs to exit cleanly). Clock - clk.
// Date: 2026-10-21
module frame_buffer_cocotb_top #(
  parameter int DEPTH  = 256,
  parameter int ADDR_W = 8
) (
  input  logic              clk,
  input  logic              wr_en,
  input  logic [ADDR_W-1:0] wr_addr,
  input  logic [23:0]       wr_data,
  input  logic              rd_en,
  input  logic [ADDR_W-1:0] rd_addr0,
  input  logic [ADDR_W-1:0] rd_addr1,
  input  logic [ADDR_W-1:0] rd_addr2,
  input  logic [ADDR_W-1:0] rd_addr3,
  output logic [23:0]       rd_data0,
  output logic [23:0]       rd_data1,
  output logic [23:0]       rd_data2,
  output logic [23:0]       rd_data3
);
  frame_buffer #(
    .PIX_W(24),
    .DEPTH(DEPTH),
    .ADDR_W(ADDR_W)
  ) u_dut (
    .clk,
    .wr_en,
    .wr_addr,
    .wr_data,
    .rd_en,
    .rd_addr0,
    .rd_addr1,
    .rd_addr2,
    .rd_addr3,
    .rd_data0,
    .rd_data1,
    .rd_data2,
    .rd_data3
  );
endmodule
