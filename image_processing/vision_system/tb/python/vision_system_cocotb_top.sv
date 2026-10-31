// ***************
// Filename: vision_system_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of vision_system for the comparison with its
//   model (vision_system_tb.py): the streams as s_* / m_* ports, the
//   register bus as flattened axi_* ports (ADDR_W 8), the on-chip frame
//   store sized by ADDR_W / FB_DEPTH (small frames), or (USE_EXT_FB) the
//   SDRAM store with a short power-up wait: its data bus split as in
//   ext_frame_buffer_cocotb_top (dq_seen the bus, the test's SDRAM
//   responder drives tb_dq onto it unless the controller issues a WRITE),
//   or (USE_DDR_FB) the DDR store on a one-port ddr_ctrl with ddr_mem behind
//   it (256-bit words, 4096 words; mem_err the memory's timing checker).
//   Clock - clk. Reset - rst_n (synchronous, active low).
// Date: 2026-10-25
module vision_system_cocotb_top #(
  parameter int ADDR_W     = 12,
  parameter int FB_DEPTH   = 4096,
  parameter bit USE_EXT_FB = 1'b0,
  parameter bit USE_DDR_FB = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [23:0] s_tdata,
  input  logic        s_tvalid,
  output logic        s_tready,
  input  logic        s_tlast,
  input  logic        s_tuser,
  output logic [23:0] m_tdata,
  output logic        m_tvalid,
  input  logic        m_tready,
  output logic        m_tlast,
  output logic        m_tuser,
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
  input  logic        axi_rready,
  output logic        sdram_cs_n,
  output logic        sdram_ras_n,
  output logic        sdram_cas_n,
  output logic        sdram_we_n,
  output logic [12:0] sdram_a,
  input  logic [63:0] tb_dq,
  output logic [63:0] dq_seen,
  output logic        mem_err
);
  axis_if #(.DATA_W(24)) si ();
  axis_if #(.DATA_W(24)) mi ();
  axil_if #(.ADDR_W(8)) bus ();
  assign si.tdata = s_tdata;
  assign si.tvalid = s_tvalid;
  assign s_tready = si.tready;
  assign si.tlast = s_tlast;
  assign si.tuser = s_tuser;
  assign si.tkeep = '1;
  assign m_tdata = mi.tdata;
  assign m_tvalid = mi.tvalid;
  assign mi.tready = m_tready;
  assign m_tlast = mi.tlast;
  assign m_tuser = mi.tuser;
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
  wire        sdram_clk, sdram_cke;
  wire [1:0]  sdram_ba;
  wire [7:0]  sdram_dqm;
  wire [63:0] sdram_dq;
  wire        ctrl_writes = !sdram_cs_n && sdram_ras_n && !sdram_cas_n && !sdram_we_n;
  assign sdram_dq = (USE_EXT_FB && !ctrl_writes) ? tb_dq : 64'bz;
  assign dq_seen  = sdram_dq;
  localparam int BANK_W = 2, ROW_W = 4, COL_W = 6, T_REFI = 300;
  logic [3:0]   awid, arid, bid, rid;
  logic [31:0]  awaddr, araddr;
  logic [7:0]   awlen, arlen;
  logic [2:0]   awsize, arsize, dfi_cmd;
  logic [1:0]   awburst, arburst, bresp, rresp;
  logic         awvalid, awready, wlast, wvalid, wready, bvalid, bready;
  logic         arvalid, arready, rlast, rvalid, rready, dfi_rv;
  logic [255:0] wdata, rdata, dfi_wrdata, dfi_rddata;
  logic [31:0]  wstrb, dfi_wrstrb;
  logic [BANK_W-1:0] dfi_bank;
  logic [ROW_W-1:0]  dfi_row;
  logic [COL_W-1:0]  dfi_col;
  logic [3:0]   mem_err_code;
  logic [15:0]  mem_err_cnt;
  vision_system #(
    .ADDR_W(ADDR_W),
    .FB_DEPTH(FB_DEPTH),
    .USE_EXT_FB(USE_EXT_FB),
    .SDRAM_INIT_WAIT_CYCLES(40),
    .USE_DDR_FB(USE_DDR_FB),
    .DDR_LINE_PIX(16),
    .DDR_CACHE_LINES(16)
  ) u_dut (
    .clk,
    .rst_n,
    .s_axis(si),
    .m_axis(mi),
    .s_axil(bus),
    .sdram_clk,
    .sdram_cke,
    .sdram_cs_n,
    .sdram_ras_n,
    .sdram_cas_n,
    .sdram_we_n,
    .sdram_a,
    .sdram_ba,
    .sdram_dqm,
    .sdram_dq,
    .m_axi_awid(awid),
    .m_axi_awaddr(awaddr),
    .m_axi_awlen(awlen),
    .m_axi_awsize(awsize),
    .m_axi_awburst(awburst),
    .m_axi_awvalid(awvalid),
    .m_axi_awready(awready),
    .m_axi_wdata(wdata),
    .m_axi_wstrb(wstrb),
    .m_axi_wlast(wlast),
    .m_axi_wvalid(wvalid),
    .m_axi_wready(wready),
    .m_axi_bid(bid),
    .m_axi_bresp(bresp),
    .m_axi_bvalid(bvalid),
    .m_axi_bready(bready),
    .m_axi_arid(arid),
    .m_axi_araddr(araddr),
    .m_axi_arlen(arlen),
    .m_axi_arsize(arsize),
    .m_axi_arburst(arburst),
    .m_axi_arvalid(arvalid),
    .m_axi_arready(arready),
    .m_axi_rid(rid),
    .m_axi_rdata(rdata),
    .m_axi_rresp(rresp),
    .m_axi_rlast(rlast),
    .m_axi_rvalid(rvalid),
    .m_axi_rready(rready)
  );
  // the DDR store's controller and memory (idle unless USE_DDR_FB)
  ddr_ctrl_regs_if u_regs_if ();
  assign u_regs_if.cfg_ctrl = 1'b0;
  assign u_regs_if.cfg_ctrl_wr = 1'b0;
  ddr_ctrl #(
    .NPORTS(1),
    .DATA_W(256),
    .ADDR_W(32),
    .ID_W(4),
    .BANK_W(BANK_W),
    .ROW_W(ROW_W),
    .COL_W(COL_W),
    .T_RCD(3),
    .T_RP(3),
    .T_RAS(6),
    .T_CL(4),
    .T_WR(3),
    .T_RTP(2),
    .T_WTR(2),
    .T_RRD(2),
    .T_RFC(12),
    .T_REFI(T_REFI),
    .PRIORITY(0),
    .RQ_DEPTH(8),
    .BQ_DEPTH(2)
  ) u_ctrl (
    .clk,
    .rst_n,
    .s_axi_awid(awid),
    .s_axi_awaddr(awaddr),
    .s_axi_awlen(awlen),
    .s_axi_awsize(awsize),
    .s_axi_awburst(awburst),
    .s_axi_awvalid(awvalid),
    .s_axi_awready(awready),
    .s_axi_wdata(wdata),
    .s_axi_wstrb(wstrb),
    .s_axi_wlast(wlast),
    .s_axi_wvalid(wvalid),
    .s_axi_wready(wready),
    .s_axi_bid(bid),
    .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid),
    .s_axi_bready(bready),
    .s_axi_arid(arid),
    .s_axi_araddr(araddr),
    .s_axi_arlen(arlen),
    .s_axi_arsize(arsize),
    .s_axi_arburst(arburst),
    .s_axi_arvalid(arvalid),
    .s_axi_arready(arready),
    .s_axi_rid(rid),
    .s_axi_rdata(rdata),
    .s_axi_rresp(rresp),
    .s_axi_rlast(rlast),
    .s_axi_rvalid(rvalid),
    .s_axi_rready(rready),
    .dfi_cmd_o(dfi_cmd),
    .dfi_bank_o(dfi_bank),
    .dfi_row_o(dfi_row),
    .dfi_col_o(dfi_col),
    .dfi_wrdata_o(dfi_wrdata),
    .dfi_wrstrb_o(dfi_wrstrb),
    .dfi_rddata_valid_i(dfi_rv),
    .dfi_rddata_i(dfi_rddata),
    .regs(u_regs_if)
  );
  ddr_mem #(
    .DATA_W(256),
    .BANK_W(BANK_W),
    .ROW_W(ROW_W),
    .COL_W(COL_W),
    .MEM_WORDS(1 << (BANK_W + ROW_W + COL_W)),
    .T_RCD(3),
    .T_RP(3),
    .T_RAS(6),
    .T_CL(4),
    .T_WR(3),
    .T_RTP(2),
    .T_WTR(2),
    .T_RRD(2),
    .T_RFC(12),
    .REF_MAX(9 * T_REFI)
  ) u_mem (
    .clk,
    .rst_n,
    .cmd_i(dfi_cmd),
    .bank_i(dfi_bank),
    .row_i(dfi_row),
    .col_i(dfi_col),
    .wrdata_i(dfi_wrdata),
    .wrstrb_i(dfi_wrstrb),
    .rddata_valid_o(dfi_rv),
    .rddata_o(dfi_rddata),
    .err_o(mem_err),
    .err_code_o(mem_err_code),
    .err_cnt_o(mem_err_cnt)
  );
  // not used: the SDRAM pins the responder ignores (bank, mask, clock enable), tkeep, the memory's error
  // details (mem_err is checked), the controller's statistics
  wire unused_ok = &{1'b0, sdram_clk, sdram_cke, sdram_ba, sdram_dqm, mi.tkeep, mem_err_code, mem_err_cnt,
                     u_regs_if.sts_status, u_regs_if.sts_rd_beats, u_regs_if.sts_wr_beats, u_regs_if.sts_acts,
                     u_regs_if.sts_hits, u_regs_if.sts_refs, u_regs_if.sts_errs, 1'b0};
endmodule
