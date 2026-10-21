// ***************
// Filename: uart_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of uart (uart_tb.py compares it with the golden
//   model ip/peripherals/uart/model/uart_model.py). Two independent instances
//   on one clock: u_core, the logic with its register interface and streams
//   on ports (core_*, tx_* bytes to send, rx_* bytes received) and its RX line
//   either the testbench's rxd_i or, with board_loop, its own TXD (py_soc's
//   board loopback); and u_top, uart_top with its AXI4-Lite register map
//   (axi_* ports, ADDR_W 8; streams idle, RXD high). Clock - aclk. Reset -
//   synchronous active low aresetn.
// Date: 2026-10-20
// ***************
module uart_cocotb_top #(
  parameter int CLK_HZ     = 100_000_000,
  parameter int BAUD       = 1_000_000,
  parameter int FIFO_DEPTH = 4
) (
  input  logic        aclk,
  input  logic        aresetn,
  // u_core: register interface
  input  logic [31:0] core_ctrl,
  input  logic [31:0] core_fcw,
  input  logic        core_fcw_wr,
  input  logic [31:0] core_status,
  input  logic        core_status_wr,
  output logic [31:0] core_sts_status,
  output logic [31:0] core_sts_err_cnt,
  // u_core: streams and lines
  input  logic [7:0]  tx_tdata,
  input  logic        tx_tvalid,
  output logic        tx_tready,
  output logic [7:0]  rx_tdata,
  output logic        rx_tvalid,
  input  logic        rx_tready,
  input  logic        rxd_i,
  input  logic        board_loop,
  output logic        txd_o,
  // u_top
  input  logic [7:0]  axi_awaddr,
  input  logic        axi_awvalid,
  output logic        axi_awready,
  input  logic [31:0] axi_wdata,
  input  logic [3:0]  axi_wstrb,
  input  logic        axi_wvalid,
  output logic        axi_wready,
  output logic [1:0]  axi_bresp,
  output logic        axi_bvalid,
  input  logic        axi_bready,
  input  logic [7:0]  axi_araddr,
  input  logic        axi_arvalid,
  output logic        axi_arready,
  output logic [31:0] axi_rdata,
  output logic [1:0]  axi_rresp,
  output logic        axi_rvalid,
  input  logic        axi_rready
);
  // ---------------- the logic ----------------
  uart_regs_if u_regs_if ();
  assign u_regs_if.cfg_ctrl = core_ctrl;
  assign u_regs_if.cfg_ctrl_wr = 1'b0;                        // acts by value
  assign u_regs_if.cfg_fcw = core_fcw;
  assign u_regs_if.cfg_fcw_wr = core_fcw_wr;
  assign u_regs_if.cfg_status = core_status;
  assign u_regs_if.cfg_status_wr = core_status_wr;
  assign core_sts_status = u_regs_if.sts_status;
  assign core_sts_err_cnt = u_regs_if.sts_err_cnt;

  axis_if #(.DATA_W(8)) s_axis ();
  axis_if #(.DATA_W(8)) m_axis ();
  uart_if uart ();
  assign s_axis.tdata = tx_tdata;
  assign s_axis.tvalid = tx_tvalid;
  assign s_axis.tlast = 1'b0;
  assign s_axis.tkeep = 1'b1;
  assign s_axis.tuser = 1'b0;
  assign tx_tready = s_axis.tready;
  assign rx_tdata = m_axis.tdata;
  assign rx_tvalid = m_axis.tvalid;
  assign m_axis.tready = rx_tready;
  assign txd_o = uart.txd;
  assign uart.rxd = board_loop ? uart.txd : rxd_i;

  uart #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .FIFO_DEPTH(FIFO_DEPTH)) u_core (
    .aclk,
    .aresetn,
    .s_axis,
    .m_axis,
    .pins(uart),
    .regs(u_regs_if)
  );
  wire unused_ok = &{1'b0, m_axis.tlast, m_axis.tkeep, m_axis.tuser};

  // ---------------- the block ----------------
  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  axis_if #(.DATA_W(8)) t_s_axis ();
  axis_if #(.DATA_W(8)) t_m_axis ();
  uart_if t_uart ();
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
  assign t_s_axis.tdata = '0;
  assign t_s_axis.tvalid = 1'b0;
  assign t_s_axis.tlast = 1'b0;
  assign t_s_axis.tkeep = 1'b1;
  assign t_s_axis.tuser = 1'b0;
  assign t_m_axis.tready = 1'b1;
  assign t_uart.rxd = 1'b1;
  wire unused_top = &{1'b0, t_s_axis.tready, t_m_axis.tdata, t_m_axis.tvalid, t_m_axis.tlast, t_m_axis.tkeep,
                      t_m_axis.tuser, t_uart.txd};

  uart_top #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .FIFO_DEPTH(FIFO_DEPTH)) u_top (
    .aclk,
    .aresetn,
    .s_axil(s_axil),
    .s_axis(t_s_axis),
    .m_axis(t_m_axis),
    .uart(t_uart)
  );
endmodule
