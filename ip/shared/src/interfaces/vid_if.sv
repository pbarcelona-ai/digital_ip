// ***************
// Filename: vid_if.sv
// Author: FPGA Cores 4 U
// Description: Timed (parallel) video: pixel data with data enable and syncs on the pixel clock,
//   as driven to a display (axis_to_video, vid_timing_gen) and taken by the link transmitters
//   (hdmi_tx, lvds_tx, dsi_tx, csi2_tx). Modules take widths as parameters (no $bits on interface
//   members: Icarus); connect a port with the plain instance name (.p(u_if)). A top-level module
//   for synthesis keeps discrete ports (ip/scripts/syn_wrap.py writes the wrapper). A timing-only
//   source (vid_timing_gen) ties data to 0.
// Date: 2026-10-16
interface vid_if #(
  parameter int DATA_W = 24
) ();
  logic [DATA_W-1:0] data;              // pixel, component 0 in the LSBs
  logic de;                             // data enable (active area)
  logic hs;                             // horizontal sync (polarity per the timing)
  logic vs;                             // vertical sync
  // DATA_W: pixel width
  // width DATA_W = data

  modport source (output data, de, hs, vs);
  modport sink (input data, de, hs, vs);
  modport monitor (input data, de, hs, vs);
endinterface
