// ***************
// Filename: ecc_memory_ctrl.sv
// Author: FPGA Cores 4 U
// Description: ECC-protected memory controller. Version 1.0.0. A DEPTH x
//   DATA_W word memory (inferred RAM, stored as SECDED codewords) behind a
//   simple request interface. Writes store the encoded word; reads fetch
//   the codeword, correct any single-bit error, flag double-bit errors
//   (sec_o / ded_o with rvalid_o) and count them (saturating counters,
//   err_addr_o keeps the address of the last error). With SCRUB=1 a
//   corrected read writes the repaired codeword back, which stalls new
//   requests for one clock (ready_o low) and halves read throughput, so a
//   soft error is not allowed to accumulate into an uncorrectable one.
//   inject_i (test aid) is XORed into the codeword of the next write to
//   create memory errors on demand - tie to zero in a product. Clock -
//   clk. Reset - synchronous active low clears counters and pipeline,
//   memory contents are undefined until written (reads of never-written
//   words may report errors). Latency - read data 2 clocks after the
//   accepted request (rdata_o / flags with rvalid_o), write takes effect
//   the next clock. Throughput - one request per clock (SCRUB=0). Errors -
//   ded_o (uncorrectable, data_o unreliable), sec_o (corrected), counters;
//   DEPTH<2 rejected at elaboration.
// Date: 2026-09-29

module ecc_memory_ctrl #(
  parameter int DATA_W = 32,
  parameter int DEPTH  = 1024,
  parameter bit SCRUB  = 1'b1,
  parameter int CODE_W = DATA_W + $clog2(DATA_W + $clog2(DATA_W + 1) + 1) + 1,
  parameter int CNT_W  = 16
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     req_i,
  input  logic                     we_i,
  input  logic [$clog2(DEPTH)-1:0] addr_i,
  input  logic [DATA_W-1:0]        wdata_i,
  output logic                     ready_o,
  input  logic [CODE_W-1:0]        inject_i,          // XOR mask for the next write (testing)
  output logic                     rvalid_o,
  output logic [DATA_W-1:0]        rdata_o,
  output logic                     sec_o,             // with rvalid_o: single error corrected
  output logic                     ded_o,             // with rvalid_o: uncorrectable error
  input  logic                     clr_i,
  output logic [CNT_W-1:0]         sec_count_o,
  output logic [CNT_W-1:0]         ded_count_o,
  output logic [$clog2(DEPTH)-1:0] err_addr_o
);
