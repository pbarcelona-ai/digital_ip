// ***************
// Filename: sharpen_cas.sv
// Author: FPGA Cores 4 U
// Description: Contrast-adaptive sharpening (CAS) filter for AXI4-Stream video, after
//   AMD FidelityFX CAS. Same-size in / out; 3x3 neighbourhood; line-buffer
//   architecture (about two lines of latency, no frame buffer).
//
//   Per pixel and per component, with neighbourhood
//        a b c
//        d e f        (e = centre, M = 2^COMP_W - 1, edges clamp)
//        g h i
//     mn   = min(b,d,e,f,h) + min(a..i)          0 .. 2M   (soft minimum)
//     mx   = max(b,d,e,f,h) + max(a..i)          0 .. 2M   (soft maximum)
//     head = min(mn, 2M - mx)                   headroom before clipping
//     amp  = min(256, (head * RECIP[mx] + 2^15) >> 16),  RECIP[v] = round(2^24 / v)
//            (amp = 256 * head / mx; 0 when mx = 0)          Q8, 0..256
//     sq   = SQRT[amp] = round(16 * sqrt(amp))                Q8, 0..256
//     k    = (sq * G + 128) >> 8,  G = GAIN[SHARPNESS] = round(65536 / (1024 - 3*SHARPNESS))
//     out  = clamp(e + ((k * (4e - b - d - f - h) + 128) >>> 8), 0, M)
//
//   k is the unsharp-mask strength. amp is large in flat or low-contrast areas
//   with headroom and small near clipping or on strong edges, so detail is
//   enhanced without halos. SHARPNESS 0..256 maps the peak strength k from
//   0.25 (G = 64) to 1.0 (G = 256), matching CAS's lerp(8, 5, sharpness)
//   peak. The normalisation divide of the reference CAS, 1 / (1 + 4w), is
//   folded into the unsharp form e + k (4e - neighbours); this is exact at
//   amp = 0 and amp = 1 and monotonic in between (see docs).
//
//   Frame handling: the first beat of a frame must carry tuser (earlier beats
//   are dropped and flag SOF_ERR); tlast must mark column SIZE.W-1 (EOL_ERR);
//   SIZE and SHARPNESS are latched at start of frame. Input is back-pressured
//   when all four line buffers are in use.
//
//   Registers (AXI4-Lite, byte addresses)
//     0x000 CTRL      [0] ENABLE  [1] BYPASS (pass pixels through unchanged)
//     0x004 STATUS    [0] BUSY (RO) [1] FRAME_DONE* [2] SOF_ERR* [3] EOL_ERR*  (*W1C)
//     0x008 SIZE      [15:0] width  [31:16] height
//     0x020 FRAME_CNT (RO)
//     0x024 IP_ID     (RO) "SHRP"
//     0x028 CAPS      (RO) [7:0] 3 (kernel) [15:8] CHANNELS [23:16] COMP_W
//     0x02C MAX_SIZE  (RO) [15:0] MAX_W
//     0x040 SHARPNESS [8:0] 0..256  (0 = gentle, 256 = maximum)
//
//   Throughput: 1 pixel / clock (W+1 cycles per line).
//   Dependencies: axil_regbus
// Date: 2026-09-26

module sharpen_cas #(
  parameter int CHANNELS = 3,
  parameter int COMP_W   = 8,
  parameter int MAX_W    = 1920,
  parameter int ADDR_W   = 8,
  localparam int PIX_W   = CHANNELS * COMP_W
)(
  input  logic              clk,
  input  logic              rst_n,
  // AXI4-Lite
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
  // AXI4-Stream in
  input  logic [PIX_W-1:0]  s_axis_tdata,
  input  logic              s_axis_tvalid,
  output logic              s_axis_tready,
  input  logic              s_axis_tuser,
  input  logic              s_axis_tlast,
  // AXI4-Stream out
  output logic [PIX_W-1:0]  m_axis_tdata,
  output logic              m_axis_tvalid,
  input  logic              m_axis_tready,
  output logic              m_axis_tuser,
  output logic              m_axis_tlast
);
