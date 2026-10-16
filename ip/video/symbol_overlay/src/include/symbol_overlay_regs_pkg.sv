// ***************
// Filename: symbol_overlay_regs_pkg.sv
// Author: FPGA Cores 4 U
// Description: Register offsets of symbol_overlay (byte offsets in its
//   window) and bit fields (<REG>_<FIELD>_LSB / _MASK), for firmware ("from
//   symbol_overlay_regs_pkg import *" in pyc.py) and testbenches. Generated
//   by ip/scripts/regmap_gen.py from symbol_overlay_regs.json.
// Date: 2026-10-16
package symbol_overlay_regs_pkg;
  localparam int SYMBOL_OVERLAY_ID = 'h0;
  localparam int SYMBOL_OVERLAY_VERSION = 'h4;
  localparam int SYMBOL_OVERLAY_DATE = 'h8;
  localparam int SYMBOL_OVERLAY_CTRL = 'h18;
  localparam int SYMBOL_OVERLAY_COMMIT = 'h1C;
  localparam int SYMBOL_OVERLAY_STATUS = 'h20;
  localparam int SYMBOL_OVERLAY_STATUS_PENDING_LSB = 0;
  localparam int SYMBOL_OVERLAY_STATUS_PENDING_MASK = 'h1;
  localparam int SYMBOL_OVERLAY_STATUS_FRAMES_LSB = 16;
  localparam int SYMBOL_OVERLAY_STATUS_FRAMES_MASK = 'hFFFF0000;
  localparam int SYMBOL_OVERLAY_FRAME_NUM = 'h24;
  localparam int SYMBOL_OVERLAY_OBJ_CTRL = 'h50;
  localparam int SYMBOL_OVERLAY_OBJ_CTRL_STRIDE = 16;
  localparam int SYMBOL_OVERLAY_OBJ_CTRL_EN_LSB = 0;
  localparam int SYMBOL_OVERLAY_OBJ_CTRL_EN_MASK = 'h1;
  localparam int SYMBOL_OVERLAY_OBJ_CTRL_SHAPE_LSB = 1;
  localparam int SYMBOL_OVERLAY_OBJ_CTRL_SHAPE_MASK = 'h6;
  localparam int SYMBOL_OVERLAY_OBJ_CTRL_DASHED_LSB = 3;
  localparam int SYMBOL_OVERLAY_OBJ_CTRL_DASHED_MASK = 'h8;
  localparam int SYMBOL_OVERLAY_OBJ_CTRL_BLEND_LSB = 4;
  localparam int SYMBOL_OVERLAY_OBJ_CTRL_BLEND_MASK = 'h10;
  localparam int SYMBOL_OVERLAY_OBJ_CTRL_OVAL_LSB = 5;
  localparam int SYMBOL_OVERLAY_OBJ_CTRL_OVAL_MASK = 'h20;
  localparam int SYMBOL_OVERLAY_OBJ_CTRL_LINE_W_LSB = 8;
  localparam int SYMBOL_OVERLAY_OBJ_CTRL_LINE_W_MASK = 'hF00;
  localparam int SYMBOL_OVERLAY_OBJ_CTRL_DASH_LOG2_LSB = 12;
  localparam int SYMBOL_OVERLAY_OBJ_CTRL_DASH_LOG2_MASK = 'h7000;
  localparam int SYMBOL_OVERLAY_OBJ_X = 'h54;
  localparam int SYMBOL_OVERLAY_OBJ_X_STRIDE = 16;
  localparam int SYMBOL_OVERLAY_OBJ_Y = 'h58;
  localparam int SYMBOL_OVERLAY_OBJ_Y_STRIDE = 16;
  localparam int SYMBOL_OVERLAY_OBJ_COLOR = 'h5C;
  localparam int SYMBOL_OVERLAY_OBJ_COLOR_STRIDE = 16;
  localparam int SYMBOL_OVERLAY_TXT_CTRL = 'h110;
  localparam int SYMBOL_OVERLAY_TXT_CTRL_STRIDE = 16;
  localparam int SYMBOL_OVERLAY_TXT_CTRL_EN_LSB = 0;
  localparam int SYMBOL_OVERLAY_TXT_CTRL_EN_MASK = 'h1;
  localparam int SYMBOL_OVERLAY_TXT_CTRL_SCALE_LSB = 1;
  localparam int SYMBOL_OVERLAY_TXT_CTRL_SCALE_MASK = 'h6;
  localparam int SYMBOL_OVERLAY_TXT_CTRL_BACKDROP_LSB = 3;
  localparam int SYMBOL_OVERLAY_TXT_CTRL_BACKDROP_MASK = 'h8;
  localparam int SYMBOL_OVERLAY_TXT_CTRL_FNUM_LSB = 4;
  localparam int SYMBOL_OVERLAY_TXT_CTRL_FNUM_MASK = 'h10;
  localparam int SYMBOL_OVERLAY_TXT_CTRL_LENGTH_LSB = 8;
  localparam int SYMBOL_OVERLAY_TXT_CTRL_LENGTH_MASK = 'h1F00;
  localparam int SYMBOL_OVERLAY_TXT_POS = 'h114;
  localparam int SYMBOL_OVERLAY_TXT_POS_STRIDE = 16;
  localparam int SYMBOL_OVERLAY_TXT_COLOR = 'h118;
  localparam int SYMBOL_OVERLAY_TXT_COLOR_STRIDE = 16;
  localparam int SYMBOL_OVERLAY_TXT_CHARS = 'h210;
  localparam int SYMBOL_OVERLAY_TXT_CHARS_STRIDE = 4;
endpackage
