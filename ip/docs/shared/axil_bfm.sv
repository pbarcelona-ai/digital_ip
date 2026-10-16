// ***************
// Filename: axil_bfm.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Lite bus functional model (master) for testbenches.
//   Port names match the s_axil_* ports of every IP so it connects with a
//   .* port list. Provides blocking write() and read() tasks that are
//   called hierarchically, plus an error counter for non-OKAY responses.
//   Address width is a parameter.
// Date: 2026-09-29

module axil_bfm #(
  parameter int ADDR_W = 8
) (
  input  logic              aclk,
  output logic [ADDR_W-1:0] s_axil_awaddr,
  output logic              s_axil_awvalid,
  input  logic              s_axil_awready,
  output logic [31:0]       s_axil_wdata,
  output logic [3:0]        s_axil_wstrb,
  output logic              s_axil_wvalid,
  input  logic              s_axil_wready,
  input  logic [1:0]        s_axil_bresp,
  input  logic              s_axil_bvalid,
  output logic              s_axil_bready,
  output logic [ADDR_W-1:0] s_axil_araddr,
  output logic              s_axil_arvalid,
  input  logic              s_axil_arready,
  input  logic [31:0]       s_axil_rdata,
  input  logic [1:0]        s_axil_rresp,
  input  logic              s_axil_rvalid,
  output logic              s_axil_rready
);
