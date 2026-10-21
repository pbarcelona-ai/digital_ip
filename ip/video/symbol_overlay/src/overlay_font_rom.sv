// ***************
// Filename: overlay_font_rom.sv
// Author: FPGA Cores 4 U
// Description: symbol_overlay's smooth-font ROM: DEPTH words of W bits (one
//   glyph row each, the leftmost pixel's 4-bit coverage in the top nibble)
//   from the hex file FILE (src/include/overlay_font_aa_s<S>.mem, written by
//   scripts/make_aa_font.py), two read ports (labels and texts). Contents -
//   loaded with $readmemh at elaboration (block RAM / LUT ROM initial
//   values); an empty FILE leaves the ROM at zero (no smooth font). Clock -
//   clk; each port's output register loads when its enable is high (one
//   clock of latency). Reset - none (a ROM; the outputs follow the address
//   one clock later).
// Date: 2026-10-20
module overlay_font_rom #(
  parameter int    W     = 32,
  parameter int    DEPTH = 1140,
  parameter        FILE  = ""          // untyped: Icarus string parameters
) (
  input  logic                     clk,
  input  logic                     en_a,
  input  logic [$clog2(DEPTH)-1:0] addr_a,
  output logic [W-1:0]             data_a,
  input  logic                     en_b,
  input  logic [$clog2(DEPTH)-1:0] addr_b,
  output logic [W-1:0]             data_b
);
  logic [W-1:0] mem [DEPTH];
  // ROM contents (synthesis: initial values of the inferred memory)
  initial begin
    for (int i = 0; i < DEPTH; i++) mem[i] = '0;
    if (FILE != "") $readmemh(FILE, mem);
  end
  // addresses past DEPTH read zero
  always_ff @(posedge clk) begin
    if (en_a) data_a <= (int'(addr_a) < DEPTH) ? mem[addr_a] : '0;
    if (en_b) data_b <= (int'(addr_b) < DEPTH) ? mem[addr_b] : '0;
  end
endmodule
