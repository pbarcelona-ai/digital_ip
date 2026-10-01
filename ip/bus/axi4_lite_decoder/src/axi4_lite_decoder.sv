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
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (NSLAVE < 1) begin : g_bn $error("axi4_lite_decoder: NSLAVE must be >= 1"); end
  // constant overlap check: two regions overlap when their bases agree on the bits both masks compare
  for (genvar i = 0; i < NSLAVE; i++) begin : g_ci
    for (genvar j = i + 1; j < NSLAVE; j++) begin : g_cj
      if (((BASE[i*ADDR_W +: ADDR_W] ^ BASE[j*ADDR_W +: ADDR_W]) & MASK[i*ADDR_W +: ADDR_W] & MASK[j*ADDR_W +: ADDR_W]) == '0) begin : g_ov
        $error("axi4_lite_decoder: regions %0d and %0d overlap", i, j);
      end
    end
  end
  logic [NSLAVE-1:0] hit;
  always_comb begin
    for (int i = 0; i < NSLAVE; i++) hit[i] = ((addr_i & MASK[i*ADDR_W +: ADDR_W]) == BASE[i*ADDR_W +: ADDR_W]);
    sel_o = '0;
    for (int i = NSLAVE-1; i >= 0; i--) if (hit[i]) begin sel_o = '0; sel_o[i] = 1'b1; end
  end
  assign miss_o  = ~|hit;
  assign multi_o = ($countones(hit) > 1);
endmodule
