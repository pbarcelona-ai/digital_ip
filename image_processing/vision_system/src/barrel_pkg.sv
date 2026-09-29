// ***************
// Filename: barrel_pkg.sv
// Author: Paul Barcelona
// Description: Shared SystemVerilog package for the lens-distortion-
// correction core. Defines the Q16.16 fixed-point format used by
// every module in this design, the saturating qmul() multiply
// helper, and the frame-size/pipeline-timing constants (MAX_W,
// MAX_H, ADDR_W, COORD_W, LINE_GAP_CYCLES) every other file
// imports.
// Date: September 26, 2026
// ***************
// =============================================================================
// barrel_pkg.sv
//
// Shared parameters / fixed-point format for the barrel-distortion-correction
// pipeline.
//
// Fixed-point convention used EVERYWHERE in this design (coefficients,
// normalized coordinates, pixel coordinates, factors): signed Q16.16
//   bit [31]    = sign
//   bits[30:16] = integer part (15 bits, i.e. range approx +/-32768)
//   bits[15:0]  = fractional part (16 bits, resolution 2^-16 = 1.53e-5)
//
// A single uniform format is used throughout (pixel coordinates and
// normalized [-1..1]-ish coordinates alike) to keep every multiply stage
// identical: mult32x32 -> 64-bit product -> arithmetic-shift-right by 16 ->
// truncate to 32 bits. This wastes a little headroom on the normalized
// values (which only ever use a couple of integer bits) but removes any
// risk of per-signal format bookkeeping errors, which is the right
// trade-off for a reference design.
// =============================================================================
package barrel_pkg;

  localparam int FRAC_BITS = 16;
  localparam int DATA_W    = 32;                 // Q16.16 word width
  localparam bit signed [DATA_W-1:0] Q16_ONE  = 32'h0001_0000; // 1.0
  localparam bit signed [DATA_W-1:0] Q16_ZERO = 32'h0000_0000;

  // Pixel channel width (RGB888 packed into 24 bits; upper 8 bits of the
  // 32-bit AXI-Stream word are unused/zero).
  localparam int PIX_W   = 24;
  localparam int CHAN_W  = 8;

  // Maximum supported frame geometry. On-chip frame buffer is sized to
  // MAX_W*MAX_H*4 (four replicated banks for single-cycle 4-corner
  // bilinear reads -- see frame_buffer.sv). Increase for real deployment
  // together with moving the buffer to external DDR (see docs/README).
  // 720 (not a round power-of-two) because that's the largest single
  // dimension this project's own testbenches exercise (480x720/720x480
  // portrait/landscape frames) -- found to be a real limitation (720 >
  // the previous MAX_H=512) when those tests were scaled up, not an
  // arbitrary round number.
  localparam int MAX_W = 720;
  localparam int MAX_H = 720;
  localparam int ADDR_W = $clog2(MAX_W*MAX_H);
  localparam int COORD_W = $clog2(MAX_W > MAX_H ? MAX_W : MAX_H) + 1;

  // Number of idle cycles required between consecutive lines on both the
  // slave (input) and master (output) AXI4-Stream video interfaces, per
  // the spec ("5 idle clocks then the next continuous line").
  localparam int LINE_GAP_CYCLES = 5;

  // Post-multiply stage of the saturating fixed-point multiply: takes the
  // raw 64-bit signed product (Q32.32), shifts it back to Q16.16 with an
  // arithmetic shift, and saturates to 32 bits. Split out from qmul() so
  // pipelined datapaths can REGISTER the raw product first (letting the
  // synthesizer absorb that register into the DSP48's internal MREG/PREG)
  // and do the shift/saturate in the following cycle. qmul(a,b) is by
  // definition qsat(a*b), so both forms are bit-identical.
  function automatic logic signed [DATA_W-1:0] qsat
    (input logic signed [2*DATA_W-1:0] prod_in);
    logic signed [2*DATA_W-1:0] prod;
    logic signed [DATA_W-1:0]   res;
    begin
      prod = prod_in >>> FRAC_BITS;           // arithmetic shift back to Q16.16
      // saturate to 32 bits
      if (prod > $signed({1'b0,{(DATA_W-1){1'b1}}}))
        res = {1'b0,{(DATA_W-1){1'b1}}};
      else if (prod < $signed({1'b1,{(DATA_W-1){1'b0}}}))
        res = {1'b1,{(DATA_W-1){1'b0}}};
      else
        res = prod[DATA_W-1:0];
      qsat = res;
    end
  endfunction

  // Saturate an already-shifted 48-bit signed value (as produced by the
  // mulq_s IP: exactly (a*b)>>>16) to a signed 32-bit result.
  // qsat48(mulq_s(a,b)) == qmul(a,b) for all a,b.
  function automatic logic signed [DATA_W-1:0] qsat48
    (input logic signed [47:0] s_in);
    begin
      if (s_in > 48'sd2147483647)        qsat48 = {1'b0,{(DATA_W-1){1'b1}}};
      else if (s_in < -48'sd2147483648)  qsat48 = {1'b1,{(DATA_W-1){1'b0}}};
      else                               qsat48 = s_in[DATA_W-1:0];
    end
  endfunction

  // Fixed-point saturating multiply: (a * b) in Q16.16 x Q16.16 -> Q16.16
  // (single-cycle combinational form; used by testbenches/reference code
  // and by any path that is not timing-critical).
  function automatic logic signed [DATA_W-1:0] qmul
    (input logic signed [DATA_W-1:0] a, input logic signed [DATA_W-1:0] b);
    logic signed [2*DATA_W-1:0] prod;
    begin
      prod = a * b;                          // full 64-bit product
      qmul = qsat(prod);
    end
  endfunction

endpackage
