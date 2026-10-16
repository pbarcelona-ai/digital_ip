// ***************
// Filename: ppi_tx_if.sv
// Author: FPGA Cores 4 U
// Description: MIPI D-PHY transmit PHY-Protocol Interface (PPI, D-PHY v1.2 TxRequestHS /
//   TxReadyHS / TxDataHS) between a CSI-2 / DSI packet engine and the (vendor) D-PHY. Modules
//   take widths as parameters (no $bits on interface members: Icarus); connect a port with the
//   plain instance name (.p(u_if)). A top-level module for synthesis keeps discrete ports
//   (ip/scripts/syn_wrap.py writes the wrapper).
// Date: 2026-10-16
interface ppi_tx_if #(
  parameter int NLANES = 2
) ();
  logic [NLANES*8-1:0] lane_data;       // byte of lane i in [8i +: 8]
  logic [NLANES-1:0] lane_valid;        // byte accepted on lane i
  logic hs_req;                         // TxRequestHS: start / hold the HS burst
  logic tx_ready;                       // TxReadyHS: the PHY takes the bytes
  // NLANES: data lanes

  modport link (output lane_data, lane_valid, hs_req, input tx_ready);
  modport phy (output tx_ready, input lane_data, lane_valid, hs_req);
  modport monitor (input lane_data, lane_valid, hs_req, tx_ready);
endinterface
