// ***************
// Filename: ddr_ctrl_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking directed testbench for ddr_ctrl_top in front
//   of ddr_mem (2 ports, 64-bit words, 4 banks x 16 rows x 8 columns,
//   T_REFI 200). Checks, independently of the Python model (a byte-array
//   shadow memory in the testbench): bursts written on both ports read back
//   with their IDs, RLAST and OKAY, with random gaps on W and back-pressure
//   on R and B; concurrent traffic from both ports; partial write strobes;
//   SLVERR (wrong size, FIXED burst) and DECERR (beyond the memory) with
//   read data 0 and the memory untouched; refreshes kept on schedule; the
//   statistics counters and their clear; ID / VERSION and SLVERR on a
//   read-only write; and that ddr_mem never reports a timing violation
//   (every DDR timing rule kept). +define+MUTATE corrupts one shadow byte:
//   the testbench must then fail (mutation check). Test tasks in
//   tests/ddr_ctrl_tests.sv. Prints TEST PASSED on success.
// Date: 2026-10-25
`timescale 1ns/1ps
module ddr_ctrl_tb;
  localparam int NP = 2, DW = 64, AW = 32, IW = 4, BW = 2, RW = 4, CW = 3;
  localparam int NB = DW / 8;
  localparam int WORDS = 1 << (BW + RW + CW);
  localparam int T_RCD = 3, T_RP = 3, T_RAS = 6, T_CL = 4, T_WR = 3, T_RTP = 2, T_WTR = 2, T_RRD = 2;
  localparam int T_RFC = 12, T_REFI = 200;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // AXI4-Lite control
  axil_if #(.ADDR_W(8)) bus ();
  axil_bfm #(.ADDR_W(8)) u_bfm (
    .aclk(clk),
    .s_axil(bus)
  );

  // per-port AXI4 signals, driven by the port tasks
  logic [IW-1:0] awid [NP], arid [NP];
  logic [AW-1:0] awaddr [NP], araddr [NP];
  logic [7:0]    awlen [NP], arlen [NP];
  logic [2:0]    awsize [NP], arsize [NP];
  logic [1:0]    awburst [NP], arburst [NP];
  logic          awvalid [NP], arvalid [NP], wvalid [NP], wlast [NP], bready [NP], rready [NP];
  logic [DW-1:0] wdata [NP];
  logic [NB-1:0] wstrb [NP];
  logic [NP*IW-1:0] s_awid, s_arid, s_bid, s_rid;
  logic [NP*AW-1:0] s_awaddr, s_araddr;
  logic [NP*8-1:0]  s_awlen, s_arlen;
  logic [NP*3-1:0]  s_awsize, s_arsize;
  logic [NP*2-1:0]  s_awburst, s_arburst, s_bresp, s_rresp;
  logic [NP-1:0]    s_awvalid, s_awready, s_wlast, s_wvalid, s_wready, s_bvalid, s_bready;
  logic [NP-1:0]    s_arvalid, s_arready, s_rlast, s_rvalid, s_rready;
  logic [NP*DW-1:0] s_wdata, s_rdata;
  logic [NP*NB-1:0] s_wstrb;
  always_comb begin
    for (int p = 0; p < NP; p++) begin
      s_awid[p*IW +: IW] = awid[p];
      s_awaddr[p*AW +: AW] = awaddr[p];
      s_awlen[p*8 +: 8] = awlen[p];
      s_awsize[p*3 +: 3] = awsize[p];
      s_awburst[p*2 +: 2] = awburst[p];
      s_awvalid[p] = awvalid[p];
      s_wdata[p*DW +: DW] = wdata[p];
      s_wstrb[p*NB +: NB] = wstrb[p];
      s_wlast[p] = wlast[p];
      s_wvalid[p] = wvalid[p];
      s_bready[p] = bready[p];
      s_arid[p*IW +: IW] = arid[p];
      s_araddr[p*AW +: AW] = araddr[p];
      s_arlen[p*8 +: 8] = arlen[p];
      s_arsize[p*3 +: 3] = arsize[p];
      s_arburst[p*2 +: 2] = arburst[p];
      s_arvalid[p] = arvalid[p];
      s_rready[p] = rready[p];
    end
  end

  // controller and memory (DFI)
  logic [2:0]    dfi_cmd;
  logic [BW-1:0] dfi_bank;
  logic [RW-1:0] dfi_row;
  logic [CW-1:0] dfi_col;
  logic [DW-1:0] dfi_wrdata, dfi_rddata;
  logic [NB-1:0] dfi_wrstrb;
  logic          dfi_rv, mem_err;
  logic [3:0]    mem_err_code;
  logic [15:0]   mem_err_cnt;
  ddr_ctrl_top #(
    .NPORTS(NP),
    .DATA_W(DW),
    .ADDR_W(AW),
    .ID_W(IW),
    .BANK_W(BW),
    .ROW_W(RW),
    .COL_W(CW),
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
    .PRIORITY(0),
    .RQ_DEPTH(8),
    .BQ_DEPTH(2)
  ) dut (
    .clk,
    .rst_n,
    .s_axil(bus),
    .s_axi_awid(s_awid),
    .s_axi_awaddr(s_awaddr),
    .s_axi_awlen(s_awlen),
    .s_axi_awsize(s_awsize),
    .s_axi_awburst(s_awburst),
    .s_axi_awvalid(s_awvalid),
    .s_axi_awready(s_awready),
    .s_axi_wdata(s_wdata),
    .s_axi_wstrb(s_wstrb),
    .s_axi_wlast(s_wlast),
    .s_axi_wvalid(s_wvalid),
    .s_axi_wready(s_wready),
    .s_axi_bid(s_bid),
    .s_axi_bresp(s_bresp),
    .s_axi_bvalid(s_bvalid),
    .s_axi_bready(s_bready),
    .s_axi_arid(s_arid),
    .s_axi_araddr(s_araddr),
    .s_axi_arlen(s_arlen),
    .s_axi_arsize(s_arsize),
    .s_axi_arburst(s_arburst),
    .s_axi_arvalid(s_arvalid),
    .s_axi_arready(s_arready),
    .s_axi_rid(s_rid),
    .s_axi_rdata(s_rdata),
    .s_axi_rresp(s_rresp),
    .s_axi_rlast(s_rlast),
    .s_axi_rvalid(s_rvalid),
    .s_axi_rready(s_rready),
    .dfi_cmd_o(dfi_cmd),
    .dfi_bank_o(dfi_bank),
    .dfi_row_o(dfi_row),
    .dfi_col_o(dfi_col),
    .dfi_wrdata_o(dfi_wrdata),
    .dfi_wrstrb_o(dfi_wrstrb),
    .dfi_rddata_valid_i(dfi_rv),
    .dfi_rddata_i(dfi_rddata)
  );
  ddr_mem #(
    .DATA_W(DW),
    .BANK_W(BW),
    .ROW_W(RW),
    .COL_W(CW),
    .MEM_WORDS(WORDS),
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
    .wrdata_i(dfi_wrdata),
    .wrstrb_i(dfi_wrstrb),
    .rddata_valid_o(dfi_rv),
    .rddata_o(dfi_rddata),
    .err_o(mem_err),
    .err_code_o(mem_err_code),
    .err_cnt_o(mem_err_cnt)
  );

  // independent shadow memory (bytes) and DFI command counters
  logic [7:0] shadow [WORDS*NB];
  int n_ref = 0, n_act = 0, n_rd = 0, n_wr = 0;
  always @(posedge clk) begin
    if (rst_n) begin
      n_ref <= n_ref + int'(dfi_cmd == 3'd6);
      n_act <= n_act + int'(dfi_cmd == 3'd1);
      n_rd  <= n_rd + int'(dfi_cmd == 3'd2);
      n_wr  <= n_wr + int'(dfi_cmd == 3'd3);
    end
  end
  int errors = 0;
  `include "ddr_ctrl_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("ddr_ctrl_tb.vcd");
      $dumpvars(0, ddr_ctrl_tb);
    end
    for (int i = 0; i < WORDS * NB; i++) shadow[i] = 8'h00;
    for (int p = 0; p < NP; p++) port_idle(p);
    repeat (4) @(posedge clk);
    #1 rst_n = 1;
    repeat (2) @(posedge clk);
    test_register_map();
    test_write_read();
    test_both_ports();
    test_strobes();
    test_errors();
    test_refresh();
    test_statistics();
    test_timing_kept();
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #5_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
