// ***************
// Filename: scaler_mip.sv
// Author: FPGA Cores 4 U
// Description: Mip-map scaler engine (trilinear/anisotropic).
//   Engine of scaler_trilinear (ANISO_MAX_LOG2 = 0) and
//   scaler_anisotropic (ANISO_MAX_LOG2 > 0). Frame flow:
//   1. capture the input frame as mip level 0
//   2. build LEVELS-1 levels with a 2x2 box filter
//        m[k+1](x,y) = (sum of the 2x2 block of m[k] + 2) >> 2
//      W[k+1] = max(1, W[k] >> 1), same for H (clamp-to-edge)
//   3. per output pixel take NP = 2^ANISO_LOG2 probes at
//        probe[n] = src + PROBE_START + n*PROBE_STEP          (16.16)
//      each a trilinear sample of levels L and L+1:
//        u_k = ((u + 0.5) >> k) - 0.5      level-k coordinate
//        t   = (bil_L*(256-f) + bil_L+1*f + 128) >> 8
//      output = (sum t + NP/2) >> ANISO_LOG2
//      L = LOD[15:8], f = LOD[7:0]; at the top level f is forced to 0.
//   IP registers:
//     0x040 LOD (8.8)             0x044 ANISO_LOG2 (clamped)
//     0x048/0x04C PROBE_STEP_X/Y  0x050/0x054 PROBE_START_X/Y (s16.16)
//     0x058 MIP_INFO (RO)         0x060+4k LEVEL_SIZE[k] (RO)
//   Interfaces: AXI4-Lite control (common map in scaler_ctrl),
//   AXI4-Stream video in/out (tuser = SOF, tlast = EOL; pixel =
//   CHANNELS x COMP_W bits, component 0 in the LSBs).
//   Throughput: 1 probe/clock = 1/NP output pixels/clock.
//   Latency: one input frame plus mip build (about W*H/3 cycles).
//   PINGPONG = 1 double-buffers level 0 and the pyramid, so the next frame
//   is captured while the current one is built and sampled.
//   Uses: axil_regbus, scaler_ctrl, scaler_dda, banked_framebuf.
// Date: 2026-09-26

module scaler_mip #(
  parameter int CHANNELS = 3,        // components per pixel
  parameter int COMP_W   = 8,          // bits per component
  parameter int MAX_W    = 1920,       // frame buffer width
  parameter int MAX_H    = 1080,       // frame buffer height
  parameter int ADDR_W   = 14,         // AXI-Lite address width
  parameter int LEVELS        = 4,     // mip levels incl. level 0 (1..8)
  parameter int ANISO_MAX_LOG2 = 0,    // log2 of max probes (0..4)
  parameter int PHASE_BITS    = 8,     // bilinear phase resolution
  parameter logic [31:0] IP_ID = 32'h4D49_504D,               // "MIPM"
  parameter int PINGPONG      = 0,     // 1: double buffer (capture while generating)
  localparam int PIX_W   = CHANNELS * COMP_W   // bits per pixel
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
