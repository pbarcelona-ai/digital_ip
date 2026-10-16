// ***************
// Filename: axi4_lite_decoder.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Lite address decoder. Version 1.0.0. Purely combinational
//   decode of an address into a one-hot slave select over NSLAVE regions.
//   Region i matches when (addr & MASK[i]) == BASE[i] (MASK selects the
//   compared address bits, so a 4 KB region at 0x1000 uses BASE=0x1000 and
//   MASK=0xFFFFF000). When more than one region matches the lowest index wins
//   and multi_o is raised (a configuration error the parameter check also
//   reports for constant overlaps). No match sets miss_o (unmapped access,
//   the caller returns DECERR). Clock - none (combinational, 0 latency).
//   Reset - none. Timing - one masked compare per region. Errors -
//   overlapping regions rejected at elaboration; NSLAVE < 1 rejected. Latency
//   - 0 clocks (combinational).
// Date: 2026-09-29

module axi4_lite_decoder #(
  parameter int ADDR_W = 32,
  parameter int NSLAVE = 4,
  // defaults describe four 4 KB regions at 0x0000/0x1000/0x2000/0x3000 (NSLAVE=4, ADDR_W=32);
  // override both for any other configuration
  parameter logic [NSLAVE*ADDR_W-1:0] BASE = {32'h0000_3000, 32'h0000_2000, 32'h0000_1000, 32'h0000_0000},
  parameter logic [NSLAVE*ADDR_W-1:0] MASK = {4{32'hFFFF_F000}}
) (
  input  logic [ADDR_W-1:0] addr_i,
  output logic [NSLAVE-1:0] sel_o,
  output logic              miss_o,
  output logic              multi_o
);
