// ***************
// Filename: tb_ddr_frame_store.sv
// Author: FPGA Cores 4 U
// Description: Self-checking directed testbench of ddr_frame_store on a
//   one-port ddr_ctrl with ddr_mem (256-bit words, 20 x 12 frames, 8-line
//   cache of 32 pixels, T_REFI 300). Checks, independently of the Python
//   model (a pixel scoreboard per buffer): a frame written in raster order
//   with gaps reads back in bilinear and bicubic neighbourhoods; writes to
//   one buffer while the other is read (double buffering) leave the read
//   frame intact; a rewritten buffer reads back its new frame after wr_idle
//   and rd_flush, and its old frame without the flush (the cache does not
//   see writes, as specified); scattered single-pixel writes (partial words)
//   land; wr_idle falls with a write and rises once it is in memory; a
//   clear during a line fill drops the request (no rd_valid; the store
//   ready again once the burst is complete, the next read correct); and
//   ddr_mem reports no timing violation. +define+MUTATE corrupts one
//   expected pixel: the testbench must then fail (mutation check). Test
//   tasks in tests/ddr_frame_store_tests.sv. Prints TEST PASSED and
//   >>> PASS <<< on success.
// Date: 2026-10-25
`timescale 1ns/1ps
module tb_ddr_frame_store;
  localparam int PW = 24, AW = 10, DW = 256, FW = 20, FH = 12, NPIX = FW * FH;
  localparam int BANK_W = 2, ROW_W = 4, COL_W = 6, T_REFI = 300;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic          wr_en = 0, wr_buf = 0, rd_en = 0, rd_buf = 0, rd_flush = 0, clear = 0;
  logic [AW-1:0] wr_addr = '0, rd_addr [4];
  logic [PW-1:0] wr_data = '0, rd_data [4];
  logic          wr_ready, wr_idle, rd_ready, rd_valid;
  logic [3:0]    awid, arid, bid, rid;
  logic [31:0]   awaddr, araddr;
  logic [7:0]    awlen, arlen;
  logic [2:0]    awsize, arsize;
  logic [1:0]    awburst, arburst, bresp, rresp;
  logic          awvalid, awready, wlast, wvalid, wready, bvalid, bready, arvalid, arready, rlast, rvalid, rready;
  logic [DW-1:0] wdata, rdata;
  logic [DW/8-1:0] wstrb;
  ddr_frame_store #(
    .PIX_W(PW),
    .ADDR_W(AW),
    .DATA_W(DW),
    .LINE_PIX(32),
    .CACHE_LINES(8),
    .WQ_DEPTH(4),
    .FLUSH_IDLE(4),
    .OUT_MAX(8)
  ) dut (
    .clk,
    .rst_n,
    .wr_en,
    .wr_ready,
    .wr_addr,
    .wr_data,
    .wr_buf,
    .wr_idle,
    .rd_en,
    .rd_ready,
    .rd_addr0(rd_addr[0]),
    .rd_addr1(rd_addr[1]),
    .rd_addr2(rd_addr[2]),
    .rd_addr3(rd_addr[3]),
    .rd_buf,
    .rd_flush,
    .clear,
    .rd_valid,
    .rd_data0(rd_data[0]),
    .rd_data1(rd_data[1]),
    .rd_data2(rd_data[2]),
    .rd_data3(rd_data[3]),
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
  ddr_ctrl_regs_if u_regs_if ();
  assign u_regs_if.cfg_ctrl = 1'b0;
  assign u_regs_if.cfg_ctrl_wr = 1'b0;
  logic [2:0]        dfi_cmd;
  logic [BANK_W-1:0] dfi_bank;
  logic [ROW_W-1:0]  dfi_row;
  logic [COL_W-1:0]  dfi_col;
  logic [DW-1:0]     dfi_wrdata, dfi_rddata;
  logic [DW/8-1:0]   dfi_wrstrb;
  logic              dfi_rv, mem_err;
  logic [3:0]        mem_err_code;
  logic [15:0]       mem_err_cnt;
  ddr_ctrl #(
    .NPORTS(1),
    .DATA_W(DW),
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
    .DATA_W(DW),
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

  logic [PW-1:0] sb [2][NPIX];                   // scoreboard: each buffer's pixels
  int errors = 0;
  `include "ddr_frame_store_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("tb_ddr_frame_store.vcd");
      $dumpvars(0, tb_ddr_frame_store);
    end
    for (int k = 0; k < 4; k++) rd_addr[k] = '0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1;
    test_write_read();
    test_double_buffer();
    test_rewrite_flush();
    test_scattered_writes();
    test_wr_idle();
    test_clear();
    test_timing_kept();
    if (errors == 0) begin
      $display("TEST PASSED");
      $display(">>> PASS <<<");                   // the design's make test-ip marker
    end else begin
      $display("TEST FAILED (%0d errors)", errors);
    end
    $finish;
  end
  initial begin
    #10_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
