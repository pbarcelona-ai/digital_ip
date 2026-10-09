// ***************
// Filename: timeout_timer.sv
// Author: FPGA Cores 4 U
// Description: Inactivity timeout timer. Version 1.0.0. Counts clocks
//   since the last activity_i pulse; when the count reaches timeout_i,
//   expired_o goes high (level, registered) and timeout_pulse_o pulses
//   once. Any activity clears the count and expired_o. timeout_i = 0
//   disables the timer. Clock - clk (use ce_i to count slower ticks).
//   Reset - synchronous active low, not expired. Latency - expired_o rises
//   timeout_i + 1 clocks after the last activity. Errors - WIDTH < 1
//   rejected at elaboration; the counter saturates at timeout_i so it
//   never wraps.
// Date: 2026-09-29
module timeout_timer #(
  parameter int WIDTH = 24
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             ce_i,         // tick enable (1 = every clock)
  input  logic             activity_i,   // restart the timer
  input  logic [WIDTH-1:0] timeout_i,    // ticks; 0 = disabled
  output logic             expired_o,
  output logic             timeout_pulse_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (WIDTH < 1) begin : g_bw $error("timeout_timer: WIDTH must be >= 1"); end
  logic [WIDTH-1:0] cnt;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cnt <= '0;
      expired_o <= 1'b0;
      timeout_pulse_o <= 1'b0;
    end
    else begin
      timeout_pulse_o <= 1'b0;
      if (activity_i || timeout_i == '0) begin
        cnt <= '0;
        expired_o <= 1'b0;
      end
      else if (ce_i && !expired_o) begin
        if (cnt + 1'b1 >= timeout_i) begin
          expired_o <= 1'b1;
          timeout_pulse_o <= 1'b1;
          cnt <= timeout_i;
        end
        else cnt <= cnt + 1'b1;
      end
    end
  end
endmodule
