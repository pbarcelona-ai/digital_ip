// ***************
// Filename: regbus_if.sv
// Author: FPGA Cores 4 U
// Description: Simple register bus between an AXI4-Lite front end (axi4_lite_slave, axil_regbus)
//   and the register block: one-clock write / read strobes, error answers that become SLVERR.
//   Modules take widths as parameters (no $bits on interface members: Icarus); connect a port
//   with the plain instance name (.p(u_if)). A top-level module for synthesis keeps discrete
//   ports (ip/scripts/syn_wrap.py writes the wrapper).
// Date: 2026-10-16
interface regbus_if #(
  parameter int ADDR_W = 8,
  parameter int DATA_W = 32
) ();
  logic wr;                             // write strobe (one clock)
  logic [ADDR_W-1:0] waddr;             // write byte address
  logic [DATA_W-1:0] wdata;             // write data
  logic [DATA_W/8-1:0] wstrb;           // byte strobes
  logic wr_err;                         // write refused (SLVERR), the clock after wr
  logic rd;                             // read strobe (one clock)
  logic [ADDR_W-1:0] raddr;             // read byte address
  logic [DATA_W-1:0] rdata;             // read data
  logic rd_valid;                       // rdata valid (1 when the device answers the clock after rd)
  logic rd_err;                         // read refused (SLVERR), with rdata
  // ADDR_W: byte address width
  // DATA_W: data width
  // width ADDR_W = waddr
  // width DATA_W = wdata

  modport host (output wr, waddr, wdata, wstrb, rd, raddr, input wr_err, rdata, rd_valid, rd_err);
  modport dev (output wr_err, rdata, rd_valid, rd_err, input wr, waddr, wdata, wstrb, rd, raddr);
  modport monitor (input wr, waddr, wdata, wstrb, wr_err, rd, raddr, rdata, rd_valid, rd_err);
endinterface
