// ***************
// Filename: fixed_recip.sv
// Author: Paul Barcelona
// Description: Reusable IP. Iterative shift/subtract unsigned Q16.16
// reciprocal divider (33 cycles). Used in the config plane (once
// per register write, not per pixel) and, since this project
// added fisheye/panoramic/perspective support, instantiated a
// second time inside coord_gen's per-pixel "slow path".
// Date: September 26, 2026
// ***************
// =============================================================================
// fixed_recip.sv
//
// Iterative (restoring, shift/subtract) unsigned reciprocal: given an
// unsigned Q16.16 operand D > 0, computes result = floor(2^32 / D_raw),
// which is exactly 1/D expressed in Q16.16.
//
// This runs once whenever IMG_WIDTH, IMG_HEIGHT, SCALE or CENTER_* are
// (re)programmed over AXI-Lite -- NOT once per pixel -- so a 33-cycle
// iterative divider is a perfectly good, cheap, synthesizable choice and
// keeps a division operator out of the per-pixel critical path entirely.
// =============================================================================
module fixed_recip #(
  parameter int W = 32
) (
  input  logic         clk,
  input  logic         rst_n,
  input  logic         start,        // pulse to begin
  input  logic [W-1:0] operand,      // unsigned Q16.16, treated as >0 (0 -> saturate)
  output logic [W-1:0] result,       // unsigned Q16.16 reciprocal (saturates to all-1s)
  output logic         busy,
  output logic         done          // one-cycle pulse
);

  typedef enum logic [1:0] {S_IDLE, S_RUN, S_DONE} state_t;
  state_t state;

  logic [W-1:0]           divisor;
  logic [W:0]             rem;
  logic [W:0]             quot;
  logic [$clog2(W+2)-1:0] step;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state  <= S_IDLE;
      busy   <= 1'b0;
      done   <= 1'b0;
      result <= '0;
      divisor <= '0; rem <= '0; quot <= '0; step <= '0;
    end else begin
      done <= 1'b0;
      unique case (state)
        S_IDLE: begin
          busy <= 1'b0;
          if (start) begin
            divisor <= (operand == '0) ? {{(W-1){1'b0}}, 1'b1} : operand;
            rem     <= {{W{1'b0}}, 1'b1};   // effective dividend = 2^W, fed in 1 bit at a time
            quot    <= '0;
            step    <= '0;
            busy    <= 1'b1;
            state   <= S_RUN;
          end
        end
        S_RUN: begin
          logic [W:0] div_ext;
          div_ext = {1'b0, divisor};
          if (rem >= div_ext) begin
            rem  <= (rem - div_ext) << 1;
            quot <= {quot[W-1:0], 1'b1};
          end else begin
            rem  <= rem << 1;
            quot <= {quot[W-1:0], 1'b0};
          end
          if (step == W) state <= S_DONE;
          else           step  <= step + 1'b1;
        end
        S_DONE: begin
          result <= quot[W] ? {W{1'b1}} : quot[W-1:0]; // saturate on overflow (D < 1 ULP)
          busy   <= 1'b0;
          done   <= 1'b1;
          state  <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
