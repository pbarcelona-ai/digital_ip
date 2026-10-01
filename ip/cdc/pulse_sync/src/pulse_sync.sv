// ***************
// Filename: pulse_sync.sv
// Author: FPGA Cores 4 U
// Description: Pulse transfer between clock domains with full handshake.
//   Version 1.0.0. A toggle crosses to the destination and an acknowledge
//   toggle crosses back, so a new pulse is accepted only when the previous
//   one has completed (busy_o low). Pulses arriving while busy are dropped
//   and flagged on drop_o (one src clock) so nothing is lost silently. Clocks
//   - src_clk and dst_clk unrelated. Reset - synchronous per domain, active
//   low. Latency - about STAGES+2 dst clocks to pulse_o; busy clears after
//   ~2*STAGES+3 clocks of the slower domain. Errors - drop_o on overrun;
//   STAGES<2 rejected at elaboration. Clock - the clock of the parent block,
//   all signals are synchronous to it.
//   all signals are synchronous to it.
// Date: 2026-09-29
module pulse_sync #(
  parameter int STAGES = 2
) (
  input  logic src_clk,
  input  logic src_rst_n,
  input  logic pulse_i,                  // one-clock pulse, source domain
  output logic busy_o,                   // transfer in flight (source domain)
  output logic drop_o,                   // pulse_i ignored because busy
  input  logic dst_clk,
  input  logic dst_rst_n,
  output logic pulse_o                   // one-clock pulse, destination domain
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (STAGES < 2) begin : g_bad_stages
    $error("pulse_sync: STAGES must be >= 2");
  end
  logic req_tog, ack_tog, ack_s;
  always_ff @(posedge src_clk) begin
    if (!src_rst_n) begin req_tog <= 1'b0; drop_o <= 1'b0; end
    else begin
      drop_o <= pulse_i & busy_o;
      if (pulse_i & ~busy_o) req_tog <= ~req_tog;
    end
  end
  bit_sync #(.STAGES(STAGES)) u_ack (.clk(src_clk), .rst_n(src_rst_n), .d_i(ack_tog), .q_o(ack_s));
  assign busy_o = (req_tog != ack_s);

  logic req_s, req_d;
  bit_sync #(.STAGES(STAGES)) u_req (.clk(dst_clk), .rst_n(dst_rst_n), .d_i(req_tog), .q_o(req_s));
  always_ff @(posedge dst_clk) begin
    if (!dst_rst_n) begin req_d <= 1'b0; pulse_o <= 1'b0; ack_tog <= 1'b0; end
    else begin
      req_d <= req_s; pulse_o <= req_s ^ req_d; ack_tog <= req_s;
    end
  end
endmodule
