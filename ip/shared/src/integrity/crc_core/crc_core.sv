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
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (CRC_W < 8) begin : g_bw $error("crc_core: CRC_W must be >= 8"); end
  if (DATA_W < 8 || (DATA_W % 8) != 0) begin : g_bd $error("crc_core: DATA_W must be a multiple of 8"); end
  function automatic logic [CRC_W-1:0] byte_step(input logic [CRC_W-1:0] c, input logic [7:0] b);
    logic [CRC_W-1:0] r; logic [7:0] bb; logic fb;
    r = c;
    for (int i = 0; i < 8; i++) bb[i] = REFIN ? b[7-i] : b[i];        // bb[7] is processed first
    for (int i = 7; i >= 0; i--) begin
      fb = r[CRC_W-1] ^ bb[i];
      r = {r[CRC_W-2:0], 1'b0};
      if (fb) r = r ^ POLY;
    end
    byte_step = r;
  endfunction
  logic [CRC_W-1:0] crc_r, nxt;
  always_comb begin
    nxt = crc_r;
    for (int b = 0; b < DATA_W/8; b++) if (keep_i[b]) nxt = byte_step(nxt, data_i[b*8 +: 8]);
  end
  always_ff @(posedge clk) begin
    if (!rst_n || init_i) crc_r <= INIT;
    else if (valid_i) crc_r <= nxt;
  end
  logic [CRC_W-1:0] refl;
  always_comb for (int i = 0; i < CRC_W; i++) refl[i] = crc_r[CRC_W-1-i];
  assign crc_o = (REFOUT ? refl : crc_r) ^ XOROUT;
endmodule
