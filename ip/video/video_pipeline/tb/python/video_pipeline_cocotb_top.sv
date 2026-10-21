// ***************
// Filename: video_pipeline_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of video_pipeline for the comparison of its
//   ISP with the model (video_pipeline_tb.py), built with
//   video_pipeline_cocotb_config.sv (CSI-2 receiver and insert point): the
//   D-PHY lanes in on byte_clk, the AXI4-Lite bus as flattened axi_* ports
//   (ADDR_W 15), the ISP output at the insert point as ins_* ports (the
//   return path idle), the end-of-frame and statistics pulses out.
//   Clocks - byte_clk, pix_clk. Resets - byte_rst_n, pix_rst_n
//   (synchronous, active low).
// Date: 2026-10-21
module video_pipeline_cocotb_top #(
  parameter int NLANES = 2,
  parameter int MAX_W  = 64
) (
  input  logic                byte_clk,
  input  logic                byte_rst_n,
  input  logic [NLANES*8-1:0] lane_data_i,
  input  logic [NLANES-1:0]   lane_valid_i,
  input  logic                pix_clk,
  input  logic                pix_rst_n,
  input  logic [14:0]         axi_awaddr,
  input  logic                axi_awvalid,
  output logic                axi_awready,
  input  logic [31:0]         axi_wdata,
  input  logic [3:0]          axi_wstrb,
  input  logic                axi_wvalid,
  output logic                axi_wready,
  output logic [1:0]          axi_bresp,
  output logic                axi_bvalid,
  input  logic                axi_bready,
  input  logic [14:0]         axi_araddr,
  input  logic                axi_arvalid,
  output logic                axi_arready,
  output logic [31:0]         axi_rdata,
  output logic [1:0]          axi_rresp,
  output logic                axi_rvalid,
  input  logic                axi_rready,
  output logic [23:0]         ins_tdata,
  output logic                ins_tvalid,
  input  logic                ins_tready,
  output logic                ins_tlast,
  output logic                ins_tuser,
  output logic                eof_in_o,
  output logic                eof_out_o,
  output logic                stats_done_o
);
  axil_if #(.ADDR_W(15)) bus ();
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
  axis_if #(.DATA_W(24)) ins_m ();
  axis_if #(.DATA_W(24)) ins_s ();
  assign ins_tdata = ins_m.tdata;
  assign ins_tvalid = ins_m.tvalid;
  assign ins_m.tready = ins_tready;
  assign ins_tlast = ins_m.tlast;
  assign ins_tuser = ins_m.tuser;
  assign ins_s.tdata = '0;
  assign ins_s.tvalid = 1'b0;
  assign ins_s.tlast = 1'b0;
  assign ins_s.tuser = 1'b0;
  assign ins_s.tkeep = '1;
  video_pipeline #(
    .NLANES(NLANES),
    .MAX_W(MAX_W),
    .CSI_FIFO(1024),
    .OUT_FIFO(256),
    .SCALER(1'b0)
  ) u_dut (
    .byte_clk,
    .byte_rst_n,
    .lane_data_i,
    .lane_valid_i,
    .pix_clk,
    .pix_rst_n,
    .s_axil(bus),
    .ins_m_axis(ins_m),
    .ins_s_axis(ins_s),
    .eof_in_o,
    .eof_out_o,
    .stats_done_o
  );
  wire unused_ok = &{1'b0, ins_m.tkeep, ins_s.tready, 1'b0};
endmodule
