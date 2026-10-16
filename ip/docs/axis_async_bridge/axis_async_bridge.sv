// ***************
// Filename: axis_async_bridge.sv
// Author: FPGA Cores 4 U
// Description: AXI-Stream asynchronous clock domain bridge. Carries tdata,
//   tkeep, tlast and tuser from the slave clock domain to the master clock
//   domain through a gray pointer dual clock FIFO. Each side has an
//   independent active-low reset that is synchronized locally (async assert,
//   sync release). Optional depth for rate matching. Both resets should be
//   asserted together. Version 1.0.0. Clocks - s_clk and m_clk unrelated,
//   built on async_fifo with the same crossing rules and latency (3 to 5
//   destination clocks). Reset - synchronous active low per domain. Timing -
//   see async_fifo. Errors - none at run time (full FIFO deasserts s_tready,
//   nothing is dropped); illegal parameters stop elaboration. Clock - the
//   clock of the parent block, all signals are synchronous to it. Latency -
//   as documented in the parent block, fixed and independent of data.
//   as documented in the parent block, fixed and independent of data.
// Date: 2026-09-29

module axis_async_bridge #(
  parameter int DATA_W = 32,
  parameter int DEPTH  = 512,
  parameter int USER_W = 1
) (
  // Slave side
  input  logic                s_clk,
  input  logic                s_rst_n,
  input  logic [DATA_W-1:0]   s_axis_tdata,
  input  logic [DATA_W/8-1:0] s_axis_tkeep,
  input  logic                s_axis_tlast,
  input  logic [USER_W-1:0]   s_axis_tuser,
  input  logic                s_axis_tvalid,
  output logic                s_axis_tready,
  // Master side
  input  logic                m_clk,
  input  logic                m_rst_n,
  output logic [DATA_W-1:0]   m_axis_tdata,
  output logic [DATA_W/8-1:0] m_axis_tkeep,
  output logic                m_axis_tlast,
  output logic [USER_W-1:0]   m_axis_tuser,
  output logic                m_axis_tvalid,
  input  logic                m_axis_tready
);
