// ***************
// Filename: fixed_recip.sv
// Author: FPGA Cores 4 U
// Description: Reusable IP. Iterative shift/subtract unsigned Q16.16
// reciprocal divider: result = floor(2^W / operand) (1/D in Q16.16 for
// W = 32), all ones when it does not fit (an operand of 0 is taken as 1).
// Used in the config plane (axi_lite_regs, once per geometry write) and in
// coord_gen's per-pixel slow path. Golden model: model/fixed_recip_model.py
// (bit and clock exact; tb/python).
// Timing: a start accepted in S_IDLE (clock edge 0) gives done one clock
// wide after edge W + 2 (34 for W = 32), result valid from then on; busy
// is high from edge 0 to edge W + 2; a start while busy is ignored.
// Clock - clk. Reset - synchronous active low rst_n. Clock-domain
// crossings - none.
// Date: 2026-10-21
// ***************
// =============================================================================
// fixed_recip.sv
//
// Iterative (restoring, shift/subtract) unsigned reciprocal: given an
// unsigned Q16.16 operand D > 0, computes result = floor(2^32 / D_raw),
// which is exactly 1/D expressed in Q16.16.
//
// An iterative divider is cheap and keeps a division operator out of the
// per-pixel critical path; the slow path accepts its W + 2 clocks per
// pixel for the three division models.
// =============================================================================
module fixed_recip #(
  parameter int W = 32
) (
  input  logic         clk,          // clock
  input  logic         rst_n,        // synchronous, active low
  input  logic         start,        // pulse to begin
  input  logic [W-1:0] operand,      // unsigned Q16.16, treated as >0 (0 -> saturate)
  output logic [W-1:0] result,       // unsigned Q16.16 reciprocal (saturates to all-1s)
  output logic         busy,         // a division is running
  output logic         done          // one-cycle pulse: result updated
);

  typedef enum logic [1:0] {S_IDLE, S_RUN, S_DONE} state_t;
  state_t state;

  logic [W-1:0]           divisor;
  logic [W:0]             rem;
  logic [W:0]             quot;
  logic [$clog2(W+2)-1:0] step;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state  <= S_IDLE;
      busy   <= 1'b0;
      done   <= 1'b0;
      result <= '0;
      divisor <= '0;
      rem <= '0;
      quot <= '0;
      step <= '0;
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
          if (step == $bits(step)'(W)) state <= S_DONE;
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
