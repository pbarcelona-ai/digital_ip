// ***************
// Filename: axil_core_gate.sv
// Author: FPGA Cores 4 U
// Description: Gate of a CPU window into the core logic (cpu_clk), in front
//   of its axi4_lite_cdc. axi4_lite_cdc needs both of its sides reset
//   together, and its pix_clk side is reset with the core logic
//   (CORE_RESET), not with the CPU. The gate passes the window (s_axil ->
//   m_axil) only while the core logic is out of reset (core_up_i: pix_rst_n
//   synchronised to cpu_clk; the pix_clk side is released first and reset
//   first) and pass_o holds the bridge's cpu_clk side in reset otherwise.
//   Closed while CORE_RESET = 0 (core_rel_i), it answers every access itself
//   with SLVERR (read data 0), so the CPU never waits on a bridge in reset;
//   an access in flight when the core logic goes into reset completes with
//   SLVERR. Closed while CORE_RESET = 1 (the core logic being released), a
//   new access waits for the gate to open, as it would have waited in the
//   bridge. It opens only between accesses. (With the core clock gated off
//   by SYSCTL CLK_EN the core logic never leaves reset, and such an access
//   waits forever.) Version 1.0.0 (from video_processor.sv's EXT gate).
//   Parameters: none (the address width is the interfaces').
//   Clock - clk (cpu_clk). Reset - synchronous active low rst_n (the CPU's).
//   Clock-domain crossings - none here (core_up_i comes through bit_sync).
// Date: 2026-10-26
module axil_core_gate (
  input  logic          clk,                     // cpu_clk
  input  logic          rst_n,                   // the CPU's reset
  input  logic          core_up_i,               // the core logic out of reset (in cpu_clk)
  input  logic          core_rel_i,              // SYSCTL CORE_RESET
  output logic          pass_o,                  // gate open (the bridge's cpu_clk side out of reset)
  // s_axil: axil_if.slave (ip/shared/src/interfaces/axil_if.sv), ADDR_W of the window
  axil_if.slave         s_axil,
  // m_axil: axil_if.master (ip/shared/src/interfaces/axil_if.sv), ADDR_W of the window
  axil_if.master        m_axil
);
  logic hold;                                    // gate closed, core logic being released: wait
  logic got_aw, got_w, got_ar;                   // CPU handshakes of the access in flight
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pass_o <= 1'b0;
      got_aw <= 1'b0;
      got_w <= 1'b0;
      got_ar <= 1'b0;
    end else begin
      if (s_axil.bvalid && s_axil.bready) begin
        got_aw <= 1'b0;
        got_w <= 1'b0;
      end
      if (s_axil.rvalid && s_axil.rready) got_ar <= 1'b0;
      if (s_axil.awvalid && s_axil.awready) got_aw <= 1'b1;
      if (s_axil.wvalid && s_axil.wready) got_w <= 1'b1;
      if (s_axil.arvalid && s_axil.arready) got_ar <= 1'b1;
      // open only while holding (no CPU handshake can happen in that cycle); close as soon as
      // CORE_RESET clears, before pix_rst_n is even synchronised back
      if (!core_up_i || !core_rel_i) pass_o <= 1'b0;
      else if (!got_aw && !got_w && !got_ar) pass_o <= 1'b1;
    end
  end
  assign hold = !pass_o && core_rel_i && !got_aw && !got_w && !got_ar;
  assign m_axil.awaddr  = s_axil.awaddr;
  assign m_axil.wdata   = s_axil.wdata;
  assign m_axil.wstrb   = s_axil.wstrb;
  assign m_axil.araddr  = s_axil.araddr;
  assign m_axil.awvalid = s_axil.awvalid && pass_o;
  assign m_axil.wvalid  = s_axil.wvalid && pass_o;
  assign m_axil.bready  = s_axil.bready && pass_o;
  assign m_axil.arvalid = s_axil.arvalid && pass_o;
  assign m_axil.rready  = s_axil.rready && pass_o;
  assign s_axil.awready = pass_o ? m_axil.awready : !hold && !got_aw;
  assign s_axil.wready  = pass_o ? m_axil.wready : !hold && !got_w;
  assign s_axil.bvalid  = pass_o ? m_axil.bvalid : got_aw && got_w;
  assign s_axil.bresp   = pass_o ? m_axil.bresp : 2'b10;     // SLVERR
  assign s_axil.arready = pass_o ? m_axil.arready : !hold && !got_ar;
  assign s_axil.rvalid  = pass_o ? m_axil.rvalid : got_ar;
  assign s_axil.rdata   = pass_o ? m_axil.rdata : 32'd0;
  assign s_axil.rresp   = pass_o ? m_axil.rresp : 2'b10;     // SLVERR
endmodule
