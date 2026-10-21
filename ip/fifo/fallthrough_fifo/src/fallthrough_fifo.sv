// ***************
// Filename: fallthrough_fifo.sv
// Author: FPGA Cores 4 U
// Description: First-word-fall-through FIFO with valid/ready handshakes.
//   Version 1.0.0. The oldest word is presented on m_data_o as soon as the
//   FIFO is not empty (m_valid_o), with no read latency; m_ready_i pops
//   it. Storage is a register-array with asynchronous read (distributed
//   RAM style), intended for shallow FIFOs (DEPTH <= 64); use ip_axis_fifo
//   for deep block-RAM FIFOs. Clock - clk. Reset - synchronous active low,
//   empty. Latency - 1 clock from a write into an empty FIFO to m_valid_o.
//   Overflow - s_ready_o is low when full, so a compliant source never
//   overflows; a push into a full FIFO is refused even with a pop in the
//   same clock. Errors - DEPTH must be a power of two >= 2 (rejected at
//   elaboration). Golden model: model/fallthrough_fifo_model.py (clock
//   exact; tb/python).
// Date: 2026-10-21
module fallthrough_fifo #(
  parameter int WIDTH = 32,                      // word width, >= 1
  parameter int DEPTH = 16                       // words, a power of two >= 2 (intended <= 64)
) (
  input  logic                   clk,            // clock
  input  logic                   rst_n,          // synchronous, active low: empty
  input  logic [WIDTH-1:0]       s_data_i,       // word to push
  input  logic                   s_valid_i,      // push request
  output logic                   s_ready_o,      // not full
  output logic [WIDTH-1:0]       m_data_o,       // the oldest word (valid with m_valid_o)
  output logic                   m_valid_o,      // not empty
  input  logic                   m_ready_i,      // pop the oldest word
  output logic [$clog2(DEPTH):0] level_o         // words held
);
  /* verilator lint_off UNUSEDPARAM */             // version identification (library convention), not logic
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  /* verilator lint_on UNUSEDPARAM */
  localparam int AW = $clog2(DEPTH);
  if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0) begin : g_bad
    $error("fallthrough_fifo: DEPTH must be a power of two >= 2");
  end
  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [AW:0] wptr, rptr;
  assign level_o   = wptr - rptr;
  assign s_ready_o = (level_o != ($clog2(DEPTH)+1)'(DEPTH));
  assign m_valid_o = (wptr != rptr);
  assign m_data_o  = mem[rptr[AW-1:0]];
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wptr <= '0;
      rptr <= '0;
    end
    else begin
      if (s_valid_i & s_ready_o) begin
        mem[wptr[AW-1:0]] <= s_data_i;
        wptr <= wptr + 1'b1;
      end
      if (m_valid_o & m_ready_i) rptr <= rptr + 1'b1;
    end
  end
endmodule
