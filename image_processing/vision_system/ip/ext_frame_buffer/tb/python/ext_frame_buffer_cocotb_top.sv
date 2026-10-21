// ***************
// Filename: ext_frame_buffer_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of ext_frame_buffer for the comparison with
//   its model (ext_frame_buffer_tb.py). The SDRAM data bus is split for
//   the test: dq_seen is the bus, the test's SDRAM responder drives tb_dq
//   onto it when tb_drive is set and the controller is not issuing a WRITE
//   (the controller drives the bus only then). Parameters as the module's,
//   small timings for the test. Clock - clk. Reset - rst_n (synchronous,
//   active low, as ext_frame_buffer).
// Date: 2026-10-21
module ext_frame_buffer_cocotb_top #(
  parameter int FIFO_DEPTH              = 32,
  parameter int INIT_WAIT_CYCLES        = 40,
  parameter int REFRESH_INTERVAL_CYCLES = 780,
  parameter int T_RAS_CYCLES            = 5,
  parameter int CAS_LATENCY             = 2
) (
  input  logic                         clk,
  input  logic                         rst_n,
  input  logic                         wr_en,
  output logic                         wr_ready,
  input  logic [barrel_pkg::ADDR_W-1:0] wr_addr,
  input  logic [23:0]                  wr_data,
  output logic                         wr_idle,
  input  logic                         rd_en,
  output logic                         rd_ready,
  input  logic [barrel_pkg::ADDR_W-1:0] rd_addr0,
  input  logic [barrel_pkg::ADDR_W-1:0] rd_addr1,
  input  logic [barrel_pkg::ADDR_W-1:0] rd_addr2,
  input  logic [barrel_pkg::ADDR_W-1:0] rd_addr3,
  output logic                         rd_valid,
  output logic [23:0]                  rd_data0,
  output logic [23:0]                  rd_data1,
  output logic [23:0]                  rd_data2,
  output logic [23:0]                  rd_data3,
  output logic                         sdram_cke,
  output logic                         sdram_cs_n,
  output logic                         sdram_ras_n,
  output logic                         sdram_cas_n,
  output logic                         sdram_we_n,
  output logic [12:0]                  sdram_a,
  output logic [1:0]                   sdram_ba,
  output logic [7:0]                   sdram_dqm,
  input  logic                         tb_drive,
  input  logic [63:0]                  tb_dq,
  output logic [63:0]                  dq_seen
);
  wire [63:0] dq;
  wire        sdram_clk;
  wire        ctrl_writes = !sdram_cs_n && sdram_ras_n && !sdram_cas_n && !sdram_we_n;
  assign dq = (tb_drive && !ctrl_writes) ? tb_dq : 64'bz;
  assign dq_seen = dq;
  ext_frame_buffer #(
    .FIFO_DEPTH(FIFO_DEPTH),
    .INIT_WAIT_CYCLES(INIT_WAIT_CYCLES),
    .T_RAS_CYCLES(T_RAS_CYCLES),
    .CAS_LATENCY(CAS_LATENCY),
    .REFRESH_INTERVAL_CYCLES(REFRESH_INTERVAL_CYCLES)
  ) u_dut (
    .clk,
    .rst_n,
    .wr_en,
    .wr_ready,
    .wr_addr,
    .wr_data,
    .wr_idle,
    .rd_en,
    .rd_ready,
    .rd_addr0,
    .rd_addr1,
    .rd_addr2,
    .rd_addr3,
    .rd_valid,
    .rd_data0,
    .rd_data1,
    .rd_data2,
    .rd_data3,
    .sdram_clk,
    .sdram_cke,
    .sdram_cs_n,
    .sdram_ras_n,
    .sdram_cas_n,
    .sdram_we_n,
    .sdram_a,
    .sdram_ba,
    .sdram_dqm,
    .sdram_dq(dq)
  );
  wire unused_ok = &{1'b0, sdram_clk, 1'b0};
endmodule
