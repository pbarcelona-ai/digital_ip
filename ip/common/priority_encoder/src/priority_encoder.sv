// ***************
// Filename: priority_encoder.sv
// Author: FPGA Cores 4 U
// Description: Priority encoder. Version 1.0.0. Encodes the highest-priority
//   asserted request: LSB_HIGH=1 gives bit 0 the highest priority, LSB_HIGH=0
//   gives the MSB. Outputs the index, a one-hot vector and a valid flag.
//   REGISTERED=1 adds one output register stage (latency 1, synchronous reset
//   to invalid); otherwise the module is purely combinational (latency 0) and
//   clk/rst_n are unused. Timing - log2(WIDTH) LUT levels; register the
//   output for wide vectors at 100 MHz. Errors - WIDTH < 2 rejected at
//   elaboration; idx_o is 0 when valid_o is low. Clock - the clock of the
//   parent block, all signals are synchronous to it.
// Date: 2026-09-29
module priority_encoder #(
  parameter int WIDTH      = 8,
  parameter bit LSB_HIGH   = 1'b1,
  parameter bit REGISTERED = 1'b0
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [WIDTH-1:0]         req_i,
  output logic [$clog2(WIDTH)-1:0] idx_o,
  output logic [WIDTH-1:0]         onehot_o,
  output logic                     valid_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam int IW = $clog2(WIDTH);
  if (WIDTH < 2) begin : g_bw $error("priority_encoder: WIDTH must be >= 2"); end
  logic [IW-1:0] idx_c;
  logic [WIDTH-1:0] oh_c;
  logic v_c;
  always_comb begin
    idx_c = '0;
    oh_c = '0;
    v_c = 1'b0;
    if (LSB_HIGH) begin
      for (int i = WIDTH-1; i >= 0; i--) if (req_i[i]) begin
        idx_c = IW'(i);
        oh_c = '0;
        oh_c[i] = 1'b1;
        v_c = 1'b1;
      end
    end else begin
      for (int i = 0; i < WIDTH; i++) if (req_i[i]) begin
        idx_c = IW'(i);
        oh_c = '0;
        oh_c[i] = 1'b1;
        v_c = 1'b1;
      end
    end
  end
  if (REGISTERED) begin : g_reg
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        idx_o <= '0;
        onehot_o <= '0;
        valid_o <= 1'b0;
      end
      else begin
        idx_o <= idx_c;
        onehot_o <= oh_c;
        valid_o <= v_c;
      end
    end
  end else begin : g_comb
    assign idx_o = idx_c;
    assign onehot_o = oh_c;
    assign valid_o = v_c;
  end
endmodule
