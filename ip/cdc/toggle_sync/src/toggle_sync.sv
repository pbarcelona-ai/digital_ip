// ***************
// Filename: toggle_sync.sv
// Author: FPGA Cores 4 U
// Description: Event transfer between clock domains using a toggle level.
//   Version 1.0.0. Every one-clock event_i pulse in the source domain flips a
//   toggle flop; the destination synchronizes the toggle and emits event_o
//   for each change. No handshake, so events must be spaced at least STAGES+2
//   destination clocks apart (source clock period permitting) or they are
//   lost; use pulse_sync when spacing cannot be guaranteed. Clocks - src_clk
//   and dst_clk are unrelated. Reset - synchronous per domain, active low.
//   Latency - STAGES+1 dst clocks. Errors - none reported; STAGES<2 rejected
//   at elaboration. Clock - the clock of the parent block, all signals are
//   synchronous to it.
//   synchronous to it.
// Date: 2026-09-29
module toggle_sync #(
  parameter int STAGES = 2
) (
  input  logic src_clk,
  input  logic src_rst_n,
  input  logic event_i,                  // one-clock pulse, source domain
  input  logic dst_clk,
  input  logic dst_rst_n,
  output logic event_o,                  // one-clock pulse, destination domain
  output logic toggle_o                  // synchronized toggle level (dst domain)
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (STAGES < 2) begin : g_bad_stages
    $error("toggle_sync: STAGES must be >= 2");
  end
  logic tog;                             // source toggle
  always_ff @(posedge src_clk) begin
    if (!src_rst_n) tog <= 1'b0;
    else if (event_i) tog <= ~tog;
  end
  logic tog_s, tog_d;
  bit_sync #(.STAGES(STAGES)) u_sync (.clk(dst_clk), .rst_n(dst_rst_n), .d_i(tog), .q_o(tog_s));
  always_ff @(posedge dst_clk) begin
    if (!dst_rst_n) begin tog_d <= 1'b0; event_o <= 1'b0; end
    else begin tog_d <= tog_s; event_o <= tog_s ^ tog_d; end
  end
  assign toggle_o = tog_s;
endmodule
