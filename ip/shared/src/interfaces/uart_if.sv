// ***************
// Filename: uart_if.sv
// Author: FPGA Cores 4 U
// Description: UART serial pins of a DTE (transmit on txd, receive on rxd). Modules take widths
//   as parameters (no $bits on interface members: Icarus); connect a port with the plain instance
//   name (.p(u_if)). A top-level module for synthesis keeps discrete ports
//   (ip/scripts/syn_wrap.py writes the wrapper).
// Date: 2026-10-16
interface uart_if ();
  logic txd;                            // transmit data (idle 1)
  logic rxd;                            // receive data (idle 1)

  modport dte (output txd, input rxd);
  modport dce (output rxd, input txd);
  modport monitor (input txd, rxd);
endinterface
