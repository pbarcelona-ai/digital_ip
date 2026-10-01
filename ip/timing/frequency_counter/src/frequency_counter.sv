// ***************
// Filename: frequency_counter.sv
// Author: FPGA Cores 4 U
// Description: Input frequency counter. Version 1.0.0. Counts rising edges
//   of the (asynchronous) signal sig_i during a gate window of gate_clks_i
//   system clocks and reports the edge count in count_o with a one-clock
//   valid_o pulse after every window; frequency = count * f_clk /
//   gate_clks. The input passes a 2-flop synchronizer, so signals up to
//   f_clk/4 are counted correctly (higher rates alias); over_o flags a
//   count that saturated. Clock - clk. Reset - synchronous active low.
//   Latency - one gate window plus 4 clocks. Resolution - +/-1 count per
//   window; a longer gate improves resolution. Errors - gate_clks_i = 0
//   disables measuring; saturation flagged on over_o (sticky per result).
// Date: 2026-09-29
module frequency_counter #(
  parameter int COUNT_W = 32,
  parameter int GATE_W  = 32
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic               en_i,
  input  logic [GATE_W-1:0]  gate_clks_i,
  input  logic               sig_i,
  output logic [COUNT_W-1:0] count_o,
  output logic               valid_o,
  output logic               over_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (COUNT_W < 2 || GATE_W < 2) begin : g_bad $error("frequency_counter: widths must be >= 2"); end
  logic s_sync, s_prev, rise;
  bit_sync #(.STAGES(2)) u_sync (.clk, .rst_n, .d_i(sig_i), .q_o(s_sync));
  always_ff @(posedge clk) begin
    if (!rst_n) begin s_prev <= 1'b0; rise <= 1'b0; end
    else begin s_prev <= s_sync; rise <= s_sync & ~s_prev; end
  end
  logic [GATE_W-1:0] gcnt; logic [COUNT_W-1:0] ecnt; logic sat;
  always_ff @(posedge clk) begin
    if (!rst_n || !en_i || gate_clks_i == '0) begin
      gcnt <= '0; ecnt <= '0; valid_o <= 1'b0; sat <= 1'b0; if (!rst_n) begin count_o <= '0; over_o <= 1'b0; end
    end else begin
      valid_o <= 1'b0;
      if (gcnt == gate_clks_i - 1'b1) begin
        count_o <= ecnt + ((rise && ecnt != '1) ? 1'b1 : 1'b0); over_o <= sat | (rise && ecnt == '1);
        valid_o <= 1'b1; gcnt <= '0; ecnt <= '0; sat <= 1'b0;
      end else begin
        gcnt <= gcnt + 1'b1;
        if (rise) begin if (ecnt == '1) sat <= 1'b1; else ecnt <= ecnt + 1'b1; end
      end
    end
  end
endmodule
