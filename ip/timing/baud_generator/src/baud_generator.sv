// ***************
// Filename: baud_generator.sv
// Author: Paul Barcelona
// Description: Programmable serial baud-rate tick generator. Version
//   1.0.0. A fractional (NCO) divider produces tick_os_o at
//   BAUD*OVERSAMPLE ticks per second and tick_baud_o once every OVERSAMPLE
//   oversample ticks, with no cumulative error (average frequency exact to
//   2^-ACC_W of the clock). The nominal increment is computed at
//   elaboration from CLK_HZ, BAUD and OVERSAMPLE; set use_reg_i=1 to
//   override it at run time with inc_i (inc =
//   round(BAUD*OVERSAMPLE*2^ACC_W/CLK_HZ)). Works at any clock frequency
//   as long as BAUD*OVERSAMPLE <= CLK_HZ/2. Clock - clk. Reset -
//   synchronous active low. sync_i restarts the bit phase (used by
//   receivers on the start edge). Latency - ticks are registered, one
//   clock after the accumulator overflows. Jitter - at most one clk period
//   on each tick. Errors - unreachable rates (increment 0 or >=
//   2^(ACC_W-1)) rejected at elaboration.
// Date: 2026-09-29
module baud_generator #(
  parameter int CLK_HZ     = 100_000_000,
  parameter int BAUD       = 115_200,
  parameter int OVERSAMPLE = 16,
  parameter int ACC_W      = 32
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             en_i,
  input  logic             use_reg_i,
  input  logic [ACC_W-1:0] inc_i,
  input  logic             sync_i,          // restart accumulator and bit counter
  output logic             tick_os_o,       // oversample tick
  output logic             tick_baud_o      // one per bit time
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam longint unsigned INC_L = ((64'd1 << ACC_W) * BAUD * OVERSAMPLE + CLK_HZ / 2) / CLK_HZ;
  localparam logic [ACC_W-1:0] INC_NOM = ACC_W'(INC_L);
  if (INC_L == 0 || INC_L >= (64'd1 << (ACC_W - 1))) begin : g_bad
    $error("baud_generator: BAUD*OVERSAMPLE not reachable from CLK_HZ");
  end
  if (OVERSAMPLE < 1) begin : g_bo $error("baud_generator: OVERSAMPLE must be >= 1"); end
  logic [ACC_W-1:0] acc; logic [ACC_W:0] sum; logic [$clog2(OVERSAMPLE > 1 ? OVERSAMPLE : 2)-1:0] osc;
  assign sum = {1'b0, acc} + {1'b0, use_reg_i ? inc_i : INC_NOM};
  always_ff @(posedge clk) begin
    if (!rst_n || !en_i || sync_i) begin
      acc <= '0; tick_os_o <= 1'b0; tick_baud_o <= 1'b0; osc <= '0;
    end else begin
      acc <= sum[ACC_W-1:0]; tick_os_o <= sum[ACC_W]; tick_baud_o <= 1'b0;
      if (sum[ACC_W]) begin
        if (osc == OVERSAMPLE - 1) begin osc <= '0; tick_baud_o <= 1'b1; end
        else osc <= osc + 1'b1;
      end
    end
  end
endmodule
