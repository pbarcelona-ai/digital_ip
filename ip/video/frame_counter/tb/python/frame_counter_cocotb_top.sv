// ***************
// Filename: frame_counter_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of frame_counter (frame_counter_tb.py compares
//   it with ip/video/frame_counter/model/frame_counter_model.py). Two
//   independent instances on one clock: u_core, the logic with its register
//   interface on ports (core_*), and u_top, frame_counter_top with its
//   AXI4-Lite register map (axi_* ports, ADDR_W 8) and its own marker input
//   top_eof_i. Clock - clk. Reset - rst_n (synchronous, active low).
// Date: 2026-10-21
module frame_counter_cocotb_top #(
  parameter int NCH    = 5,
  parameter int EVQ    = 8,
  parameter int TS_DIV = 3
) (
  input  logic              clk,
  input  logic              rst_n,
  // u_core
  input  logic [NCH-1:0]    core_eof_i,
  input  logic [NCH-1:0]    core_irq_en,
  input  logic [NCH-1:0]    core_ev_en,
  input  logic [NCH-1:0]    core_status,
  input  logic [NCH-1:0]    core_clear,
  input  logic              core_clear_wr,
  input  logic [1:0]        core_event_pop,
  input  logic              core_event_pop_wr,
  output logic [NCH-1:0]    core_irq_o,
  output logic [NCH-1:0]    core_sts_status_set,
  output logic [31:0]       core_sts_event,
  output logic [31:0]       core_sts_event_time,
  output logic [NCH*32-1:0] core_sts_count,
  output logic [31:0]       core_sts_time,
  // u_top
  input  logic [NCH-1:0]    top_eof_i,
  output logic [NCH-1:0]    top_irq_o,
  input  logic [7:0]        axi_awaddr,
  input  logic              axi_awvalid,
  output logic              axi_awready,
  input  logic [31:0]       axi_wdata,
  input  logic [3:0]        axi_wstrb,
  input  logic              axi_wvalid,
  output logic              axi_wready,
  output logic [1:0]        axi_bresp,
  output logic              axi_bvalid,
  input  logic              axi_bready,
  input  logic [7:0]        axi_araddr,
  input  logic              axi_arvalid,
  output logic              axi_arready,
  output logic [31:0]       axi_rdata,
  output logic [1:0]        axi_rresp,
  output logic              axi_rvalid,
  input  logic              axi_rready
);
  frame_counter_regs_if #(.NCH(NCH)) ri ();
  assign ri.cfg_irq_en = core_irq_en;
  assign ri.cfg_irq_en_wr = 1'b0;
  assign ri.cfg_ev_en = core_ev_en;
  assign ri.cfg_ev_en_wr = 1'b0;
  assign ri.cfg_status = core_status;
  assign ri.cfg_status_wr = 1'b0;
  assign ri.cfg_clear = core_clear;
  assign ri.cfg_clear_wr = core_clear_wr;
  assign ri.cfg_event_pop = core_event_pop;
  assign ri.cfg_event_pop_wr = core_event_pop_wr;
  assign core_sts_status_set = ri.sts_status_set;
  assign core_sts_event = ri.sts_event;
  assign core_sts_event_time = ri.sts_event_time;
  assign core_sts_count = ri.sts_count;
  assign core_sts_time = ri.sts_time;
  frame_counter #(
    .NCH(NCH),
    .EVQ(EVQ),
    .TS_DIV(TS_DIV)
  ) u_core (
    .clk,
    .rst_n,
    .eof_i(core_eof_i),
    .irq_o(core_irq_o),
    .regs(ri)
  );
  axil_if #(.ADDR_W(8)) bus ();
  assign bus.awaddr = axi_awaddr;
  assign bus.awvalid = axi_awvalid;
  assign axi_awready = bus.awready;
  assign bus.wdata = axi_wdata;
  assign bus.wstrb = axi_wstrb;
  assign bus.wvalid = axi_wvalid;
  assign axi_wready = bus.wready;
  assign axi_bresp = bus.bresp;
  assign axi_bvalid = bus.bvalid;
  assign bus.bready = axi_bready;
  assign bus.araddr = axi_araddr;
  assign bus.arvalid = axi_arvalid;
  assign axi_arready = bus.arready;
  assign axi_rdata = bus.rdata;
  assign axi_rresp = bus.rresp;
  assign axi_rvalid = bus.rvalid;
  assign bus.rready = axi_rready;
  frame_counter_top #(
    .NCH(NCH),
    .EVQ(EVQ),
    .TS_DIV(TS_DIV)
  ) u_top (
    .clk,
    .rst_n,
    .eof_i(top_eof_i),
    .irq_o(top_irq_o),
    .s_axil(bus)
  );
endmodule
