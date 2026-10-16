// ***************
// Filename: axi4_lite_slave.sv
// Author: FPGA Cores 4 U
// Description: Generic AXI4-Lite slave front end. Version 1.0.0. Converts
//   AXI4-Lite transactions into a simple register-access interface for
//   user logic: a write strobe (wr_en_o with addr, data, byte strobes) and
//   a read request (rd_en_o with addr) completed by the user through
//   rd_valid_i/rd_data_i (or immediately when READ_WAIT=0, data taken
//   combinationally from rd_data_i in the cycle after rd_en_o). Write
//   address and data channels are accepted independently and combined. The
//   user may flag an error on either access (wr_err_i, valid two clocks
//   after wr_en_o starts, i.e. the clock after it ends; rd_err_i with the
//   read data) which returns SLVERR; an access to an address >=
//   ADDR_LIMIT_W-mapped range returns DECERR. Clock - aclk only. Reset -
//   synchronous aresetn (active low), all channels idle. Latency - write:
//   2 clocks from both AW and W accepted to bvalid; read: 2 clocks (+ user
//   latency). One transaction outstanding per direction. Errors -
//   SLVERR/DECERR as above; ADDR_W < 2 rejected at elaboration.
// Date: 2026-09-29

module axi4_lite_slave #(
  parameter int ADDR_W     = 8,
  parameter int READ_WAIT  = 0,            // 0: rd_data_i valid the cycle after rd_en_o; 1: wait for rd_valid_i
  parameter int MAP_WORDS  = 0             // 0: full address space valid, else words [0, MAP_WORDS) valid
) (
  input  logic              aclk,
  input  logic              aresetn,
  input  logic [ADDR_W-1:0] s_axil_awaddr,
  input  logic              s_axil_awvalid,
  output logic              s_axil_awready,
  input  logic [31:0]       s_axil_wdata,
  input  logic [3:0]        s_axil_wstrb,
  input  logic              s_axil_wvalid,
  output logic              s_axil_wready,
  output logic [1:0]        s_axil_bresp,
  output logic              s_axil_bvalid,
  input  logic              s_axil_bready,
  input  logic [ADDR_W-1:0] s_axil_araddr,
  input  logic              s_axil_arvalid,
  output logic              s_axil_arready,
  output logic [31:0]       s_axil_rdata,
  output logic [1:0]        s_axil_rresp,
  output logic              s_axil_rvalid,
  input  logic              s_axil_rready,
  // User register interface
  output logic              wr_en_o,       // one clock
  output logic [ADDR_W-1:0] wr_addr_o,
  output logic [31:0]       wr_data_o,
  output logic [3:0]        wr_strb_o,
  input  logic              wr_err_i,      // sampled in the cycle after wr_en_o
  output logic              rd_en_o,       // one clock
  output logic [ADDR_W-1:0] rd_addr_o,
  input  logic [31:0]       rd_data_i,
  input  logic              rd_valid_i,    // READ_WAIT=1 only
  input  logic              rd_err_i
);
