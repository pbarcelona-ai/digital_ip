// ***************
// Filename: edge_detect.sv
// Author: FPGA Cores 4 U
// Description: Edge detector for WIDTH signals. Version 1.0.0. EDGE
//   selects rising (0), falling (1) or both (2). Optional two-flop input
//   synchronizer (SYNC_INPUT=1) for asynchronous inputs. Clock - clk;
//   input must be synchronous unless SYNC_INPUT=1. Reset - synchronous
//   active low, previous-value register resets to RESET_LEVEL so no false
//   edge appears after reset. Latency - pulse_o is registered: 1 clock
//   after the input changes (3 with SYNC_INPUT). Output - one clock wide
//   pulse. Errors - invalid EDGE or WIDTH rejected at elaboration.
// Date: 2026-09-29
module edge_detect #(
  parameter int WIDTH       = 1,
  parameter int EDGE        = 0,         // 0 rise, 1 fall, 2 both
  parameter bit SYNC_INPUT  = 1'b0,
  parameter bit RESET_LEVEL = 1'b0       // assumed idle input level
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic [WIDTH-1:0] d_i,
  output logic [WIDTH-1:0] pulse_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (WIDTH < 1) begin : g_bad_w $error("edge_detect: WIDTH must be >= 1"); end
  if (EDGE < 0 || EDGE > 2) begin : g_bad_e $error("edge_detect: EDGE must be 0..2"); end
  logic [WIDTH-1:0] cur, prev, s1, s2;
  if (SYNC_INPUT) begin : g_sync
    (* async_reg = "true" *) logic [WIDTH-1:0] a, b;
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        a <= {WIDTH{RESET_LEVEL}};
        b <= {WIDTH{RESET_LEVEL}};
      end
      else begin
        a <= d_i;
        b <= a;
      end
    end
    assign cur = b;
  end else begin : g_nosync
    assign cur = d_i;
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      prev <= {WIDTH{RESET_LEVEL}};
      pulse_o <= '0;
    end
    else begin
      prev <= cur;
      case (EDGE)
        0: pulse_o <= cur & ~prev;
        1: pulse_o <= ~cur & prev;
        default: pulse_o <= cur ^ prev;
      endcase
    end
  end
endmodule
