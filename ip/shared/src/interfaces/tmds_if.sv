// ***************
// Filename: tmds_if.sv
// Author: FPGA Cores 4 U
// Description: TMDS symbols of one pixel clock (DVI 1.0 / HDMI): three 10-bit channel symbols and
//   the clock pattern, from the link layer (hdmi_tx) to a 10:1 serializer. Modules take widths as
//   parameters (no $bits on interface members: Icarus); connect a port with the plain instance
//   name (.p(u_if)). A top-level module for synthesis keeps discrete ports
//   (ip/scripts/syn_wrap.py writes the wrapper).
// Date: 2026-10-16
interface tmds_if ();
  logic [9:0] ch0;                      // channel 0 (blue + syncs) symbol, bit 0 first
  logic [9:0] ch1;                      // channel 1 (green)
  logic [9:0] ch2;                      // channel 2 (red)
  logic [9:0] clk;                      // clock channel pattern 1111100000

  modport source (output ch0, ch1, ch2, clk);
  modport sink (input ch0, ch1, ch2, clk);
  modport monitor (input ch0, ch1, ch2, clk);
endinterface
