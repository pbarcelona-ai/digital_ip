// ***************
// Filename: checksum.sv
// Author: FPGA Cores 4 U
// Description: Configurable byte-stream checksum. Version 1.0.0. MODE 0 is
//   an 8-bit two's-complement sum (the sum of all bytes plus the checksum
//   is 0 mod 256), MODE 1 is the RFC 1071 Internet checksum (16-bit one's
//   complement sum of big-endian byte pairs, inverted; an odd final byte
//   is padded with zero), MODE 2 is Fletcher-16 (two running sums modulo
//   255). One byte is consumed per clock when valid_i is high; init_i
//   clears the state. checksum_o always reflects the bytes consumed so far
//   (a pending odd Internet byte is padded on the fly), so no flush is
//   needed. ok_o is high when the stream seen so far includes its own
//   checksum and the total verifies (Internet result 0xFFFF sum / SUM8
//   zero / Fletcher-16 both sums zero). Clock - clk. Reset - synchronous
//   active low, empty state. Latency - checksum_o valid 1 clock after the
//   last byte. Errors - MODE outside 0..2 rejected at elaboration.
// Date: 2026-09-29

module checksum #(
  parameter int MODE = 1
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        init_i,
  input  logic        valid_i,
  input  logic [7:0]  byte_i,
  output logic [15:0] checksum_o,
  output logic        ok_o
);
