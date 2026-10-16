// ***************
// Filename: intc.sv
// Author: FPGA Cores 4 U
// Description: Interrupt controller logic with NUM_IRQ sources. Each source
//   has enable, edge or level type, polarity, and software set. Edge
//   sources latch into a pending register cleared by write-1-to-clear,
//   level sources follow the input. A lowest-index-wins priority encoder
//   reports the active vector (pipelined) and the irq output. Its registers
//   come and go on the cfg_* / sts_* ports; intc_top.sv is the block with
//   its AXI4-Lite register map (src/include/intc_regs.sv: ID "INTC" /
//   VERSION / DATE at 0x00-0x08, ENABLE 0x10, EDGE_TYPE 0x14, ACTIVE_LOW
//   0x18, PENDING 0x1C (W1C for edge bits), SOFT_SET 0x20 (write), VECTOR
//   0x24 [4:0] id [31] valid, MASKED 0x28). Clock - single clock aclk;
//   irq_i is synchronised by two flops. Reset - synchronous active low
//   aresetn. Errors - illegal parameter values stop elaboration with an
//   $error.
// Date: 2026-10-12
module intc #(
  parameter int NUM_IRQ = 16             // number of sources (1..32)
) (
  input  logic               aclk,
  input  logic               aresetn,
  input  logic [NUM_IRQ-1:0] irq_i,
  output logic               irq_o,
  // register ports
  // regs: intc_regs_if.core (src/include/intc_regs_if.sv)
  intc_regs_if.core regs
);
  if (NUM_IRQ < 1 || NUM_IRQ > 32) begin : g_chk_n $error("%m: NUM_IRQ must be 1..32"); end

  wire [NUM_IRQ-1:0] en   = regs.cfg_enable;
  wire [NUM_IRQ-1:0] edg  = regs.cfg_edge_type;
  wire [NUM_IRQ-1:0] pol  = regs.cfg_active_low;

  // Synchronize and normalize polarity (active high internally)
  (* async_reg = "true" *) logic [NUM_IRQ-1:0] s1, s2;
  logic [NUM_IRQ-1:0] prev, lvl;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      s1 <= '0;
      s2 <= '0;
      prev <= '0;
      lvl <= '0;
    end
    else begin
      s1 <= irq_i;
      s2 <= s1;
      lvl <= s2 ^ pol;
      prev <= lvl;
    end
  end
  wire [NUM_IRQ-1:0] rise = lvl & ~prev;

  // Edge pending latch (W1C) with software set
  logic [NUM_IRQ-1:0] pend_edge;
  always_ff @(posedge aclk) begin
    if (!aresetn) pend_edge <= '0;
    else pend_edge <= (pend_edge & ~(regs.cfg_pending_wr ? regs.cfg_pending : '0)) | (rise & edg)
                    | (regs.cfg_soft_set_wr ? regs.cfg_soft_set : '0);
  end
  // Level sources follow the input; software set works for them via edge latch
  wire [NUM_IRQ-1:0] pending = (edg & pend_edge) | (~edg & lvl) | (~edg & pend_edge);
  wire [NUM_IRQ-1:0] masked  = pending & en;

  // Pipelined priority encoder (lowest index first)
  logic [4:0] vec;
  logic vec_v;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      vec <= '0;
      vec_v <= 1'b0;
    end
    else begin
      vec_v <= 1'b0;
      vec <= '0;
      for (int i = NUM_IRQ-1; i >= 0; i--)
        if (masked[i]) begin
          vec <= 5'(i);
          vec_v <= 1'b1;
        end
    end
  end
  assign irq_o = vec_v;
  assign regs.sts_pending = pending;
  assign regs.sts_vector = {vec_v, 26'd0, vec};
  assign regs.sts_masked = masked;
endmodule
