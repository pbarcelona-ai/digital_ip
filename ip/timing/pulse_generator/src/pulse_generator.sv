// ***************
// Filename: pulse_generator.sv
// Author: Paul Barcelona
// Description: Periodic or one-shot pulse generator. Version 1.0.0. In
//   continuous mode a pulse of width_i clocks is produced every period_i
//   clocks; in one-shot mode (oneshot_i=1) each trigger_i pulse produces
//   one pulse of width_i clocks (retriggers ignored while active). Period,
//   width and polarity may be changed on the fly; new values apply from
//   the next period start. width_i is clamped to period_i in continuous
//   mode. Clock - clk. Reset - synchronous active low, output idle
//   (inverted when INVERT). Latency - pulse_o starts 1 clock after the
//   period start or trigger. Errors - period_i = 0 disables output;
//   width_i = 0 gives no pulse; WIDTH < 2 rejected at elaboration.
// Date: 2026-09-29
module pulse_generator #(
  parameter int WIDTH  = 16,
  parameter bit INVERT = 1'b0
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             en_i,
  input  logic             oneshot_i,
  input  logic             trigger_i,
  input  logic [WIDTH-1:0] period_i,      // clocks per period (continuous mode)
  input  logic [WIDTH-1:0] width_i,       // pulse width in clocks
  output logic             pulse_o,
  output logic             start_o        // one clock at the start of each pulse
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (WIDTH < 2) begin : g_bad $error("pulse_generator: WIDTH must be >= 2"); end
  logic [WIDTH-1:0] pcnt, wcnt, w_lat, p_lat; logic active;
  logic raw;
  always_ff @(posedge clk) begin
    if (!rst_n || !en_i) begin
      pcnt <= '0; wcnt <= '0; active <= 1'b0; raw <= 1'b0; start_o <= 1'b0; w_lat <= '0; p_lat <= '0;
    end else begin
      start_o <= 1'b0;
      if (oneshot_i) begin
        if (!active) begin
          if (trigger_i && width_i != '0) begin active <= 1'b1; wcnt <= width_i - 1'b1; raw <= 1'b1; start_o <= 1'b1; end
          else raw <= 1'b0;
        end else if (wcnt == '0) begin active <= 1'b0; raw <= 1'b0; end
        else wcnt <= wcnt - 1'b1;
      end else begin
        if (period_i == '0) begin raw <= 1'b0; pcnt <= '0; end
        else begin
          if (pcnt == '0) begin
            // period start: latch new period/width
            p_lat <= period_i; w_lat <= (width_i > period_i) ? period_i : width_i;
            pcnt <= period_i - 1'b1;
            raw <= (width_i != '0); start_o <= (width_i != '0);
            wcnt <= ((width_i > period_i) ? period_i : width_i);
          end else begin
            pcnt <= pcnt - 1'b1;
            if (wcnt > 1) wcnt <= wcnt - 1'b1;
            if (wcnt <= 1) raw <= 1'b0;
          end
        end
      end
    end
  end
  assign pulse_o = raw ^ INVERT;
endmodule
