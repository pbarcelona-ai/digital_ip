// ***************
// Filename: crc8.sv
// Author: FPGA Cores 4 U
// Description: CRC-8 (polynomial 0x07, init 0, no reflection). Version
//   1.0.0. Thin wrapper around crc_core with the standard CRC8 parameters
//   as defaults (POLY, INIT, reflection and final XOR are overridable for
//   other 8-bit CRCs). Bytes are consumed little-endian, DATA_W bits per
//   clock, keep_i marks valid bytes of a partial last word. Clock - clk.
//   Reset - synchronous active low, register = INIT. Latency - crc_o
//   updates 1 clock after valid_i. Check value - CRC of the ASCII string
//   123456789 is 0xF4. Errors - invalid widths rejected at elaboration by
//   crc_core.
// Date: 2026-09-29
module crc8 #(
  parameter int DATA_W = 8,
  parameter logic [7:0] POLY   = 8'h07,
  parameter logic [7:0] INIT   = 8'h00,
  parameter bit REFIN  = 1'b0,
  parameter bit REFOUT = 1'b0,
  parameter logic [7:0] XOROUT = 8'h00
) (
  input  logic                 clk,
  input  logic                 rst_n,
  input  logic                 init_i,
  input  logic                 valid_i,
  input  logic [DATA_W-1:0]    data_i,
  input  logic [DATA_W/8-1:0]  keep_i,
  output logic [7:0]           crc_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  crc_core #(.CRC_W(8), .DATA_W(DATA_W), .POLY(POLY), .INIT(INIT), .REFIN(REFIN), .REFOUT(REFOUT), .XOROUT(XOROUT)) u_core (.*);
endmodule
