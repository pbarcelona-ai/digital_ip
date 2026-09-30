// ***************
// Filename: fallthrough_fifo.sv
// Author: Paul Barcelona
// Description: First-word-fall-through FIFO with valid/ready handshakes.
//   Version 1.0.0. The oldest word is presented on m_data_o as soon as the
//   FIFO is not empty (m_valid_o), with no read latency; m_ready_i pops
//   it. Storage is a register-array with asynchronous read (distributed
//   RAM style), intended for shallow FIFOs (DEPTH <= 64); use ip_axis_fifo
//   for deep block-RAM FIFOs. Clock - clk. Reset - synchronous active low,
//   empty. Latency - 1 clock from a write into an empty FIFO to m_valid_o.
//   Overflow - s_ready_o is low when full, so a compliant source never
//   overflows. Errors - DEPTH must be a power of two >= 2 (rejected at
//   elaboration).
// Date: 2026-09-29
module fallthrough_fifo #(
  parameter int WIDTH = 32,
  parameter int DEPTH = 16
) (
  input  logic                   clk,
  input  logic                   rst_n,
  input  logic [WIDTH-1:0]       s_data_i,
  input  logic                   s_valid_i,
  output logic                   s_ready_o,
  output logic [WIDTH-1:0]       m_data_o,
  output logic                   m_valid_o,
  input  logic                   m_ready_i,
  output logic [$clog2(DEPTH):0] level_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam int AW = $clog2(DEPTH);
  if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0) begin : g_bad $error("fallthrough_fifo: DEPTH must be a power of two >= 2"); end
  logic [WIDTH-1:0] mem [0:DEPTH-1];
  logic [AW:0] wptr, rptr;
  assign level_o   = wptr - rptr;
  assign s_ready_o = (level_o != DEPTH);
  assign m_valid_o = (wptr != rptr);
  assign m_data_o  = mem[rptr[AW-1:0]];
  always_ff @(posedge clk) begin
    if (!rst_n) begin wptr <= '0; rptr <= '0; end
    else begin
      if (s_valid_i & s_ready_o) begin mem[wptr[AW-1:0]] <= s_data_i; wptr <= wptr + 1'b1; end
      if (m_valid_o & m_ready_i) rptr <= rptr + 1'b1;
    end
  end
endmodule
