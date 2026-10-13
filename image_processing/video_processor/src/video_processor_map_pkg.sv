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
// Date: 2026-10-12
package video_processor_map_pkg;
  import py_soc_map_pkg::*;
  import video_pipeline_map_pkg::*;
  // ---------------- pixel-domain windows (offsets in the EXT window)
  localparam logic [31:0] VP_OFFSET  = 32'h0000_0000;   // video_pipeline (+ scaler at +SCALER_OFFSET)
  localparam logic [31:0] VP_MASK    = 32'hFFFF_8000;   // 0x0000-0x7FFF
  localparam logic [31:0] VS_OFFSET  = 32'h0000_8000;   // vision_system (ID "VSYS")
  localparam logic [31:0] VS_MASK    = 32'hFFFF_FF00;
  localparam logic [31:0] FLT_OFFSET = 32'h0000_8200;   // blur_sharpen (ID "BLSH")
  localparam logic [31:0] FLT_MASK   = 32'hFFFF_FE00;
  localparam logic [31:0] FC_OFFSET  = 32'h0000_8400;   // frame_counter (ID "FCNT")
  localparam logic [31:0] FC_MASK    = 32'hFFFF_FF00;
  localparam logic [31:0] TRK_OFFSET = 32'h0000_8500;   // object_tracker (ID "OTRK")
  localparam logic [31:0] TRK_MASK   = 32'hFFFF_FF00;
  localparam logic [31:0] OVL_OFFSET = 32'h0000_8800;   // symbol_overlay (ID "SOVL")
  localparam logic [31:0] OVL_MASK   = 32'hFFFF_FC00;
  // ---------------- CPU addresses
  localparam logic [31:0] VP_BASE     = py_soc_map_pkg::EXT_BASE + VP_OFFSET;
  localparam logic [31:0] SCALER_BASE = VP_BASE + video_pipeline_map_pkg::SCALER_OFFSET;
  localparam logic [31:0] VS_BASE     = py_soc_map_pkg::EXT_BASE + VS_OFFSET;
  localparam logic [31:0] FLT_BASE    = py_soc_map_pkg::EXT_BASE + FLT_OFFSET;
  localparam logic [31:0] FC_BASE     = py_soc_map_pkg::EXT_BASE + FC_OFFSET;
  localparam logic [31:0] TRK_BASE    = py_soc_map_pkg::EXT_BASE + TRK_OFFSET;
  localparam logic [31:0] OVL_BASE    = py_soc_map_pkg::EXT_BASE + OVL_OFFSET;
endpackage
