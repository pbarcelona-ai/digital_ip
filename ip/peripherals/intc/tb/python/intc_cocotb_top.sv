// ***************
// Filename: intc_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of intc (tb/python/intc_tb.py compares it with
//   the golden model ip/peripherals/intc/model/intc_model.py). Two
//   independent instances on one clock:
//     u_core  the logic intc with its register interface on ports (core_*):
//             the test drives the register values and write pulses itself,
//             clock for clock;
//     u_top   intc_top, the block with its AXI4-Lite register map (axi_*
//             ports, flattened axil_if, ADDR_W = 8).
//   Clock - aclk. Reset - synchronous active low aresetn (both instances).
// Date: 2026-10-20
// ***************
module intc_cocotb_top #(
  parameter int NUM_IRQ = 17
) (
  input  logic               aclk,
  input  logic               aresetn,
  // u_core: the logic, register interface on ports
  input  logic [NUM_IRQ-1:0] core_irq_i,
  output logic               core_irq_o,
  input  logic [NUM_IRQ-1:0] core_enable,
  input  logic [NUM_IRQ-1:0] core_edge_type,
  input  logic [NUM_IRQ-1:0] core_active_low,
  input  logic [NUM_IRQ-1:0] core_pending,
  input  logic               core_pending_wr,
  input  logic [NUM_IRQ-1:0] core_soft_set,
  input  logic               core_soft_set_wr,
  output logic [NUM_IRQ-1:0] core_sts_pending,
  output logic [NUM_IRQ-1:0] core_sts_masked,
  output logic [31:0]        core_sts_vector,
  // u_top: the block with its AXI4-Lite register map
  input  logic [NUM_IRQ-1:0] top_irq_i,
  output logic               top_irq_o,
  input  logic [7:0]         axi_awaddr,
  input  logic               axi_awvalid,
  output logic               axi_awready,
  input  logic [31:0]        axi_wdata,
  input  logic [3:0]         axi_wstrb,
  input  logic               axi_wvalid,
  output logic               axi_wready,
  output logic [1:0]         axi_bresp,
  output logic               axi_bvalid,
  input  logic               axi_bready,
  input  logic [7:0]         axi_araddr,
  input  logic               axi_arvalid,
  output logic               axi_arready,
  output logic [31:0]        axi_rdata,
  output logic [1:0]         axi_rresp,
  output logic               axi_rvalid,
  input  logic               axi_rready
);
  // ---------------- the logic ----------------
  intc_regs_if #(.NUM_IRQ(NUM_IRQ)) u_regs_if ();
  assign u_regs_if.cfg_enable = core_enable;
  assign u_regs_if.cfg_enable_wr = 1'b0;                      // unused by intc
  assign u_regs_if.cfg_edge_type = core_edge_type;
  assign u_regs_if.cfg_edge_type_wr = 1'b0;
  assign u_regs_if.cfg_active_low = core_active_low;
  assign u_regs_if.cfg_active_low_wr = 1'b0;
  assign u_regs_if.cfg_pending = core_pending;
  assign u_regs_if.cfg_pending_wr = core_pending_wr;
  assign u_regs_if.cfg_soft_set = core_soft_set;
  assign u_regs_if.cfg_soft_set_wr = core_soft_set_wr;
  assign core_sts_pending = u_regs_if.sts_pending;
  assign core_sts_masked = u_regs_if.sts_masked;
  assign core_sts_vector = u_regs_if.sts_vector;

  intc #(.NUM_IRQ(NUM_IRQ)) u_core (
    .aclk,
    .aresetn,
    .irq_i(core_irq_i),
    .irq_o(core_irq_o),
    .regs(u_regs_if)
  );

  // ---------------- the block ----------------
  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  assign s_axil.awaddr = axi_awaddr;
  assign s_axil.awvalid = axi_awvalid;
  assign axi_awready = s_axil.awready;
  assign s_axil.wdata = axi_wdata;
  assign s_axil.wstrb = axi_wstrb;
  assign s_axil.wvalid = axi_wvalid;
  assign axi_wready = s_axil.wready;
  assign axi_bresp = s_axil.bresp;
  assign axi_bvalid = s_axil.bvalid;
  assign s_axil.bready = axi_bready;
  assign s_axil.araddr = axi_araddr;
  assign s_axil.arvalid = axi_arvalid;
  assign axi_arready = s_axil.arready;
  assign axi_rdata = s_axil.rdata;
  assign axi_rresp = s_axil.rresp;
  assign axi_rvalid = s_axil.rvalid;
  assign s_axil.rready = axi_rready;

  intc_top #(.NUM_IRQ(NUM_IRQ)) u_top (
    .aclk,
    .aresetn,
    .s_axil(s_axil),
    .irq_i(top_irq_i),
    .irq_o(top_irq_o)
  );
endmodule
