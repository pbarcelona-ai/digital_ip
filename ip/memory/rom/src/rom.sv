// ***************
// Filename: rom.sv
// Author: FPGA Cores 4 U
// Description: Parameterized synchronous ROM. Version 1.0.0. Contents come
//   from INIT_FILE (hex text read with $readmemh, one word per line) or,
//   when INIT_FILE is empty, from a deterministic built-in pattern (word
//   index XOR 32'hA5A5_5A5A truncated to WIDTH) so the module is testable
//   without files. Clock - clk. Reset - output register resets
//   synchronously (active low) to zero. Latency - data valid one clock
//   after addr_i with en_i. Errors - out-of-range addresses cannot occur
//   (DEPTH need not be a power of two - addresses >= DEPTH return zero and
//   raise oob_o); DEPTH<2 rejected at elaboration. Inferred as block RAM
//   or LUT ROM.
// Date: 2026-09-29
module rom #(
  parameter int    WIDTH     = 32,
  parameter int    DEPTH     = 256,
  parameter INIT_FILE = ""
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     en_i,
  input  logic [$clog2(DEPTH)-1:0] addr_i,
  output logic [WIDTH-1:0]         data_o,
  output logic                     oob_o      // registered: address >= DEPTH was requested
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (DEPTH < 2 || WIDTH < 1) begin : g_bad $error("rom: bad DEPTH/WIDTH"); end
  logic [WIDTH-1:0] mem [0:DEPTH-1];
  initial begin
    if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
    else for (int i = 0; i < DEPTH; i++) mem[i] = WIDTH'(32'(i) ^ 32'hA5A5_5A5A);
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin data_o <= '0; oob_o <= 1'b0; end
    else if (en_i) begin
      oob_o  <= (32'(addr_i) >= DEPTH);
      data_o <= (32'(addr_i) >= DEPTH) ? '0 : mem[addr_i];
    end
  end
endmodule
