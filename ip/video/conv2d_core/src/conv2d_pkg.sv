// ***************
// Filename: conv2d_pkg.sv
// Author: FPGA Cores 4 U
// Description: Kernel definitions for conv2d_core based filters. Version
//   1.0.0. A kernel is N x N signed integer coefficients, entry i = r*N + c
//   (row r from the top, column c from the left) in bits [i*32 +: 32] of a
//   packed vector; the result is (sum(k * p) + round) >>> shift, clamped.
//     identity_kernel  centre 1, shift 0: output = input (pass-through)
//     blur_kernel      binomial (Gaussian approximation) [1 2 1] or
//                      [1 4 6 4 1] outer product, shift 2*(N-1) (sum 1.0)
//     sharpen_kernel   unsharp mask (1 + a) * identity - a * blur, a =
//                      AMOUNT (integer), same shift: sum 1.0, so flat areas
//                      keep their level and edges are boosted
//   N = 3 or 5. KMAX = 25 entries are always returned; use the low N*N.
// Date: 2026-10-08
package conv2d_pkg;
  localparam int KMAX = 25;

  function automatic int binom(input int n, input int i);
    if (n == 3) return (i == 1) ? 2 : 1;
    case (i) 0, 4: return 1; 1, 3: return 4; default: return 6; endcase
  endfunction

  function automatic int blur_shift(input int n);
    return 2 * (n - 1);
  endfunction

  function automatic logic [KMAX*32-1:0] identity_kernel(input int n);
    logic [KMAX*32-1:0] k; k = '0;
    k[((n / 2) * n + n / 2) * 32 +: 32] = 32'sd1;
    return k;
  endfunction

  function automatic logic [KMAX*32-1:0] blur_kernel(input int n);
    logic [KMAX*32-1:0] k; k = '0;
    for (int r = 0; r < n; r++)
      for (int c = 0; c < n; c++)
        k[(r * n + c) * 32 +: 32] = 32'(binom(n, r) * binom(n, c));
    return k;
  endfunction

  function automatic logic [KMAX*32-1:0] sharpen_kernel(input int n, input int amount);
    logic [KMAX*32-1:0] k; int one;
    one = 1 << blur_shift(n);
    for (int r = 0; r < n; r++)
      for (int c = 0; c < n; c++)
        k[(r * n + c) * 32 +: 32] = 32'(((r == n / 2 && c == n / 2) ? (1 + amount) * one : 0)
                                        - amount * binom(n, r) * binom(n, c));
    for (int i = n * n; i < KMAX; i++) k[i * 32 +: 32] = '0;
    return k;
  endfunction
endpackage
