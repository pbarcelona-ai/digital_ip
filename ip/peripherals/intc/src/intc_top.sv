// ***************
// Filename: intc_top.sv
// Author: Paul Barcelona
// Description: Interrupt controller IP with NUM_IRQ sources. Each source
//   has enable, edge or level type, polarity, and software set. Edge
//   sources latch into a pending register cleared by write-1-to-clear,
//   level sources follow the input. A lowest-index-wins priority encoder
//   reports the active vector (pipelined) and the irq output. Map - 0x00
//   ENABLE, 0x04 EDGE_TYPE, 0x08 ACTIVE_LOW, 0x0C PENDING (W1C for edge
//   bits), 0x10 SOFT_SET (write), 0x14 VECTOR [4:0]=id [31]=valid, 0x18
//   MASKED_PENDING. Version 1.0.0. Clock - single clock aclk, every input
//   is synchronous to it unless a two-flop synchronizer is mentioned.
//   Reset - synchronous active low aresetn, registers take the documented
//   reset values. Latency - AXI-Lite write response and read data follow
//   the request by about 2 to 3 clocks (ip_axil_regs, registered read
//   path). Timing - registered outputs, no combinational path from the bus
//   to the pins. Errors - out of range AXI-Lite accesses return SLVERR;
//   illegal parameter values stop elaboration with an $error.
// Date: 2026-09-29
module intc_top #(
  parameter int NUM_IRQ = 16             // number of sources (<= 32)
) (
  input  logic        aclk,
  input  logic        aresetn,
  // AXI4-Lite slave (register access)
  input  logic [7:0]  s_axil_awaddr,
  input  logic        s_axil_awvalid,
  output logic        s_axil_awready,
  input  logic [31:0] s_axil_wdata,
  input  logic [3:0]  s_axil_wstrb,
  input  logic        s_axil_wvalid,
  output logic        s_axil_wready,
  output logic [1:0]  s_axil_bresp,
  output logic        s_axil_bvalid,
  input  logic        s_axil_bready,
  input  logic [7:0]  s_axil_araddr,
  input  logic        s_axil_arvalid,
  output logic        s_axil_arready,
  output logic [31:0] s_axil_rdata,
  output logic [1:0]  s_axil_rresp,
  output logic        s_axil_rvalid,
  input  logic        s_axil_rready,
  input  logic [NUM_IRQ-1:0] irq_i,
  output logic               irq_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (NUM_IRQ < 1 || NUM_IRQ > 32) begin : g_chk_n $error("%m: NUM_IRQ must be 1..32"); end

`ifndef SYNTHESIS
  // ---- immediate assertions (simulation only; skipped by synthesis) ----
  logic ip_chk_b_q, ip_chk_r_q;
  always @(posedge aclk) begin
    if (aresetn) begin
      ip_chk_b_q <= s_axil_bvalid & ~s_axil_bready;
      ip_chk_r_q <= s_axil_rvalid & ~s_axil_rready;
      assert (s_axil_bresp == 2'b00 || s_axil_bresp == 2'b10) else $error("%m: reserved BRESP value");
      assert (s_axil_rresp == 2'b00 || s_axil_rresp == 2'b10) else $error("%m: reserved RRESP value");
      if (ip_chk_b_q) assert (s_axil_bvalid) else $error("%m: BVALID dropped before BREADY");
      if (ip_chk_r_q) assert (s_axil_rvalid) else $error("%m: RVALID dropped before RREADY");
    end else begin ip_chk_b_q <= 1'b0; ip_chk_r_q <= 1'b0; end
  end
`endif

  logic [7*32-1:0] regs, rd;
  logic [6:0]      wr_pulse;
  logic [31:0]     wr_data;
  ip_axil_regs #(.ADDR_W(8), .NREG(7)) u_regs (
.aclk, .aresetn, .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready, .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready, .s_axil_bresp, .s_axil_bvalid, .s_axil_bready, .s_axil_araddr, .s_axil_arvalid, .s_axil_arready, .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .reg_o(regs), .wr_pulse_o(wr_pulse), .wr_data_o(wr_data), .rd_i(rd));

  wire [NUM_IRQ-1:0] en   = regs[0*32 +: NUM_IRQ];
  wire [NUM_IRQ-1:0] edg  = regs[1*32 +: NUM_IRQ];
  wire [NUM_IRQ-1:0] pol  = regs[2*32 +: NUM_IRQ];
  wire [NUM_IRQ-1:0] wd   = wr_data[NUM_IRQ-1:0];

  // Synchronize and normalize polarity (active high internally)
  (* async_reg = "true" *) logic [NUM_IRQ-1:0] s1, s2;
  logic [NUM_IRQ-1:0] prev, lvl;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin s1 <= '0; s2 <= '0; prev <= '0; lvl <= '0; end
    else begin s1 <= irq_i; s2 <= s1; lvl <= s2 ^ pol; prev <= lvl; end
  end
  wire [NUM_IRQ-1:0] rise = lvl & ~prev;

  // Edge pending latch (W1C) with software set
  logic [NUM_IRQ-1:0] pend_edge;
  always_ff @(posedge aclk) begin
    if (!aresetn) pend_edge <= '0;
    else pend_edge <= (pend_edge & ~(wr_pulse[3] ? wd : '0)) | (rise & edg)
                    | (wr_pulse[4] ? wd : '0);
  end
  // Level sources follow the input; software set works for them via edge latch
  wire [NUM_IRQ-1:0] pending = (edg & pend_edge) | (~edg & lvl) | (~edg & pend_edge);
  wire [NUM_IRQ-1:0] masked  = pending & en;

  // Pipelined priority encoder (lowest index first)
  logic [4:0] vec; logic vec_v;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin vec <= '0; vec_v <= 1'b0; end
    else begin
      vec_v <= 1'b0; vec <= '0;
      for (int i = NUM_IRQ-1; i >= 0; i--)
        if (masked[i]) begin vec <= 5'(i); vec_v <= 1'b1; end
    end
  end
  assign irq_o = vec_v;
  assign rd = {32'(masked), {vec_v, 26'd0, vec}, 32'd0, 32'(pending), regs[2*32 +: 32], regs[1*32 +: 32], regs[0 +: 32]};
endmodule
