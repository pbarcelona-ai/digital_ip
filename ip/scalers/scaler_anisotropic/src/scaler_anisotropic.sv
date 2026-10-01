// ***************
// Filename: scaler_anisotropic.sv
// Author: FPGA Cores 4 U
// Description: Anisotropic (multi-probe mip-map) scaler IP.
//   Wrapper around scaler_mip with ANISO_MAX_LOG2 = 4: up to 16 trilinear
//   probes per output pixel, spread along the major axis of the pixel
//   footprint. Keeps detail on the less-reduced axis when the X and Y
//   scale factors differ strongly (e.g. 1920x1080 -> 1920x270).
//   Throughput is 1/NP output pixels per clock.
//   LOD / probe registers: see docs/coefficient_derivation.md section 6.
//   Registers: common map (scaler_ctrl) + scaler_mip (0x040..0x07C).
//   IP_ID = "ANIS".
//   Uses: scaler_mip, axil_regbus, scaler_ctrl, scaler_dda,
//   banked_framebuf.
// Date: 2026-09-26

module scaler_anisotropic #(
  parameter int CHANNELS   = 3,        // components per pixel
  parameter int COMP_W     = 8,        // bits per component
  parameter int MAX_W      = 1920,     // frame buffer width
  parameter int MAX_H      = 1080,     // frame buffer height
  parameter int ADDR_W     = 14,       // AXI-Lite address width
  parameter int LEVELS     = 5,        // mip levels incl. level 0
  parameter int PHASE_BITS = 8,        // sub-pixel phase resolution
  parameter int PINGPONG   = 0,        // 1: double frame buffer
  localparam int PIX_W     = CHANNELS * COMP_W // bits per pixel
)(
  input  logic              clk,            // clock
  input  logic              rst_n,          // async reset, active low
  // AXI4-Lite control slave (register map in the file header)
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
  // AXI4-Stream video in (raster order)
  input  logic [PIX_W-1:0]  s_axis_tdata,   // pixel, component 0 in LSBs
  input  logic              s_axis_tvalid,
  output logic              s_axis_tready,  // low while generating
  input  logic              s_axis_tuser,   // start of frame
  input  logic              s_axis_tlast,   // end of line
  // AXI4-Stream video out (raster order)
  output logic [PIX_W-1:0]  m_axis_tdata,   // scaled pixel
  output logic              m_axis_tvalid,
  input  logic              m_axis_tready,  // back-pressure stalls all
  output logic              m_axis_tuser,   // start of frame
  output logic              m_axis_tlast    // end of line
);

  // All logic is in scaler_mip; this wrapper allows up to 2^4 = 16
  // probes per pixel and sets the IP_ID. Ports connect by name (.*).
  scaler_mip #(
    .PINGPONG(PINGPONG),
    .CHANNELS(CHANNELS), .COMP_W(COMP_W), .MAX_W(MAX_W), .MAX_H(MAX_H),
    .ADDR_W(ADDR_W), .LEVELS(LEVELS), .ANISO_MAX_LOG2(4),
    .PHASE_BITS(PHASE_BITS), .IP_ID(32'h414E_4953)              // "ANIS"
  ) u_core (.*);

endmodule
