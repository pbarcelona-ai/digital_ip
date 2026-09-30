// ***************
// Filename: error_status.sv
// Author: Paul Barcelona
// Description: Sticky hardware error/status register. Version 1.0.0. NERR
//   error inputs (level or pulse) set sticky bits in status_o. Software
//   clears bits with clr_mask_i (write-1-to-clear style, one clock, a
//   simultaneous new error wins) or all with clr_all_i. irq_mask_i gates
//   irq_o = |(status_o & irq_mask_i), which is a level until cleared.
//   first_idx_o holds the lowest index that fired in the earliest error
//   clock since the last clear (first_valid_o marks it), useful for root-
//   cause logging, and count_o counts total error clocks (saturating).
//   Clock - clk. Reset - synchronous active low, all clear. Latency -
//   status_o is registered, 1 clock after err_i; irq_o adds combinational
//   AND-OR. Errors - NERR < 1 rejected at elaboration.
// Date: 2026-09-29
module error_status #(
  parameter int NERR    = 8,
  parameter int CNT_W   = 16
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [NERR-1:0]          err_i,
  input  logic [NERR-1:0]          clr_mask_i,
  input  logic                     clr_all_i,
  input  logic [NERR-1:0]          irq_mask_i,
  output logic [NERR-1:0]          status_o,
  output logic [$clog2(NERR > 1 ? NERR : 2)-1:0] first_idx_o,
  output logic                     first_valid_o,
  output logic [CNT_W-1:0]         count_o,
  output logic                     irq_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (NERR < 1 || CNT_W < 1) begin : g_bad $error("error_status: bad parameters"); end
  always_ff @(posedge clk) begin
    if (!rst_n) begin status_o <= '0; first_idx_o <= '0; first_valid_o <= 1'b0; count_o <= '0; end
    else begin
      if (clr_all_i) begin status_o <= err_i; first_valid_o <= 1'b0; count_o <= '0; end
      else status_o <= (status_o & ~clr_mask_i) | err_i;
      if (|err_i) begin
        if (!first_valid_o || clr_all_i) begin
          first_valid_o <= 1'b1;
          for (int i = NERR-1; i >= 0; i--) if (err_i[i]) first_idx_o <= i[$clog2(NERR > 1 ? NERR : 2)-1:0];
        end
        if (count_o != '1) count_o <= (clr_all_i ? '0 : count_o) + 1'b1;
      end
    end
  end
  assign irq_o = |(status_o & irq_mask_i);
endmodule
