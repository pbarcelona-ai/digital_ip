// ***************
// Filename: pcie_axis_to_dw.sv
// Author: Paul Barcelona
// Description: Converts a 64 bit AXI-Stream TLP interface (tkeep, tlast,
//   first DW in bits 31:0) into a 32 bit double-word stream with a last flag.
//   A single beat register keeps all outputs registered, and the next beat is
//   accepted in the same cycle the last DW of the current beat leaves.
//   Version 1.0.0. Clock - the clock of the parent block, all signals are
//   synchronous to it. Reset - synchronous, driven by the parent block.
//   Latency - as documented in the parent block, fixed and independent of
//   data. Errors - none reported here, out-of-range parameters stop
//   elaboration or are handled by the parent block.
//   synchronous to it. Reset - synchronous, driven by the parent block.
//   Latency - as documented in the parent block, fixed and independent of
//   data. Errors - none reported here, out-of-range parameters stop
//   elaboration or are handled by the parent block.
// Date: 2026-09-29
module pcie_axis_to_dw (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [63:0] s_tdata,
  input  logic [7:0]  s_tkeep,
  input  logic        s_tlast,
  input  logic        s_tvalid,
  output logic        s_tready,
  output logic [31:0] dw_data,
  output logic        dw_last,
  output logic        dw_valid,
  input  logic        dw_ready
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  logic [63:0] beat_q;
  logic        keep_hi_q, last_q, vld_q, phase;   // phase 1 = upper DW

  // Output selection
  assign dw_valid = vld_q;
  assign dw_data  = phase ? beat_q[63:32] : beat_q[31:0];
  assign dw_last  = last_q & (phase | ~keep_hi_q);

  wire final_dw = vld_q & dw_ready & (phase | ~keep_hi_q);  // beat consumed
  assign s_tready = ~vld_q | final_dw;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      vld_q <= 1'b0; phase <= 1'b0; beat_q <= '0; keep_hi_q <= 1'b0; last_q <= 1'b0;
    end else begin
      if (vld_q & dw_ready & ~final_dw) phase <= 1'b1;       // lower DW sent
      if (final_dw) begin vld_q <= 1'b0; phase <= 1'b0; end
      if (s_tvalid & s_tready) begin                          // load new beat
        vld_q     <= 1'b1;
        beat_q    <= s_tdata;
        keep_hi_q <= s_tkeep[4];
        last_q    <= s_tlast;
        phase     <= 1'b0;
      end
    end
  end
endmodule
