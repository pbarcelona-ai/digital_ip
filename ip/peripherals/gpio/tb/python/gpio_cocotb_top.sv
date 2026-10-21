// ***************
// Filename: gpio_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of gpio (gpio_tb.py compares it with the golden
//   model ip/peripherals/gpio/model/gpio_model.py). Two independent instances
//   on one clock: u_core, the logic with its register interface on ports
//   (core_*) and the W1C INT_STATUS register the register map holds (the same
//   equation as gpio_regs.sv: written 1s clear, a set in the same clock wins),
//   and u_top, gpio_top with its AXI4-Lite register map (axi_* ports, ADDR_W
//   8; pins low). Clock - aclk. Reset - synchronous active low aresetn.
// Date: 2026-10-20
// ***************
module gpio_cocotb_top #(
  parameter int WIDTH = 32
) (
  input  logic             aclk,
  input  logic             aresetn,
  // u_core: register interface
  input  logic [WIDTH-1:0] core_out,
  input  logic             core_out_wr,
  input  logic [WIDTH-1:0] core_dir,
  input  logic [WIDTH-1:0] core_set,
  input  logic             core_set_wr,
  input  logic [WIDTH-1:0] core_clear,
  input  logic             core_clear_wr,
  input  logic [WIDTH-1:0] core_toggle,
  input  logic             core_toggle_wr,
  input  logic [WIDTH-1:0] core_int_en,
  input  logic [WIDTH-1:0] core_rise_en,
  input  logic [WIDTH-1:0] core_fall_en,
  input  logic [WIDTH-1:0] core_int_status_w1c,
  input  logic             core_int_status_wr,
  output logic [WIDTH-1:0] core_sts_out,
  output logic [WIDTH-1:0] core_sts_in,
  output logic [WIDTH-1:0] core_int_status,
  output logic             core_irq_o,
  // u_core: pins
  input  logic [WIDTH-1:0] gpio_i,
  output logic [WIDTH-1:0] gpio_o,
  output logic [WIDTH-1:0] gpio_t,
  // u_top
  output logic             top_irq_o,
  input  logic [7:0]       axi_awaddr,
  input  logic             axi_awvalid,
  output logic             axi_awready,
  input  logic [31:0]      axi_wdata,
  input  logic [3:0]       axi_wstrb,
  input  logic             axi_wvalid,
  output logic             axi_wready,
  output logic [1:0]       axi_bresp,
  output logic             axi_bvalid,
  input  logic             axi_bready,
  input  logic [7:0]       axi_araddr,
  input  logic             axi_arvalid,
  output logic             axi_arready,
  output logic [31:0]      axi_rdata,
  output logic [1:0]       axi_rresp,
  output logic             axi_rvalid,
  input  logic             axi_rready
);
  // ---------------- the logic ----------------
  gpio_regs_if #(.WIDTH(WIDTH)) u_regs_if ();
  logic [WIDTH-1:0] int_status_q;                             // the register map's W1C INT_STATUS
  always_ff @(posedge aclk) begin
    if (!aresetn) int_status_q <= '0;
    else int_status_q <= (core_int_status_wr ? int_status_q & ~core_int_status_w1c : int_status_q)
                         | u_regs_if.sts_int_status_set;          // a set wins over a clear
  end
  assign u_regs_if.cfg_out = core_out;
  assign u_regs_if.cfg_out_wr = core_out_wr;
  assign u_regs_if.cfg_dir = core_dir;
  assign u_regs_if.cfg_dir_wr = 1'b0;                         // acts by value
  assign u_regs_if.cfg_set = core_set;
  assign u_regs_if.cfg_set_wr = core_set_wr;
  assign u_regs_if.cfg_clear = core_clear;
  assign u_regs_if.cfg_clear_wr = core_clear_wr;
  assign u_regs_if.cfg_toggle = core_toggle;
  assign u_regs_if.cfg_toggle_wr = core_toggle_wr;
  assign u_regs_if.cfg_int_en = core_int_en;
  assign u_regs_if.cfg_int_en_wr = 1'b0;
  assign u_regs_if.cfg_rise_en = core_rise_en;
  assign u_regs_if.cfg_rise_en_wr = 1'b0;
  assign u_regs_if.cfg_fall_en = core_fall_en;
  assign u_regs_if.cfg_fall_en_wr = 1'b0;
  assign u_regs_if.cfg_int_status = int_status_q;
  assign u_regs_if.cfg_int_status_wr = core_int_status_wr;
  assign core_sts_out = u_regs_if.sts_out;
  assign core_sts_in = u_regs_if.sts_in;
  assign core_int_status = int_status_q;

  gpio #(.WIDTH(WIDTH)) u_core (
    .aclk,
    .aresetn,
    .gpio_i,
    .gpio_o,
    .gpio_t,
    .irq_o(core_irq_o),
    .regs(u_regs_if)
  );

  // ---------------- the block ----------------
  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  logic [WIDTH-1:0] t_o, t_t;
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
  wire unused_top = &{1'b0, t_o, t_t};

  gpio_top #(.WIDTH(WIDTH)) u_top (
    .aclk,
    .aresetn,
    .s_axil(s_axil),
    .gpio_i('0),
    .gpio_o(t_o),
    .gpio_t(t_t),
    .irq_o(top_irq_o)
  );
endmodule
