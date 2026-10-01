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
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam int R = CODE_W - DATA_W - 1;
  localparam int AW = $clog2(DEPTH);
  if (DEPTH < 2) begin : g_bd $error("ecc_memory_ctrl: DEPTH must be >= 2"); end
  logic [CODE_W-1:0] mem [0:DEPTH-1];
  logic [CODE_W-1:0] enc, enc_scrub, mem_q;
  logic [DATA_W-1:0] dec_data; logic dec_sec, dec_ded; logic [R-1:0] dec_syn;
  ecc_encoder #(.DATA_W(DATA_W)) u_enc (.data_i(wdata_i), .code_o(enc));
  ecc_decoder #(.DATA_W(DATA_W)) u_dec (.code_i(mem_q), .data_o(dec_data), .sec_o(dec_sec), .ded_o(dec_ded), .syndrome_o(dec_syn));
  ecc_encoder #(.DATA_W(DATA_W)) u_enc_scrub (.data_i(dec_data), .code_o(enc_scrub));

  // pipeline: stage 1 holds a read whose codeword is being decoded
  logic rd1_v; logic [AW-1:0] rd1_addr;
  logic scrub_wr; logic [AW-1:0] scrub_addr; logic [CODE_W-1:0] scrub_code;
  assign ready_o = SCRUB ? ~(rd1_v | scrub_wr) : 1'b1;
  wire acc = req_i & ready_o;
  wire do_wr = acc & we_i;
  wire do_rd = acc & ~we_i;
  // memory write port: host write has priority only when ready (no scrub in flight by construction)
  always_ff @(posedge clk) begin
    if (do_wr) mem[addr_i] <= enc ^ inject_i;
    else if (scrub_wr) mem[scrub_addr] <= scrub_code;
    if (do_rd) mem_q <= mem[addr_i];
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rd1_v <= 1'b0; rd1_addr <= '0; rvalid_o <= 1'b0; rdata_o <= '0; sec_o <= 1'b0; ded_o <= 1'b0;
      sec_count_o <= '0; ded_count_o <= '0; err_addr_o <= '0; scrub_wr <= 1'b0; scrub_addr <= '0; scrub_code <= '0;
    end else begin
      rd1_v <= do_rd; rd1_addr <= addr_i;
      rvalid_o <= rd1_v; scrub_wr <= 1'b0;
      if (rd1_v) begin
        rdata_o <= dec_data; sec_o <= dec_sec; ded_o <= dec_ded;
        if (dec_sec) begin
          if (sec_count_o != '1) sec_count_o <= sec_count_o + 1'b1;
          err_addr_o <= rd1_addr;
          if (SCRUB) begin scrub_wr <= 1'b1; scrub_addr <= rd1_addr; scrub_code <= enc_scrub; end
        end
        if (dec_ded) begin if (ded_count_o != '1) ded_count_o <= ded_count_o + 1'b1; err_addr_o <= rd1_addr; end
      end else begin sec_o <= 1'b0; ded_o <= 1'b0; end
      if (clr_i) begin sec_count_o <= '0; ded_count_o <= '0; end
    end
  end
endmodule
