// ***************
// Filename: ecc_secded.sv
// Author: FPGA Cores 4 U
// Description: SECDED (single error correct, double error detect) Hamming
//   code encoder and decoder for any data width. Version 1.0.0. The codeword
//   has DATA_W + R + 1 bits where R is the number of Hamming check bits (R=7
//   for 64 data bits, giving the classic 72-bit word, R=6 for 32 data bits
//   giving 39 bits) plus one overall parity bit at bit 0. Both modules are
//   purely combinational (latency 0) and reset-free. The decoder reports
//   sec_o when one bit (data, check or overall parity) was wrong and
//   corrected, ded_o when two bits were wrong (data_o is then the uncorrected
//   data) and the syndrome for diagnostics. Three or more errors may be
//   mis-corrected, as for any SECDED code. Timing - about log2(codeword) XOR
//   levels plus the correction mux; register the result in the caller
//   (ecc_memory_ctrl does). Errors - DATA_W < 4 rejected at elaboration.
//   Clock - none, purely combinational. Reset - none, no state. Latency - 0
//   clocks (combinational).
// Date: 2026-09-29
module ecc_encoder #(
  parameter int DATA_W = 64,
  parameter int R      = $clog2(DATA_W + $clog2(DATA_W + 1) + 1),
  parameter int CODE_W = DATA_W + R + 1
) (
  input  logic [DATA_W-1:0] data_i,
  output logic [CODE_W-1:0] code_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (DATA_W < 4) begin : g_bad $error("ecc_encoder: DATA_W must be >= 4"); end
  localparam int N = DATA_W + R;
  always_comb begin
    int j; logic par;
    code_o = '0; j = 0;
    for (int pos = 1; pos <= N; pos++) begin
      if ((pos & (pos - 1)) != 0) begin code_o[pos] = data_i[j]; j = j + 1; end
    end
    for (int p = 0; p < R; p++) begin
      par = 1'b0;
      for (int pos = 1; pos <= N; pos++) if ((pos & (1 << p)) != 0) par = par ^ code_o[pos];
      code_o[1 << p] = par;
    end
    par = 1'b0;
    for (int pos = 1; pos <= N; pos++) par = par ^ code_o[pos];
    code_o[0] = par;
  end
endmodule

module ecc_decoder #(
  parameter int DATA_W = 64,
  parameter int R      = $clog2(DATA_W + $clog2(DATA_W + 1) + 1),
  parameter int CODE_W = DATA_W + R + 1
) (
  input  logic [CODE_W-1:0] code_i,
  output logic [DATA_W-1:0] data_o,
  output logic              sec_o,       // one error corrected
  output logic              ded_o,       // two errors detected (uncorrectable)
  output logic [R-1:0]      syndrome_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (DATA_W < 4) begin : g_bad $error("ecc_decoder: DATA_W must be >= 4"); end
  localparam int N = DATA_W + R;
  logic [CODE_W-1:0] cw; logic [R-1:0] syn; logic ovr;
  always_comb begin
    int j;
    syn = '0;
    for (int p = 0; p < R; p++) begin
      syn[p] = 1'b0;
      for (int pos = 1; pos <= N; pos++) if ((pos & (1 << p)) != 0) syn[p] = syn[p] ^ code_i[pos];
    end
    ovr = ^code_i;                                      // overall parity of the whole word
    cw = code_i;
    sec_o = 1'b0; ded_o = 1'b0;
    if (syn == '0 && !ovr) begin end                    // clean
    else if (ovr) begin                                 // odd number of errors: assume one
      sec_o = 1'b1;
      if (syn != '0) begin
        if (32'(syn) <= N) cw[syn] = ~cw[syn];
        else begin sec_o = 1'b0; ded_o = 1'b1; end      // syndrome points outside the word
      end                                               // syn == 0: the overall parity bit itself flipped
    end else begin ded_o = 1'b1; end                    // even, nonzero syndrome: two errors
    j = 0; data_o = '0;
    for (int pos = 1; pos <= N; pos++) begin
      if ((pos & (pos - 1)) != 0) begin data_o[j] = cw[pos]; j = j + 1; end
    end
    if (ded_o) begin                                    // give back the raw data bits
      j = 0;
      for (int pos = 1; pos <= N; pos++) if ((pos & (pos - 1)) != 0) begin data_o[j] = code_i[pos]; j = j + 1; end
    end
  end
  assign syndrome_o = syn;
endmodule
