// ***************
// Filename: conv2d_ref.sv
// Author: FPGA Cores 4 U
// Description: Testbench reference model of conv2d_core: N x N kernel k[]
//   (i = r*N + c), result (sum + 2^(shift-1)) >>> shift clamped to CW bits,
//   per component, frame edges by BORDER (0 clamp, 1 reflect-101).
//   run(W, H) filters img[][] into out[][]; chain(W, H) copies out[][] to
//   img[][] for a second stage; set_kernel() loads a conv2d_pkg kernel.
// Date: 2026-10-08
module conv2d_ref #(
  parameter int N      = 5,
  parameter int C      = 3,
  parameter int CW     = 8,
  parameter int MAXW   = 64,
  parameter int MAXH   = 64,
  parameter int BORDER = 0
);
  localparam int R = (N - 1) / 2;
  logic [C*CW-1:0] img [MAXH][MAXW];
  logic [C*CW-1:0] out [MAXH][MAXW];
  int k [25];
  int shift = 0;

  function automatic int bnd(input int v, input int n);
    if (BORDER != 0) return (v < 0) ? -v : (v >= n) ? 2 * (n - 1) - v : v;
    return (v < 0) ? 0 : (v >= n) ? n - 1 : v;
  endfunction

  task automatic set_kernel(input logic [25*32-1:0] kp, input int sh);
    for (int i = 0; i < 25; i++) k[i] = $signed(kp[i*32 +: 32]);
    shift = sh;
  endtask

  task automatic set_identity();
    for (int i = 0; i < 25; i++) k[i] = 0;
    k[R * N + R] = 1;
    shift = 0;
  endtask

  task automatic run(input int W, input int H);
    logic [C*CW-1:0] p, res;
    int acc, v;
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) begin
        res = '0;
        for (int c = 0; c < C; c++) begin
          acc = 0;
          for (int r = 0; r < N; r++)
            for (int j = 0; j < N; j++) begin
              p = img[bnd(y + r - R, H)][bnd(x + j - R, W)];
              v = int'((p >> (c * CW)) & ((1 << CW) - 1));
              acc += k[r * N + j] * v;
            end
          if (shift > 0) acc += 1 << (shift - 1);
          acc = acc >>> shift;
          if (acc < 0) acc = 0;
          if (acc > (1 << CW) - 1) acc = (1 << CW) - 1;
          res = res | ((C*CW)'(acc) << (c * CW));
        end
        out[y][x] = res;
      end
  endtask

  task automatic chain(input int W, input int H);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) img[y][x] = out[y][x];
  endtask
endmodule
