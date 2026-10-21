// ***************
// Filename: ddr_mem_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking directed testbench for ddr_mem (small
//   configuration: 32-bit words, 4 banks, T_CL 3). Checks, independently of
//   the Python model: written words read back T_CL clocks after RD, partial
//   byte strobes, unwritten words read 0, rows kept per bank, and that each
//   timing rule (tRCD, tRP, tRAS, tWR, tRFC, a closed bank, the refresh
//   deadline) sets err_o with its code. The exact clock-by-clock comparison
//   with the model is tb/python. Test tasks in tests/ddr_mem_tests.sv.
//   Prints TEST PASSED on success.
// Date: 2026-10-21
`timescale 1ns/1ps
module ddr_mem_tb;
  localparam int DW = 32, BW = 2, RW = 4, CW = 3, T_CL = 3, T_RCD = 2, T_RP = 2, T_RAS = 4, T_WR = 2, T_RFC = 5;
  localparam int REF_MAX = 200;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  logic [2:0]    cmd = '0;
  logic [BW-1:0] bank = '0;
  logic [RW-1:0] row = '0;
  logic [CW-1:0] col = '0;
  logic [DW-1:0] wrdata = '0;
  logic [3:0]    wrstrb = '0;
  logic          rv, err;
  logic [DW-1:0] rd;
  logic [3:0]    code;
  logic [15:0]   cnt;
  ddr_mem #(
    .DATA_W(DW),
    .BANK_W(BW),
    .ROW_W(RW),
    .COL_W(CW),
    .MEM_WORDS(1 << (BW + RW + CW)),
    .T_RCD(T_RCD),
    .T_RP(T_RP),
    .T_RAS(T_RAS),
    .T_CL(T_CL),
    .T_WR(T_WR),
    .T_RTP(1),
    .T_WTR(1),
    .T_RRD(1),
    .T_RFC(T_RFC),
    .REF_MAX(REF_MAX)
  ) dut (
    .clk,
    .rst_n,
    .cmd_i(cmd),
    .bank_i(bank),
    .row_i(row),
    .col_i(col),
    .wrdata_i(wrdata),
    .wrstrb_i(wrstrb),
    .rddata_valid_o(rv),
    .rddata_o(rd),
    .err_o(err),
    .err_code_o(code),
    .err_cnt_o(cnt)
  );
  int errors = 0;
  `include "ddr_mem_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("ddr_mem_tb.vcd");
      $dumpvars(0, ddr_mem_tb);
    end
    test_write_read();
    test_timing_checks();
    test_refresh_deadline();
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #1_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
