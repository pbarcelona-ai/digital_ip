// ***************
// Filename: axil_if.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Lite interface of the FPGA Cores 4 U library, the
//   common definition every block's register-bus ports follow. Version 1.0.0.
//   Channels: write address (awaddr, awvalid, awready), write data (wdata,
//   wstrb, wvalid, wready), write response (bresp, bvalid, bready), read
//   address (araddr, arvalid, arready), read data (rdata, rresp, rvalid,
//   rready). Responses: 2'b00 OKAY, 2'b10 SLVERR (read-only word written,
//   word out of range), 2'b11 DECERR (no slave at the address). Handshake
//   rules: a transfer moves when valid and ready are both high; valid must
//   not depend on ready, and once high it stays high with stable payload.
//   Modports: master (drives the address / data / ready-for-response
//   signals), slave (drives the ready / response signals), monitor
//   (observes everything).
//   Tool note: Icarus Verilog cannot drive members of interface arrays (the
//   library's crossbars use arrays of slaves) and Yosys cannot read
//   interfaces without sv2v, so the library's modules keep discrete ports
//   named <prefix>_awaddr, <prefix>_awvalid, ... and name the interface and
//   modport in a comment above each port group, e.g.
//     // s_axil: axil_if.slave (ip/shared/src/interfaces/axil_if.sv), ADDR_W = 8
//   Testbenches and Verilator flows may use the interface directly.
//   Parameters - ADDR_W (2 .. 32), DATA_W (32). Clocks / resets - none (the
//   bus is synchronous to the clock of the blocks it connects).
// Date: 2026-10-16
interface axil_if #(
  parameter int ADDR_W = 32,                     // byte address width
  parameter int DATA_W = 32                      // data width (32)
) ();
  logic [ADDR_W-1:0]   awaddr;                   // write address
  logic                awvalid;
  logic                awready;
  logic [DATA_W-1:0]   wdata;                    // write data
  logic [DATA_W/8-1:0] wstrb;                    // byte strobes
  logic                wvalid;
  logic                wready;
  logic [1:0]          bresp;                    // write response
  logic                bvalid;
  logic                bready;
  logic [ADDR_W-1:0]   araddr;                   // read address
  logic                arvalid;
  logic                arready;
  logic [DATA_W-1:0]   rdata;                    // read data
  logic [1:0]          rresp;                    // read response
  logic                rvalid;
  logic                rready;

  modport master (output awaddr, awvalid, wdata, wstrb, wvalid, bready, araddr, arvalid, rready,
                  input awready, wready, bresp, bvalid, arready, rdata, rresp, rvalid);
  modport slave (input awaddr, awvalid, wdata, wstrb, wvalid, bready, araddr, arvalid, rready,
                 output awready, wready, bresp, bvalid, arready, rdata, rresp, rvalid);
  modport monitor (input awaddr, awvalid, awready, wdata, wstrb, wvalid, wready, bresp, bvalid, bready,
                   araddr, arvalid, arready, rdata, rresp, rvalid, rready);
endinterface
