// ***************
// Filename: video_processor_map_pkg.sv
// Author: FPGA Cores 4 U
// Description: Memory map of video_processor. The CPU domain is py_soc's
//   map (py_soc_map_pkg, imported); the pixel-clock domain is one AXI4-Lite
//   interface in py_soc's EXT window, decoded by address (u_vbus) into the
//   register windows below (*_OFFSET / *_MASK, offsets in the EXT window).
//   The video_pipeline window holds that block's own two maps
//   (video_pipeline_map_pkg: its registers and the scaler's). *_BASE are
//   the CPU addresses. The decoder (src/video_processor.sv), the testbench
//   and the firmware (pyc.py: "from video_processor_map_pkg import *") read
//   the addresses from this file. Every window starts with the block's ID
//   block (ID / VERSION / DATE at +0x00-0x08).
// Date: 2026-10-25
package video_processor_map_pkg;
  import py_soc_map_pkg::*;
  import video_pipeline_map_pkg::*;
  // ---------------- pixel-domain windows (offsets in the EXT window)
  localparam logic [31:0] VP_OFFSET  = 32'h0000_0000;   // video_pipeline (+ scaler at +SCALER_OFFSET)
  localparam logic [31:0] VP_MASK    = 32'hFFFF_8000;   // 0x0000-0x7FFF
  localparam logic [31:0] VS_OFFSET  = 32'h0000_8000;   // vision_system (ID "VSYS")
  localparam logic [31:0] VS_MASK    = 32'hFFFF_FF00;
  localparam logic [31:0] FLT_OFFSET = 32'h0000_8200;   // blur_sharpen, analysis path (ID "BLSH")
  localparam logic [31:0] FLT_MASK   = 32'hFFFF_FE00;
  localparam logic [31:0] FLTD_OFFSET = 32'h0000_8600;  // blur_sharpen, display path (ID "BLSH")
  localparam logic [31:0] FLTD_MASK   = 32'hFFFF_FE00;
  localparam logic [31:0] FC_OFFSET  = 32'h0000_8400;   // frame_counter (ID "FCNT")
  localparam logic [31:0] FC_MASK    = 32'hFFFF_FF00;
  localparam logic [31:0] FEAT_OFFSET = 32'h0000_8500;  // feature_detect (ID "FEAT"): edge / motion features
  localparam logic [31:0] FEAT_MASK   = 32'hFFFF_FF00;
  // object_tracker detectors (ID "OTRK"), one per object class, TRK_STRIDE apart: detector c at
  // TRK_OFFSET + c * TRK_STRIDE; class 0 pedestrian, 1 face, 2 automobile, 3 other vehicle, 4 aircraft
  localparam int          NTRK       = 5;
  localparam logic [31:0] TRK_OFFSET = 32'h0000_9000;   // 0x9000, 0x9200, 0x9400, 0x9600, 0x9800
  localparam logic [31:0] TRK_STRIDE = 32'h0000_0200;
  localparam logic [31:0] TRK_MASK   = 32'hFFFF_FE00;
  localparam logic [31:0] OVL_OFFSET = 32'h0000_8C00;   // symbol_overlay (ID "SOVL")
  localparam logic [31:0] OVL_MASK   = 32'hFFFF_FC00;
  localparam logic [31:0] NPU_OFFSET = 32'h0000_A000;   // npu (ID "NPU8", `VP_NPU)
  localparam logic [31:0] NPU_MASK   = 32'hFFFF_FF00;
  // ---------------- DDR byte addresses (`VP_DDR; 256 MB as the system model's DDR): 0x1000 the NPU header,
  // 0x0010_0000 the NPU frame buffer, 0x0080_0000 the detection list (sw/bytetrack.py), 0x0100_0000 on the
  // NPU program, weights and tensors (npu_compiler.py), at the top vision_system's two frame buffers, 8 MB
  // each (32-bit pixel slots: up to 2**21 pixels, a 1920 x 1080 frame)
  localparam logic [31:0] DDR_VS_FB0     = 32'h0F00_0000;
  localparam logic [31:0] DDR_VS_FB1     = 32'h0F80_0000;
  localparam logic [31:0] DDR_VS_FB_SIZE = 32'h0080_0000;
  // ---------------- CPU addresses (for the testbench and the firmware; the RTL uses the offsets)
  /* verilator lint_off UNUSEDPARAM */
  localparam logic [31:0] VP_BASE     = py_soc_map_pkg::EXT_BASE + VP_OFFSET;
  localparam logic [31:0] SCALER_BASE = VP_BASE + video_pipeline_map_pkg::SCALER_OFFSET;
  localparam logic [31:0] VS_BASE     = py_soc_map_pkg::EXT_BASE + VS_OFFSET;
  localparam logic [31:0] FLT_BASE    = py_soc_map_pkg::EXT_BASE + FLT_OFFSET;
  localparam logic [31:0] FLTD_BASE   = py_soc_map_pkg::EXT_BASE + FLTD_OFFSET;
  localparam logic [31:0] FC_BASE     = py_soc_map_pkg::EXT_BASE + FC_OFFSET;
  localparam logic [31:0] FEAT_BASE   = py_soc_map_pkg::EXT_BASE + FEAT_OFFSET;
  localparam logic [31:0] TRK_BASE    = py_soc_map_pkg::EXT_BASE + TRK_OFFSET;   // detector 0; c: + c * TRK_STRIDE
  localparam logic [31:0] OVL_BASE    = py_soc_map_pkg::EXT_BASE + OVL_OFFSET;
  localparam logic [31:0] NPU_BASE    = py_soc_map_pkg::EXT_BASE + NPU_OFFSET;
  /* verilator lint_on UNUSEDPARAM */
endpackage
