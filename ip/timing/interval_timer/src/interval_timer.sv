// ***************
// Filename: interval_timer.sv
// Author: FPGA Cores 4 U
// Description: Programmable interval timer. Version 1.0.0. Counts
//   prescaled ticks and raises a one-clock irq_o / tick_o every interval_i
//   ticks. AUTO_RELOAD mode repeats forever; one-shot mode (auto_i=0)
//   stops after the first event. Prescaler divides clk by prescale_i+1.
//   start_i starts (or restarts) the timer, stop_i halts it, and
//   remaining_o shows the ticks left. The interval and prescaler may be
//   rewritten while running and take effect at the next reload. Clock -
//   clk. Reset - synchronous active low, stopped. Latency - first event
//   interval*(prescale+1) clocks after start_i. Errors - interval_i = 0 is
//   invalid: start is refused and err_o pulses.
// Date: 2026-09-29
module interval_timer #(
  parameter int WIDTH   = 32,
  parameter int PRES_W  = 16
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              start_i,
  input  logic              stop_i,
  input  logic              auto_i,           // 1 = auto reload
  input  logic [WIDTH-1:0]  interval_i,
  input  logic [PRES_W-1:0] prescale_i,
  output logic              running_o,
  output logic              tick_o,           // one clock per interval
  output logic [WIDTH-1:0]  remaining_o,
  output logic              err_o             // start refused (interval 0)
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (WIDTH < 2 || PRES_W < 1) begin : g_bad $error("interval_timer: bad widths"); end
  logic [PRES_W-1:0] pc; wire ptick = (pc >= prescale_i);
  always_ff @(posedge clk) begin
    if (!rst_n) begin running_o <= 1'b0; tick_o <= 1'b0; remaining_o <= '0; pc <= '0; err_o <= 1'b0; end
    else begin
      tick_o <= 1'b0; err_o <= 1'b0;
      if (stop_i) running_o <= 1'b0;
      else if (start_i) begin
        if (interval_i == '0) err_o <= 1'b1;
        else begin running_o <= 1'b1; remaining_o <= interval_i; pc <= '0; end
      end else if (running_o) begin
        if (ptick) begin
          pc <= '0;
          if (remaining_o == 1) begin
            tick_o <= 1'b1;
            if (auto_i && interval_i != '0) remaining_o <= interval_i;
            else begin running_o <= 1'b0; remaining_o <= '0; end
          end else remaining_o <= remaining_o - 1'b1;
        end else pc <= pc + 1'b1;
      end
    end
  end
endmodule
