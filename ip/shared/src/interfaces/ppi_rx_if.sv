// ***************
// Filename: ppi_rx_if.sv
// Author: FPGA Cores 4 U
// Description: MIPI D-PHY receive PHY-Protocol Interface (PPI RxDataHS / RxValidHS) between the
//   (vendor) D-PHY and a CSI-2 receiver. Modules take widths as parameters (no $bits on interface
//   members: Icarus); connect a port with the plain instance name (.p(u_if)). A top-level module
//   for synthesis keeps discrete ports (ip/scripts/syn_wrap.py writes the wrapper).
// Date: 2026-10-16
interface ppi_rx_if #(
  parameter int NLANES = 2
) ();
  logic [NLANES*8-1:0] lane_data;       // byte of lane i in [8i +: 8], sync byte stripped
  logic [NLANES-1:0] lane_valid;        // lane i in an HS burst
  // NLANES: data lanes

  modport phy (output lane_data, lane_valid);
  modport link (input lane_data, lane_valid);
  modport monitor (input lane_data, lane_valid);
endinterface
