// ***************
// Filename: cic.sv
// Author: FPGA Cores 4 U
// Description: CIC decimation filter (cascaded integrator-comb). Version
//   1.0.0. N integrators run at the input rate with wrap-around
//   arithmetic, the stream is decimated by r_i (1..RMAX, run-time
//   programmable, latched at the start of each output period) and N combs
//   (differential delay 1) run at the output rate. Register width is
//   DATA_W + N*ceil(log2(RMAX)) so the wrap-around cannot corrupt the
//   result. DC gain is r^N; the output is the arithmetic right shift of
//   the comb result by shift_i (use N*log2(r) for power-of-two ratios to
//   get unity gain), rounded and saturated to OUT_W bits (sat_o flags
//   clipping). Clock - clk, one input per valid_i. Reset - synchronous
//   active low clears all integrators and combs. Latency - the output
//   appears with the clock after the r_i-th input of a period (1 clock).
//   Droop - CIC passband droop is not compensated (follow with a fir).
//   Errors - N or RMAX out of range rejected at elaboration; r_i outside
//   1..RMAX is clamped and flagged on r_err_o.
// Date: 2026-09-29
module cic #(
  parameter int N       = 3,
  parameter int RMAX    = 64,
  parameter int DATA_W  = 16,
  parameter int OUT_W   = 16
) (
  input  logic                        clk,
  input  logic                        rst_n,
  input  logic [$clog2(RMAX+1)-1:0]   r_i,
  input  logic [7:0]                  shift_i,
  input  logic                        valid_i,
  input  logic signed [DATA_W-1:0]    data_i,
  output logic                        valid_o,
  output logic signed [OUT_W-1:0]     data_o,
  output logic                        sat_o,
  output logic                        r_err_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam int RB = $clog2(RMAX + 1);
  localparam int BW = DATA_W + N * $clog2(RMAX > 1 ? RMAX : 2);
  if (N < 1 || N > 8) begin : g_bn $error("cic: N must be 1..8"); end
  if (RMAX < 2) begin : g_br $error("cic: RMAX must be >= 2"); end
  logic signed [BW-1:0] integ [0:N-1];
  logic signed [BW-1:0] comb_d [0:N-1];
  logic signed [BW-1:0] comb_v [0:N];
  logic [RB-1:0] cnt, r_lat;
  wire  [RB-1:0] r_use = (r_i == 0) ? RB'(1) : (r_i > RMAX) ? RB'(RMAX) : r_i;
  wire  last = (cnt == r_lat - 1'b1);
  logic signed [BW-1:0] sh_res, rnd;
  always_comb begin
    comb_v[0] = integ[N-1];
    for (int k = 0; k < N; k++) comb_v[k+1] = comb_v[k] - comb_d[k];
    rnd    = (shift_i == 0) ? comb_v[N] : (comb_v[N] + (BW'(1) <<< (shift_i - 1)));
    sh_res = rnd >>> shift_i;
  end
  localparam logic signed [BW-1:0] MAXV = (BW'(1) <<< (OUT_W - 1)) - 1;
  localparam logic signed [BW-1:0] MINV = -(BW'(1) <<< (OUT_W - 1));
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int k = 0; k < N; k++) begin integ[k] <= '0; comb_d[k] <= '0; end
      cnt <= '0; r_lat <= RB'(1); valid_o <= 1'b0; data_o <= '0; sat_o <= 1'b0; r_err_o <= 1'b0;
    end else begin
      valid_o <= 1'b0; sat_o <= 1'b0; r_err_o <= 1'b0;
      if (valid_i) begin
        integ[0] <= integ[0] + BW'(data_i);
        for (int k = 1; k < N; k++) integ[k] <= integ[k] + integ[k-1];
        if (cnt == '0 && (r_i == 0 || r_i > RMAX)) r_err_o <= 1'b1;
        if (last) begin
          cnt <= '0; r_lat <= r_use;
          for (int k = 0; k < N; k++) comb_d[k] <= comb_v[k];
          valid_o <= 1'b1;
          if (sh_res > MAXV) begin data_o <= MAXV[OUT_W-1:0]; sat_o <= 1'b1; end
          else if (sh_res < MINV) begin data_o <= MINV[OUT_W-1:0]; sat_o <= 1'b1; end
          else data_o <= sh_res[OUT_W-1:0];
        end else begin
          cnt <= cnt + 1'b1;
        end
      end
    end
  end
endmodule
