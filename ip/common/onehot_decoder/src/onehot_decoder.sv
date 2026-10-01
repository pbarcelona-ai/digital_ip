// ***************
// Filename: onehot_decoder.sv
// Author: FPGA Cores 4 U
// Description: Binary to one-hot decoder with enable. Version 1.0.0. Bit
//   sel_i of onehot_o is set when en_i is high. A select value >= WIDTH sets
//   err_o and produces an all-zero output. REGISTERED=1 adds one output
//   register stage (latency 1, synchronous reset to zero); otherwise the
//   block is combinational (latency 0). Errors - out-of-range select flagged
//   on err_o; WIDTH < 2 rejected at elaboration. Clock - the clock of the
//   parent block, all signals are synchronous to it.
// Date: 2026-09-29
module onehot_decoder #(
  parameter int WIDTH      = 8,
  parameter bit REGISTERED = 1'b0
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     en_i,
  input  logic [$clog2(WIDTH)-1:0] sel_i,
  output logic [WIDTH-1:0]         onehot_o,
  output logic                     err_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (WIDTH < 2) begin : g_bw $error("onehot_decoder: WIDTH must be >= 2"); end
  logic [WIDTH-1:0] oh_c; logic e_c;
  always_comb begin
    oh_c = '0; e_c = 1'b0;
    if (en_i) begin
      if (32'(sel_i) < WIDTH) oh_c[sel_i] = 1'b1; else e_c = 1'b1;
    end
  end
  if (REGISTERED) begin : g_reg
    always_ff @(posedge clk) begin
      if (!rst_n) begin onehot_o <= '0; err_o <= 1'b0; end
      else begin onehot_o <= oh_c; err_o <= e_c; end
    end
  end else begin : g_comb
    assign onehot_o = oh_c; assign err_o = e_c;
  end
endmodule
