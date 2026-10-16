// ***************
// Filename: video_pipeline_regs_pkg.sv
// Author: FPGA Cores 4 U
// Description: Register offsets of video_pipeline (byte offsets in its
//   window) and bit fields (<REG>_<FIELD>_LSB / _MASK), for firmware ("from
//   video_pipeline_regs_pkg import *" in pyc.py) and testbenches. Generated
//   by ip/scripts/regmap_gen.py from video_pipeline_regs.json.
// Date: 2026-10-16
package video_pipeline_regs_pkg;
  localparam int VIDEO_PIPELINE_ID = 'h0;
  localparam int VIDEO_PIPELINE_VERSION = 'h4;
  localparam int VIDEO_PIPELINE_DATE = 'h8;
  localparam int VIDEO_PIPELINE_CTRL = 'h14;
  localparam int VIDEO_PIPELINE_BYPASS = 'h18;
  localparam int VIDEO_PIPELINE_STATUS = 'h1C;
  localparam int VIDEO_PIPELINE_CSI = 'h20;
  localparam int VIDEO_PIPELINE_FRAME_SIZE = 'h24;
  localparam int VIDEO_PIPELINE_BLC_R = 'h28;
  localparam int VIDEO_PIPELINE_BLC_GR = 'h2C;
  localparam int VIDEO_PIPELINE_BLC_GB = 'h30;
  localparam int VIDEO_PIPELINE_BLC_B = 'h34;
  localparam int VIDEO_PIPELINE_WB_R = 'h38;
  localparam int VIDEO_PIPELINE_WB_G = 'h3C;
  localparam int VIDEO_PIPELINE_WB_B = 'h40;
  localparam int VIDEO_PIPELINE_DPC_THR = 'h44;
  localparam int VIDEO_PIPELINE_CCM_C00 = 'h48;
  localparam int VIDEO_PIPELINE_CCM_C01 = 'h4C;
  localparam int VIDEO_PIPELINE_CCM_C02 = 'h50;
  localparam int VIDEO_PIPELINE_CCM_C10 = 'h54;
  localparam int VIDEO_PIPELINE_CCM_C11 = 'h58;
  localparam int VIDEO_PIPELINE_CCM_C12 = 'h5C;
  localparam int VIDEO_PIPELINE_CCM_C20 = 'h60;
  localparam int VIDEO_PIPELINE_CCM_C21 = 'h64;
  localparam int VIDEO_PIPELINE_CCM_C22 = 'h68;
  localparam int VIDEO_PIPELINE_CCM_OFF_R = 'h6C;
  localparam int VIDEO_PIPELINE_CCM_OFF_G = 'h70;
  localparam int VIDEO_PIPELINE_CCM_OFF_B = 'h74;
  localparam int VIDEO_PIPELINE_GAMMA_ADDR = 'h78;
  localparam int VIDEO_PIPELINE_GAMMA_DATA = 'h7C;
  localparam int VIDEO_PIPELINE_STAT_THR = 'h80;
  localparam int VIDEO_PIPELINE_STAT_SUM_R = 'h84;
  localparam int VIDEO_PIPELINE_STAT_SUM_G = 'h88;
  localparam int VIDEO_PIPELINE_STAT_SUM_B = 'h8C;
  localparam int VIDEO_PIPELINE_STAT_PIX = 'h90;
  localparam int VIDEO_PIPELINE_STAT_CLIP = 'h94;
  localparam int VIDEO_PIPELINE_STAT_FRAMES = 'h98;
  localparam int VIDEO_PIPELINE_H_ACTIVE = 'h9C;
  localparam int VIDEO_PIPELINE_H_FP = 'hA0;
  localparam int VIDEO_PIPELINE_H_SYNC = 'hA4;
  localparam int VIDEO_PIPELINE_H_BP = 'hA8;
  localparam int VIDEO_PIPELINE_V_ACTIVE = 'hAC;
  localparam int VIDEO_PIPELINE_V_FP = 'hB0;
  localparam int VIDEO_PIPELINE_V_SYNC = 'hB4;
  localparam int VIDEO_PIPELINE_V_BP = 'hB8;
  localparam int VIDEO_PIPELINE_SYNC_POL = 'hBC;
  localparam int VIDEO_PIPELINE_LOCK_MAX = 'hC0;
  localparam int VIDEO_PIPELINE_START_LEVEL = 'hC4;
  localparam int VIDEO_PIPELINE_AVI = 'hC8;
  localparam int VIDEO_PIPELINE_CSI_FRAMES = 'hCC;
  localparam int VIDEO_PIPELINE_ECC_CORR = 'hD0;
  localparam int VIDEO_PIPELINE_ECC_ERR = 'hD4;
  localparam int VIDEO_PIPELINE_CRC_ERR = 'hD8;
  localparam int VIDEO_PIPELINE_UNDERFLOWS = 'hDC;
  localparam int VIDEO_PIPELINE_DPC_CORR = 'hE0;
  localparam int VIDEO_PIPELINE_CSI_OVERFLOW = 'hE4;
  localparam int VIDEO_PIPELINE_OUT_CTRL = 'hE8;
  localparam int VIDEO_PIPELINE_DSI_GAPS = 'hEC;
  localparam int VIDEO_PIPELINE_CSITX_GAP = 'hF0;
  localparam int VIDEO_PIPELINE_DSI_CMD = 'hF4;
  localparam int VIDEO_PIPELINE_DSI_CMD_BYTE = 'hF8;
  localparam int VIDEO_PIPELINE_TX_STATUS = 'hFC;
  localparam int VIDEO_PIPELINE_DSI_DROPS = 'h100;
  localparam int VIDEO_PIPELINE_CSITX_DROPS = 'h104;
  localparam int VIDEO_PIPELINE_CSITX_FRAMES = 'h108;
  localparam int VIDEO_PIPELINE_BUILD_CFG = 'h10C;
endpackage
