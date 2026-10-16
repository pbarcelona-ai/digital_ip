// ***************
// Filename: memory_arbiter.sv
// Author: FPGA Cores 4 U
// Description: Arbiter between CLIENTS memory clients and one memory port.
//   Version 1.0.0. Each client presents req/we/addr/wdata with a ready
//   handshake (a request is accepted when c_req and c_ready are both
//   high). PRIORITY 0 is round-robin (fair, last granted client has lowest
//   priority next), 1 is fixed priority with client 0 highest. Read
//   responses come back in order from the memory (m_rvalid_i/m_rdata_i,
//   any fixed or variable latency) and are routed to the client that
//   issued the read using an internal order FIFO of MAX_OUT entries; new
//   reads are stalled when it is full. Writes need no response. Clock -
//   clk. Reset - synchronous active low. Latency - grant is combinational
//   (0 clocks from request to m_req when m_ready_i); read data is passed
//   through with 0 added latency. Timing - address and data muxes are
//   CLIENTS wide, register client outputs for large CLIENTS at 100 MHz.
//   Errors - a memory response with no outstanding read raises err_o
//   (sticky, cleared by clr_err_i).
// Date: 2026-09-29

module memory_arbiter #(
  parameter int CLIENTS  = 4,
  parameter int ADDR_W   = 16,
  parameter int DATA_W   = 32,
  parameter int PRIORITY = 0,            // 0 round-robin, 1 fixed
  parameter int MAX_OUT  = 4             // outstanding reads (power of two)
) (
  input  logic                       clk,
  input  logic                       rst_n,
  // Client side (packed vectors)
  input  logic [CLIENTS-1:0]         c_req_i,
  input  logic [CLIENTS-1:0]         c_we_i,
  input  logic [CLIENTS*ADDR_W-1:0]  c_addr_i,
  input  logic [CLIENTS*DATA_W-1:0]  c_wdata_i,
  output logic [CLIENTS-1:0]         c_ready_o,
  output logic [CLIENTS-1:0]         c_rvalid_o,
  output logic [DATA_W-1:0]          c_rdata_o,       // shared read data bus
  // Memory side
  output logic                       m_req_o,
  output logic                       m_we_o,
  output logic [ADDR_W-1:0]          m_addr_o,
  output logic [DATA_W-1:0]          m_wdata_o,
  input  logic                       m_ready_i,
  input  logic                       m_rvalid_i,
  input  logic [DATA_W-1:0]          m_rdata_i,
  input  logic                       clr_err_i,
  output logic                       err_o
);
