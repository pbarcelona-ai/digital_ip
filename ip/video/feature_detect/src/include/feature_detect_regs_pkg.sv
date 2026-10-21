// ***************
// Filename: feature_detect_regs_pkg.sv
// Author: FPGA Cores 4 U
// Description: Register offsets of feature_detect (byte offsets in its
//   window) and bit fields (<REG>_<FIELD>_LSB / _MASK), for firmware ("from
//   feature_detect_regs_pkg import *" in pyc.py) and testbenches. Generated
//   by ip/scripts/regmap_gen.py from feature_detect_regs.json.
// Date: 2026-10-21
package feature_detect_regs_pkg;
  localparam int FEATURE_DETECT_ID = 'h0;
  localparam int FEATURE_DETECT_VERSION = 'h4;
  localparam int FEATURE_DETECT_DATE = 'h8;
  localparam int FEATURE_DETECT_CTRL = 'h18;
  localparam int FEATURE_DETECT_CTRL_EN_LSB = 0;
  localparam int FEATURE_DETECT_CTRL_EN_MASK = 'h1;
  localparam int FEATURE_DETECT_CTRL_EDGE_EN_LSB = 1;
  localparam int FEATURE_DETECT_CTRL_EDGE_EN_MASK = 'h2;
  localparam int FEATURE_DETECT_CTRL_MOTION_EN_LSB = 2;
  localparam int FEATURE_DETECT_CTRL_MOTION_EN_MASK = 'h4;
  localparam int FEATURE_DETECT_CTRL_AUTO_SHIFT_LSB = 3;
  localparam int FEATURE_DETECT_CTRL_AUTO_SHIFT_MASK = 'h8;
  localparam int FEATURE_DETECT_CTRL_RESTART_LSB = 4;
  localparam int FEATURE_DETECT_CTRL_RESTART_MASK = 'h10;
  localparam int FEATURE_DETECT_FRAME_SIZE = 'h1C;
  localparam int FEATURE_DETECT_FRAME_SIZE_WIDTH_LSB = 0;
  localparam int FEATURE_DETECT_FRAME_SIZE_WIDTH_MASK = 'hFFFF;
  localparam int FEATURE_DETECT_FRAME_SIZE_HEIGHT_LSB = 16;
  localparam int FEATURE_DETECT_FRAME_SIZE_HEIGHT_MASK = 'hFFFF0000;
  localparam int FEATURE_DETECT_EDGE = 'h20;
  localparam int FEATURE_DETECT_EDGE_THRESH_LSB = 0;
  localparam int FEATURE_DETECT_EDGE_THRESH_MASK = 'h7FF;
  localparam int FEATURE_DETECT_EDGE_SPAN_LSB = 16;
  localparam int FEATURE_DETECT_EDGE_SPAN_MASK = 'hF0000;
  localparam int FEATURE_DETECT_MOTION = 'h24;
  localparam int FEATURE_DETECT_MOTION_THRESH_LSB = 0;
  localparam int FEATURE_DETECT_MOTION_THRESH_MASK = 'hFF;
  localparam int FEATURE_DETECT_MOTION_SPAN_LSB = 8;
  localparam int FEATURE_DETECT_MOTION_SPAN_MASK = 'hF00;
  localparam int FEATURE_DETECT_MOTION_RATE_LSB = 12;
  localparam int FEATURE_DETECT_MOTION_RATE_MASK = 'h7000;
  localparam int FEATURE_DETECT_SHIFT = 'h28;
  localparam int FEATURE_DETECT_SHIFT_X_LSB = 0;
  localparam int FEATURE_DETECT_SHIFT_X_MASK = 'hFF;
  localparam int FEATURE_DETECT_SHIFT_Y_LSB = 8;
  localparam int FEATURE_DETECT_SHIFT_Y_MASK = 'hFF00;
  localparam int FEATURE_DETECT_SHIFT_EST = 'h2C;
  localparam int FEATURE_DETECT_SHIFT_EST_X_LSB = 0;
  localparam int FEATURE_DETECT_SHIFT_EST_X_MASK = 'hFF;
  localparam int FEATURE_DETECT_SHIFT_EST_Y_LSB = 8;
  localparam int FEATURE_DETECT_SHIFT_EST_Y_MASK = 'hFF00;
  localparam int FEATURE_DETECT_STATUS = 'h30;
  localparam int FEATURE_DETECT_STATUS_IN_FRAME_LSB = 0;
  localparam int FEATURE_DETECT_STATUS_IN_FRAME_MASK = 'h1;
  localparam int FEATURE_DETECT_STATUS_BG_VALID_LSB = 1;
  localparam int FEATURE_DETECT_STATUS_BG_VALID_MASK = 'h2;
  localparam int FEATURE_DETECT_STATUS_BUSY_LSB = 2;
  localparam int FEATURE_DETECT_STATUS_BUSY_MASK = 'h4;
  localparam int FEATURE_DETECT_STATUS_FRAMES_LSB = 16;
  localparam int FEATURE_DETECT_STATUS_FRAMES_MASK = 'hFFFF0000;
  localparam int FEATURE_DETECT_FRAMES = 'h34;
  localparam int FEATURE_DETECT_EDGE_COUNT = 'h38;
  localparam int FEATURE_DETECT_MOTION_COUNT = 'h3C;
  localparam int FEATURE_DETECT_SHIFT_USED = 'h40;
  localparam int FEATURE_DETECT_SHIFT_USED_X_LSB = 0;
  localparam int FEATURE_DETECT_SHIFT_USED_X_MASK = 'hFF;
  localparam int FEATURE_DETECT_SHIFT_USED_Y_LSB = 8;
  localparam int FEATURE_DETECT_SHIFT_USED_Y_MASK = 'hFF00;
  localparam int FEATURE_DETECT_SKY_CFG = 'h44;
  localparam int FEATURE_DETECT_SKY_CFG_SHIFT_LSB = 0;
  localparam int FEATURE_DETECT_SKY_CFG_SHIFT_MASK = 'hF;
  localparam int FEATURE_DETECT_SKY_CFG_Y_MIN_LSB = 8;
  localparam int FEATURE_DETECT_SKY_CFG_Y_MIN_MASK = 'hFF00;
  localparam int FEATURE_DETECT_SKY = 'h80;
  localparam int FEATURE_DETECT_SKY_STRIDE = 4;
endpackage
