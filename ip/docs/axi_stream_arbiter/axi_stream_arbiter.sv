// ***************
// Filename: axi_stream_arbiter.sv
// Author: FPGA Cores 4 U
// Description: AXI-Stream arbiter (N inputs to one output). Version 1.0.0.
//   Packet-granular arbitration - once an input wins, it keeps the output
//   until its tlast beat has been transferred, so packets from different
//   inputs are never interleaved. PRIORITY 0 is round-robin (the input
//   after the last winner is preferred), 1 is fixed priority with input 0
//   highest. Signals are packed vectors (input i uses slice i). The output
//   is a registered slice (one extra register stage, full throughput).
//   Clock - aclk. Reset - synchronous aresetn, idle, no owner. Latency - 2
//   clocks from arbitration to first output beat; back-to-back packets
//   from different inputs add 1 idle clock. Errors - a packet longer than
//   TIMEOUT beats without tlast releases the grant (locked_out inputs are
//   not starved) and raises hog_o; TIMEOUT=0 disables. NIN<2 rejected at
//   elaboration.
// Date: 2026-09-29

module axi_stream_arbiter #(
  parameter int NIN      = 4,
  parameter int DATA_W   = 32,
  parameter int USER_W   = 1,
  parameter int PRIORITY = 0,
  parameter int TIMEOUT  = 0
) (
  input  logic                     aclk,
  input  logic                     aresetn,
  input  logic [NIN*DATA_W-1:0]    s_axis_tdata,
  input  logic [NIN*(DATA_W/8)-1:0] s_axis_tkeep,
  input  logic [NIN-1:0]           s_axis_tlast,
  input  logic [NIN*USER_W-1:0]    s_axis_tuser,
  input  logic [NIN-1:0]           s_axis_tvalid,
  output logic [NIN-1:0]           s_axis_tready,
  output logic [DATA_W-1:0]        m_axis_tdata,
  output logic [DATA_W/8-1:0]      m_axis_tkeep,
  output logic                     m_axis_tlast,
  output logic [USER_W-1:0]        m_axis_tuser,
  output logic [$clog2(NIN)-1:0]   m_axis_tid,
  output logic                     m_axis_tvalid,
  input  logic                     m_axis_tready,
  output logic                     hog_o
);
