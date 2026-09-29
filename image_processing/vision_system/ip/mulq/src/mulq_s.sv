// ***************
// Filename: mulq_s.sv
// Author: Paul Barcelona
// Description: Reusable IP. Timing-friendly signed 32x32 multiply with
// the Q16.16 shift built in: s = (a*b) >>> 16 as an exact 48-bit
// signed value, in 2 cycles. The multiply is split into four 16x16
// partial products (one DSP48 each, registered in stage 1) that are
// combined in stage 2, avoiding the wide fabric adder that limits a
// plain 32x32 multiply to ~11 ns. Apply barrel_pkg::qsat48 to get
// the saturating qmul() result.
// Date: September 26, 2026
// ***************
// =============================================================================
// mulq_s.sv
//
// Math (a = ah*2^16 + al, b = bh*2^16 + bl, ah/bh signed 16, al/bl the
// UNSIGNED low halves):
//   a*b = ah*bh*2^32 + (ah*bl + al*bh)*2^16 + al*bl
//   (a*b)>>>16 = ah*bh*2^16 + (ah*bl + al*bh) + floor(al*bl / 2^16)
// The last term uses a plain >> on a non-negative value, so the whole
// expression equals floor((a*b)/2^16) exactly (the first two terms are
// integers, so the floor only affects al*bl/2^16). This is precisely the
// value barrel_pkg::qmul shifts before saturating, so
//   qsat48(mulq_s(a,b)) == barrel_pkg::qmul(a,b)   for all inputs.
//
// Stage 1 registers the four raw partial products (no reset -- an async
// reset on a datapath register prevents DSP-register packing). Stage 2
// registers the combined 48-bit result. Latency 2, throughput 1/clock.
// =============================================================================
module mulq_s (
  input  logic               clk,
  input  logic signed [31:0] a,
  input  logic signed [31:0] b,
  output logic signed [47:0] s
);
  // Split operands. Low halves are zero-extended to 17-bit SIGNED values
  // (so they multiply as the non-negative numbers they are).
  logic signed [15:0] ah, bh;
  logic signed [16:0] al, bl;
  assign ah = a[31:16];
  assign bh = b[31:16];
  assign al = {1'b0, a[15:0]};
  assign bl = {1'b0, b[15:0]};

  // Stage 1: raw partial products (each fits one DSP48E1's 25x18 multiplier)
  logic signed [31:0] p_hh;   // ah*bh   16x16 -> 32
  logic signed [32:0] p_hl;   // ah*bl   16x17 -> 33
  logic signed [32:0] p_lh;   // al*bh   17x16 -> 33
  logic signed [33:0] p_ll;   // al*bl   17x17 -> 34 (non-negative)
  always_ff @(posedge clk) begin
    p_hh <= ah * bh;
    p_hl <= ah * bl;
    p_lh <= al * bh;
    p_ll <= al * bl;
  end

  // Stage 2: combine. (hh<<16) + (hl+lh) + (ll>>16), 48-bit signed.
  logic signed [47:0] hh_sh, mid, ll_sh;
  assign hh_sh = {{16{p_hh[31]}}, p_hh} <<< 16;
  assign mid   = {{15{p_hl[32]}}, p_hl} + {{15{p_lh[32]}}, p_lh};
  assign ll_sh = {30'b0, p_ll[33:16]};              // p_ll >= 0: logical shift
  always_ff @(posedge clk) begin
    s <= hh_sh + mid + ll_sh;
  end
endmodule
