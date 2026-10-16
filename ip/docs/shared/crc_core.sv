// ***************
// Filename: crc_core.sv
// Author: FPGA Cores 4 U
// Description: Generic parameterized CRC engine (shared by crc8, crc16,
//   crc32). Version 1.0.0. Bytes are processed in little-endian order
//   (data_i[7:0] first) DATA_W bits per clock; keep_i marks valid low
//   bytes (contiguous from byte 0) so a final partial word can be
//   included. Parameters follow the Rocksoft model - POLY, INIT, REFIN,
//   REFOUT, XOROUT. init_i reloads INIT. crc_o is the finished CRC
//   (reflection and final XOR applied combinationally to the running
//   register). Clock - clk. Reset - synchronous active low, register =
//   INIT. Latency - crc_o reflects a word 1 clock after valid_i. Timing -
//   DATA_W bit-serial steps unrolled combinationally, use DATA_W=8 for 100
//   MHz on CRC-32. Errors - CRC_W < 8, DATA_W not a multiple of 8 rejected
//   at elaboration.
// Date: 2026-09-29

module crc_core #(
  parameter int CRC_W  = 32,
  parameter int DATA_W = 8,
  parameter logic [CRC_W-1:0] POLY   = 32'h04C1_1DB7,
  parameter logic [CRC_W-1:0] INIT   = 32'hFFFF_FFFF,
  parameter bit REFIN  = 1'b1,
  parameter bit REFOUT = 1'b1,
  parameter logic [CRC_W-1:0] XOROUT = 32'hFFFF_FFFF
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 init_i,
  input  logic                 valid_i,
  input  logic [DATA_W-1:0]    data_i,
  input  logic [DATA_W/8-1:0]  keep_i,
  output logic [CRC_W-1:0]     crc_o
);
