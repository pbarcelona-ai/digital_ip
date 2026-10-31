// ***************
// Filename: npu_ram_1w2r.sv
// Author: FPGA Cores 4 U
// Description: RAM of the NPU engines: DEPTH words of W bits, one write port
//   and two read ports with registered outputs (block RAM: the read word of
//   an address appears the clock after it; a read of the word written in
//   the same clock returns the old word). Version 1.0.0.
//   Parameters: DEPTH, W. Clock - clk. Reset - none (memory contents and
//   read registers; every word is written before it is read). Clock-domain
//   crossings - none.
// Date: 2026-10-26
module npu_ram_1w2r #(
  parameter int DEPTH = 1024,                    // words
  parameter int W     = 128                      // bits per word
) (
  input  logic                     clk,          // clock
  input  logic                     we_i,         // write
  input  logic [$clog2(DEPTH)-1:0] waddr_i,
  input  logic [W-1:0]             wdata_i,
  input  logic [$clog2(DEPTH)-1:0] raddr_a_i,    // read port A: the word, the clock after
  output logic [W-1:0]             rdata_a_o,
  input  logic [$clog2(DEPTH)-1:0] raddr_b_i,    // read port B
  output logic [W-1:0]             rdata_b_o
);
  logic [W-1:0] mem [DEPTH];
  always_ff @(posedge clk) begin
    if (we_i) mem[waddr_i] <= wdata_i;
    rdata_a_o <= mem[raddr_a_i];
    rdata_b_o <= mem[raddr_b_i];
  end
endmodule
