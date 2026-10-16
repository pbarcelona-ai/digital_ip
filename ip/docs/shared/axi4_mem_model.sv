// ***************
// Filename: axi4_mem_model.sv
// Author: FPGA Cores 4 U
// Description: Behavioral AXI4 slave memory model for testbenches. 32 bit
//   data, INCR bursts up to 256 beats, byte strobes, random ready/valid
//   stalls (STALL percent), SLVERR for addresses beyond the memory size.
//   The mem array is accessible hierarchically so tests can preload and
//   inspect memory.
// Date: 2026-09-29

module axi4_mem_model #(
  parameter int WORDS = 4096,           // memory size in 32 bit words
  parameter int STALL = 25              // percent of cycles ready/valid is held low
) (
  input  logic        aclk,
  input  logic        aresetn,
  input  logic [31:0] awaddr, input logic [7:0] awlen, input logic awvalid, output logic awready,
  input  logic [31:0] wdata, input logic [3:0] wstrb, input logic wlast, input logic wvalid, output logic wready,
  output logic [1:0]  bresp, output logic bvalid, input logic bready,
  input  logic [31:0] araddr, input logic [7:0] arlen, input logic arvalid, output logic arready,
  output logic [31:0] rdata, output logic [1:0] rresp, output logic rlast, output logic rvalid, input logic rready
);
