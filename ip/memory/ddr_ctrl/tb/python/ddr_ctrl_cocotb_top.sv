// ***************
// Filename: ddr_ctrl_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of ddr_ctrl for the comparison with its model
//   (ddr_ctrl_tb.py): ddr_ctrl_top (the controller with its register map)
//   and the generic memory ddr_mem joined by the DFI-style interface (as the
//   generic build in a design), the AXI4 ports, the AXI4-Lite register port
//   (axi_*) and the command lines as ports, the memory's checks (mem_err, its
//   code and count) out; the statistics are read from u_ctrl.u_core (stat_*). Parameters as the controller's, the memory's timings the
//   same. Clock - clk. Reset - rst_n (synchronous, active low).
// Date: 2026-10-21
module ddr_ctrl_cocotb_top #(
  parameter int NPORTS    = 2,
  parameter int DATA_W    = 64,
  parameter int ADDR_W    = 32,
  parameter int ID_W      = 4,
  parameter int BANK_W    = 2,
  parameter int ROW_W     = 6,
  parameter int COL_W     = 4,
  parameter int MEM_WORDS = 1 << 12,
  parameter int T_RCD     = 4,
  parameter int T_RP      = 4,
  parameter int T_RAS     = 10,
  parameter int T_CL      = 5,
  parameter int T_WR      = 4,
  parameter int T_RTP     = 2,
  parameter int T_WTR     = 2,
  parameter int T_RRD     = 2,
  parameter int T_RFC     = 30,
  parameter int T_REFI    = 300,
  parameter int PRIORITY  = 0,
  parameter int RQ_DEPTH  = 16,
  parameter int BQ_DEPTH  = 2
) (
  input  logic                       clk,
  input  logic                       rst_n,
  input  logic [7:0]                 axi_awaddr,
  input  logic                       axi_awvalid,
  output logic                       axi_awready,
  input  logic [31:0]                axi_wdata,
  input  logic [3:0]                 axi_wstrb,
  input  logic                       axi_wvalid,
  output logic                       axi_wready,
  output logic [1:0]                 axi_bresp,
  output logic                       axi_bvalid,
  input  logic                       axi_bready,
  input  logic [7:0]                 axi_araddr,
  input  logic                       axi_arvalid,
  output logic                       axi_arready,
  output logic [31:0]                axi_rdata,
  output logic [1:0]                 axi_rresp,
  output logic                       axi_rvalid,
  input  logic                       axi_rready,
  input  logic [NPORTS*ID_W-1:0]     s_axi_awid,
  input  logic [NPORTS*ADDR_W-1:0]   s_axi_awaddr,
  input  logic [NPORTS*8-1:0]        s_axi_awlen,
  input  logic [NPORTS*3-1:0]        s_axi_awsize,
  input  logic [NPORTS*2-1:0]        s_axi_awburst,
  input  logic [NPORTS-1:0]          s_axi_awvalid,
  output logic [NPORTS-1:0]          s_axi_awready,
  input  logic [NPORTS*DATA_W-1:0]   s_axi_wdata,
  input  logic [NPORTS*DATA_W/8-1:0] s_axi_wstrb,
  input  logic [NPORTS-1:0]          s_axi_wlast,
  input  logic [NPORTS-1:0]          s_axi_wvalid,
  output logic [NPORTS-1:0]          s_axi_wready,
  output logic [NPORTS*ID_W-1:0]     s_axi_bid,
  output logic [NPORTS*2-1:0]        s_axi_bresp,
  output logic [NPORTS-1:0]          s_axi_bvalid,
  input  logic [NPORTS-1:0]          s_axi_bready,
  input  logic [NPORTS*ID_W-1:0]     s_axi_arid,
  input  logic [NPORTS*ADDR_W-1:0]   s_axi_araddr,
  input  logic [NPORTS*8-1:0]        s_axi_arlen,
  input  logic [NPORTS*3-1:0]        s_axi_arsize,
  input  logic [NPORTS*2-1:0]        s_axi_arburst,
  input  logic [NPORTS-1:0]          s_axi_arvalid,
  output logic [NPORTS-1:0]          s_axi_arready,
  output logic [NPORTS*ID_W-1:0]     s_axi_rid,
  output logic [NPORTS*DATA_W-1:0]   s_axi_rdata,
  output logic [NPORTS*2-1:0]        s_axi_rresp,
  output logic [NPORTS-1:0]          s_axi_rlast,
  output logic [NPORTS-1:0]          s_axi_rvalid,
  input  logic [NPORTS-1:0]          s_axi_rready,
  output logic [2:0]                 dfi_cmd,
  output logic [BANK_W-1:0]          dfi_bank,
  output logic [ROW_W-1:0]           dfi_row,
  output logic [COL_W-1:0]           dfi_col,
  output logic                       mem_err,
  output logic [3:0]                 mem_err_code,
  output logic [15:0]                mem_err_cnt
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
  logic [DATA_W-1:0]   wrdata, rddata;
  logic [DATA_W/8-1:0] wrstrb;
  logic                rddata_valid;
  ddr_ctrl_top #(
    .NPORTS(NPORTS),
    .DATA_W(DATA_W),
    .ADDR_W(ADDR_W),
    .ID_W(ID_W),
    .BANK_W(BANK_W),
    .ROW_W(ROW_W),
    .COL_W(COL_W),
    .T_RCD(T_RCD),
    .T_RP(T_RP),
    .T_RAS(T_RAS),
    .T_CL(T_CL),
    .T_WR(T_WR),
    .T_RTP(T_RTP),
    .T_WTR(T_WTR),
    .T_RRD(T_RRD),
    .T_RFC(T_RFC),
    .T_REFI(T_REFI),
    .PRIORITY(PRIORITY),
    .RQ_DEPTH(RQ_DEPTH),
    .BQ_DEPTH(BQ_DEPTH)
  ) u_ctrl (
    .clk,
    .rst_n,
    .s_axil(bus),
    .s_axi_awid,
    .s_axi_awaddr,
    .s_axi_awlen,
    .s_axi_awsize,
    .s_axi_awburst,
    .s_axi_awvalid,
    .s_axi_awready,
    .s_axi_wdata,
    .s_axi_wstrb,
    .s_axi_wlast,
    .s_axi_wvalid,
    .s_axi_wready,
    .s_axi_bid,
    .s_axi_bresp,
    .s_axi_bvalid,
    .s_axi_bready,
    .s_axi_arid,
    .s_axi_araddr,
    .s_axi_arlen,
    .s_axi_arsize,
    .s_axi_arburst,
    .s_axi_arvalid,
    .s_axi_arready,
    .s_axi_rid,
    .s_axi_rdata,
    .s_axi_rresp,
    .s_axi_rlast,
    .s_axi_rvalid,
    .s_axi_rready,
    .dfi_cmd_o(dfi_cmd),
    .dfi_bank_o(dfi_bank),
    .dfi_row_o(dfi_row),
    .dfi_col_o(dfi_col),
    .dfi_wrdata_o(wrdata),
    .dfi_wrstrb_o(wrstrb),
    .dfi_rddata_valid_i(rddata_valid),
    .dfi_rddata_i(rddata)
  );
  ddr_mem #(
    .DATA_W(DATA_W),
    .BANK_W(BANK_W),
    .ROW_W(ROW_W),
    .COL_W(COL_W),
    .MEM_WORDS(MEM_WORDS),
    .T_RCD(T_RCD),
    .T_RP(T_RP),
    .T_RAS(T_RAS),
    .T_CL(T_CL),
    .T_WR(T_WR),
    .T_RTP(T_RTP),
    .T_WTR(T_WTR),
    .T_RRD(T_RRD),
    .T_RFC(T_RFC),
    .REF_MAX(9 * T_REFI)
  ) u_mem (
    .clk,
    .rst_n,
    .cmd_i(dfi_cmd),
    .bank_i(dfi_bank),
    .row_i(dfi_row),
    .col_i(dfi_col),
    .wrdata_i(wrdata),
    .wrstrb_i(wrstrb),
    .rddata_valid_o(rddata_valid),
    .rddata_o(rddata),
    .err_o(mem_err),
    .err_code_o(mem_err_code),
    .err_cnt_o(mem_err_cnt)
  );
endmodule
