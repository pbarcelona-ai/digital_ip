// ***************
// Filename: scaler_coef_gen.svh
// Author: Paul Barcelona
// Description: Polyphase coefficient generator (testbench).
//   SystemVerilog implementation of the coefficient derivation in
//   docs/coefficient_derivation.md; bit-identical to tools/scaler_coefs.py
//   so testbenches program the IP exactly as driver software would.
//   Kernels: Mitchell-Netravali cubic (B,C) and Lanczos-a. Per phase: tap
//   distances d = (t - ctr) - p/P, weights K(d/s) with s = max(1, scale),
//   normalise to 1, round, add the residue to the largest tap (exact DC
//   gain), saturate to COEF_W. Include inside a testbench module; the
//   result is written to gen_tab[phase][tap].
// Date: 2026-09-26

localparam int KERNEL_CUBIC   = 0;   // Mitchell-Netravali family, params (B, C)
localparam int KERNEL_LANCZOS = 1;   // Lanczos, param a

// Result table [phase][tap] (up to 64 phases x 16 taps)
int gen_tab [64][16];

// Evaluate kernel 'kind' at distance x (in input pixels).
// Written with a single exit point and no block-local declarations so that it
// runs on Icarus Verilog as well as on Verilator / commercial simulators.
function automatic real kernel_eval(input int kind, input real pa, input real pb, input real x);
  real ax, r, B, C, a, pi;
  pi = 3.14159265358979323846;
  ax = (x < 0.0) ? -x : x;
  r  = 0.0;
  if (kind == KERNEL_CUBIC) begin
    // piecewise cubic, support |x| < 2
    B = pa; C = pb;
    if (ax < 1.0)
      r = ((12.0 - 9.0*B - 6.0*C) * ax*ax*ax + (-18.0 + 12.0*B + 6.0*C) * ax*ax
           + (6.0 - 2.0*B)) / 6.0;
    else if (ax < 2.0)
      r = ((-B - 6.0*C) * ax*ax*ax + (6.0*B + 30.0*C) * ax*ax
           + (-12.0*B - 48.0*C) * ax + (8.0*B + 24.0*C)) / 6.0;
  end else begin
    // windowed sinc: sinc(x) * sinc(x/a), support |x| < a
    a = pa;
    if (ax < 1.0e-9)
      r = 1.0;
    else if (ax < a)
      r = (a * $sin(pi * ax) * $sin(pi * ax / a)) / (pi * pi * ax * ax);
  end
  return r;
endfunction

// scale = max(1, in_size / out_size) : kernel stretch for anti-aliasing
task automatic gen_coefs(input int kind, input real pa, input real pb,
                         input int taps, input int phase_bits, input int frac,
                         input int coef_w, input real scale);
  int  phases, ctr, one, cmax, cmin, qsum, big;
  real s, sum, f;
  real w [16];
  int  q [16];
  phases = 1 << phase_bits;
  ctr    = (taps - 1) / 2;
  s      = (scale < 1.0) ? 1.0 : scale;
  one    = 1 << frac;
  cmax   = (1 << (coef_w - 1)) - 1;
  cmin   = -(1 << (coef_w - 1));
  for (int p = 0; p < phases; p++) begin
    // sample the (stretched) kernel at the tap distances of phase p
    sum  = 0.0;
    qsum = 0;
    big  = 0;
    f    = real'(p) / real'(phases);
    for (int t = 0; t < taps; t++) begin
      w[t] = kernel_eval(kind, pa, pb, (real'(t - ctr) - f) / s);
      sum  = sum + w[t];
    end
    // normalise to unity gain and quantise; remember the largest tap
    for (int t = 0; t < taps; t++) begin
      q[t] = int'($floor(w[t] / sum * real'(one) + 0.5));
      qsum = qsum + q[t];
      if (q[t] > q[big]) big = t;
    end
    q[big] = q[big] + one - qsum;         // exact unity DC gain
    // saturate to the COEF_W range; unused taps are zero
    for (int t = 0; t < 16; t++)
      gen_tab[p][t] = (t < taps) ? ((q[t] > cmax) ? cmax : (q[t] < cmin) ? cmin : q[t]) : 0;
  end
endtask
