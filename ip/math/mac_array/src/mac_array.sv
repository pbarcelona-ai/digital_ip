// ***************
// Filename: mac_array.sv
// Author: FPGA Cores 4 U
// Description: ROWS x COLS MAC array for the NPU (INT8 x INT8 -> INT32).
//   Each column is an independent accumulator; each row broadcasts its
//   activation to all columns. The weight matrix is COLS x ROWS (one
//   weight per MAC). Latency: 1 clock from valid_i to valid_o.
//   Weight loading: stream one row per clock (w_row_i, w_valid_i, w_row_idx_i).
//   Accumulator loading: load all COLS at once (acc_i, acc_valid_i).
//   Parameters: ROWS, COLS (default 64 x 64 = 4096 MACs per clock).
//   Clock - clk. Reset - synchronous active low rst_n.
// Date: 2026-10-24
module mac_array #(
  parameter int ROWS        = 64,                // number of rows (activations per cycle)
  parameter int COLS        = 64,                // number of columns (output elements per cycle)
  parameter int A_WIDTH     = 8,                 // activation width (signed)
  parameter int W_WIDTH     = 8,                 // weight width (signed)
  parameter int ACC_WIDTH   = 32,                // accumulator/output width (signed)
  parameter int ROW_IDX_W   = $clog2(ROWS)       // row index width for weight loading
) (
  input  logic                    clk,
  input  logic                    rst_n,
  // activation input (one vector of ROWS elements per clock)
  input  logic                    valid_i,
  input  logic [ROWS*A_WIDTH-1:0] a_i,           // packed activations
  // weight loading (stream one row per clock)
  input  logic                    w_valid_i,
  input  logic [COLS*W_WIDTH-1:0] w_row_i,       // one weight row (COLS weights)
  input  logic [ROW_IDX_W-1:0]    w_row_idx_i,   // which row of the weight matrix
  // accumulator loading (one vector of COLS elements)
  input  logic                    acc_valid_i,
  input  logic [COLS*ACC_WIDTH-1:0] acc_i,
  // output
  output logic                    valid_o,
  output logic [COLS*ACC_WIDTH-1:0] result_o
);
  localparam int ROW_W = A_WIDTH;
  localparam int COL_W = ACC_WIDTH;

  // weight memory: COLS x ROWS (stored as ROWS rows of COLS weights each)
  logic [COLS*W_WIDTH-1:0] weight_mem [ROWS];
  // accumulator registers
  logic [COLS*ACC_WIDTH-1:0] acc_q;

  // weight loading
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int r = 0; r < ROWS; r++) weight_mem[r] <= '0;
    end else if (w_valid_i) begin
      weight_mem[w_row_idx_i] <= w_row_i;
    end
  end

  // accumulator loading
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      acc_q <= '0;
    end else if (acc_valid_i) begin
      acc_q <= acc_i;
    end
  end

  // MAC computation
  logic [COLS*ACC_WIDTH-1:0] sum;
  logic [COLS-1:0]           sum_ovf;
  logic [COLS-1:0]           sum_inexact;

  // Each column computes: sum[c] = sum_r (a[r] * w[c][r]) + acc[c]
  // We can compute this with a generate block or a loop
  always_comb begin
    sum = '0;
    sum_ovf = '0;
    sum_inexact = '0;
    if (valid_i) begin
      for (int c = 0; c < COLS; c++) begin
        logic signed [ACC_WIDTH:0] acc;
        logic signed [ACC_WIDTH-1:0] acc_q_c;
        logic signed [ACC_WIDTH:0] prod_sum;
        
        acc_q_c = acc_q[c*ACC_WIDTH +: ACC_WIDTH];
        acc = {{(ACC_WIDTH+1-ACC_WIDTH){acc_q_c[ACC_WIDTH-1]}}, acc_q_c};
        
        prod_sum = '0;
        for (int r = 0; r < ROWS; r++) begin
          logic signed [A_WIDTH-1:0] a_r;
          logic signed [W_WIDTH-1:0] w_cr;
          logic signed [A_WIDTH+W_WIDTH-1:0] prod;
          
          a_r = a_i[r*A_WIDTH +: A_WIDTH];
          w_cr = weight_mem[r][c*W_WIDTH +: W_WIDTH];
          prod = $signed(a_r) * $signed(w_cr);
          prod_sum += $signed({{(ACC_WIDTH+1-(A_WIDTH+W_WIDTH)){prod[A_WIDTH+W_WIDTH-1]}}, prod});
        end
        
        logic signed [ACC_WIDTH:0] result;
        result = acc + prod_sum;
        
        // Saturate to ACC_WIDTH
        if (result > ((1 << (ACC_WIDTH-1)) - 1)) begin
          sum[c*ACC_WIDTH +: ACC_WIDTH] = ((1 << (ACC_WIDTH-1)) - 1);
          sum_ovf[c] = 1'b1;
        end else if (result < -(1 << (ACC_WIDTH-1))) begin
          sum[c*ACC_WIDTH +: ACC_WIDTH] = -(1 << (ACC_WIDTH-1));
          sum_ovf[c] = 1'b1;
        end else begin
          sum[c*ACC_WIDTH +: ACC_WIDTH] = result[ACC_WIDTH-1:0];
        end
      end
    end
  end

  // Output register
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid_o <= 1'b0;
      result_o <= '0;
    end else begin
      valid_o <= valid_i;
      if (valid_i) result_o <= sum;
    end
  end

endmodule
