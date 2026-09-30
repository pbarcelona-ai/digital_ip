// ***************
// Filename: timestamp_counter.sv
// Author: Paul Barcelona
// Description: Free-running system timestamp counter. Version 1.0.0.
//   WIDTH-bit counter incrementing on every tick_i (tie to 1 for clk
//   resolution, or use clock_enable for microseconds). clear_i zeroes it
//   and load_i loads a value. capture_i latches the count into capture_o
//   (one clock later, with cap_valid_o) so software can read a coherent
//   snapshot of a wide value; TS_CAPTURE_EDGE adds a synchronized event
//   input for external timestamping. Clock - clk. Reset - synchronous
//   active low, count 0. Latency - capture_o valid 1 clock after
//   capture_i. Rollover - wraps silently; wrap_o pulses on overflow.
//   Errors - WIDTH < 2 rejected at elaboration.
// Date: 2026-09-29
module timestamp_counter #(
  parameter int WIDTH = 64
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             tick_i,
  input  logic             clear_i,
  input  logic             load_i,
  input  logic [WIDTH-1:0] load_val_i,
  input  logic             capture_i,
  output logic [WIDTH-1:0] count_o,
  output logic [WIDTH-1:0] capture_o,
  output logic             cap_valid_o,
  output logic             wrap_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (WIDTH < 2) begin : g_bad $error("timestamp_counter: WIDTH must be >= 2"); end
  always_ff @(posedge clk) begin
    if (!rst_n) begin count_o <= '0; capture_o <= '0; cap_valid_o <= 1'b0; wrap_o <= 1'b0; end
    else begin
      wrap_o <= 1'b0; cap_valid_o <= capture_i;
      if (capture_i) capture_o <= count_o;
      if (clear_i) count_o <= '0;
      else if (load_i) count_o <= load_val_i;
      else if (tick_i) begin count_o <= count_o + 1'b1; wrap_o <= (count_o == '1); end
    end
  end
endmodule
