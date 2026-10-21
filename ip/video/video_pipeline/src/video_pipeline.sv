// ***************
// Filename: video_pipeline.sv
// Author: FPGA Cores 4 U
// Description: MIPI CSI-2 camera to HDMI / DVI video pipeline. Version 1.1.0.
//
//   byte_clk | pix_clk
//   D-PHY -> csi2_rx -> axis_async_bridge -> csi2_raw_unpack -> isp_blc_wb
//     -> isp_dpc -> isp_demosaic -> isp_ccm -> isp_gamma -> isp_csc
//     -> [scaler_bilinear | bypass] -> axis_to_video -> hdmi_tx  -> TMDS (HDMI / DVI)
//                                                    -> lvds_tx  -> OpenLDI (LVDS panel)
//                                                    -> dsi_tx   -> MIPI DSI (panel)
//                                                    -> csi2_tx  -> MIPI CSI-2 (processor)
//   vid_timing_gen drives axis_to_video (genlock to the camera) and hdmi_tx;
//   isp_stats taps the linear RGB after the CCM for AE / AWB software.
//   isp_dpc follows black level and white balance (Ramanath et al. 2005 place
//   defect correction before white balance), so DPC_THR is in white-balanced
//   units; with unity gains (video_processor) the order makes no difference.
//   eof_in_o / eof_out_o pulse at the end of every frame leaving
//   csi2_raw_unpack (first stage) / entering axis_to_video (last stage),
//   e.g. for a frame counter.
//
//   Every function can be bypassed (BYPASS register, applied at the next
//   frame start): black level, white balance, defect correction, demosaic
//   (raw value on R, G and B), CCM, gamma (linear 10 -> 8 bit), CSC (RGB
//   out), scaler (stream routed around it). CTRL.TPG replaces the whole
//   pipeline output with colour bars.
//
//   The D-PHY analog front end is vendor IP: connect its per-lane HS byte
//   outputs (PPI) to lane_data_i / lane_valid_i. The TMDS symbols leave on
//   tmds*_o for a 10:1 serializer (tmds_serializer or vendor OSERDES) and
//   differential output buffers.
//
//   No frame buffer: the display is genlocked to the camera (CTRL.LOCK), so
//   the display line time must be at least the camera line time; insert an
//   external frame buffer (axis_dma + DRAM) before axis_to_video for
//   independent frame rates.
//
//   AXI4-Lite (pix_clk), ADDR_W = 15 (src/video_pipeline_map_pkg.sv):
//   0x0000-0x01FF pipeline registers (DECERR up to 0x3FFF), 0x4000-0x7FFF the scaler's own map
//   (scaler_ctrl, base 0x4000).
//     0x000 ID          RO "VPIP"; 0x004 VERSION RO ASCII "d.dd"; 0x008 DATE RO BCD
//                       mm/dd/yyyy (the ID block); register k of the old map is at
//                       0x10 + 4 k (src/include/video_pipeline_regs.sv / .json / .md):
//     0x014 CTRL        [0] output enable [1] HDMI (0 = DVI) [2] TPG
//                       [3] genlock [5:4] CFA (0 RGGB 1 GRBG 2 GBRG 3 BGGR)
//                       [6] CSC BT.709 (0 = BT.601)
//                       [7] insert: route the stream after isp_csc out
//                       through ins_m_axis_* and back in on ins_s_axis_*
//                       (`VP_INSERT; taken at the next frame start)
//     0x018 BYPASS      [0] BLC [1] WB [2] DPC [3] demosaic [4] CCM [5] gamma
//                       [6] CSC [7] scaler          (reset 0xC0: RGB out, no scaler)
//     0x01C STATUS      RO [0] output locked to the camera
//     0x020 CSI         [5:0] data type (reset 0x2B RAW10) [7:6] virtual channel
//     0x024 FRAME_SIZE  [15:0] camera width [31:16] height
//     0x028-0x034 BLC   R, Gr, Gb, B black levels
//     0x038-0x040 WB    R, G, B gains Q4.8 (reset 0x100)
//     0x044 DPC_THR     defect threshold (reset 64)
//     0x048-0x068 CCM   coefficients c00..c22, signed Q5.10 (reset identity)
//     0x06C-0x074 CCM   offsets R, G, B (signed)
//     0x078 GAMMA_ADDR  table index for the next GAMMA_DATA write
//     0x07C GAMMA_DATA  [7:0] writes table[index], index auto-increments
//     0x080 STAT_THR    clip threshold (10-bit, reset 1000)
//     0x084-0x08C STAT  RO sums of R, G, B (low 32 bits) of the last frame
//     0x090 STAT_PIX    RO pixels, 0x094 STAT_CLIP RO clipped pixels
//     0x098 STAT_FRAMES RO
//     0x09C-0x0B8 VTG   h active, h front porch, h sync, h back porch,
//                       v active, v front porch, v sync, v back porch
//     0x0BC SYNC_POL    [0] hsync [1] vsync active high
//     0x0C0 LOCK_MAX    genlock: max extra blanking lines (reset 1023)
//     0x0C4 START_LEVEL pixels buffered before a frame starts (reset 16)
//     0x0C8 AVI         [6:0] VIC [9:8] picture aspect [11:10] RGB range
//                       (colour space and colorimetry follow CSC settings)
//     0x0CC CSI_FRAMES  RO, 0x0D0 ECC_CORR RO, 0x0D4 ECC_ERR RO,
//     0x0D8 CRC_ERR RO, 0x0DC UNDERFLOWS RO, 0x0E0 DPC_CORR RO,
//     0x0E4 CSI_OVERFLOW RO (CSI overflow events: the bridge FIFO was full)
//     0x0E8 OUT_CTRL    [0] LVDS dual link [1] LVDS 18 bpp [2] LVDS JEIDA
//                       [4] DSI video [5] DSI EoTp [7:6] DSI virtual channel
//                       [8] CSI-2 TX enable [9] CSI-2 TX YUV422 [11:10] its VC
//     0x0EC DSI_GAPS    [15:0] LP clocks after a sync packet, [31:16] after pixels
//     0x0F0 CSITX_GAP   LP clocks between CSI-2 TX packets
//     0x0F4 DSI_CMD     write: queue a DSI command {[24] long, [23:16] data
//                       type, [15:0] data / word count} (sent with DSI video off)
//     0x0F8 DSI_CMD_BYTE write: [7:0] next payload byte of a long command
//     0x0FC TX_STATUS   RO [0] DSI command queue busy
//     0x100 DSI_DROPS   RO lines DSI could not send in time (dropped, or a
//                       burst that ran dry)
//     0x104 CSITX_DROPS RO lines CSI-2 TX could not send in time (as DSI)
//     0x108 CSITX_FRAMES RO frames sent by CSI-2 TX
//   The DSI, CSI-2 TX and LVDS outputs carry the same timed video as HDMI;
//   panels need RGB (CSC bypassed), CSI-2 YUV422 needs YCbCr (CSC on).
//   Scaler settings: clear its CTRL.ENABLE, wait for STATUS.BUSY = 0, then
//   change sizes / steps and enable it again (scaler_ctrl does not support
//   changing them while a frame is being generated).
//     0x10C BUILD_CFG   RO interfaces built: [0] CSI-2 RX [1] HDMI [2] LVDS
//                       [3] DSI [4] CSI-2 TX [5] scaler [6] insert point
//   External interfaces are included or excluded with the `defines in
//   configuration.sv (compiled first, see scripts/build.f); an excluded
//   interface has no ports or logic and its registers read as 0.
//   Clocks - byte_clk (D-PHY), pix_clk (pipeline, registers, video out).
//   Resets - byte_rst_n, pix_rst_n, synchronous active low; assert both.
// Date: 2026-10-21
module video_pipeline #(
  parameter int NLANES     = 2,
  parameter int MAX_W      = 2048,               // longest camera / output line
  parameter int CSI_FIFO   = 2048,               // byte-clock to pixel-clock FIFO, words
  parameter int OUT_FIFO   = 2048,               // output pixel FIFO
  parameter bit SCALER     = 1,                  // include scaler_bilinear
  /* verilator lint_off UNUSEDPARAM */            // used when the DSI / CSI-2 TX outputs are built
  parameter int DSI_LANES  = 2,                  // MIPI DSI output lanes (1, 2, 4)
  parameter int CSITX_LANES = 2                  // MIPI CSI-2 output lanes (1, 2, 4)
  /* verilator lint_on UNUSEDPARAM */
) (
  // byte_rst_n / pix_rst_n reset the logic synchronously; axis_async_bridge's reset synchronisers also
  // take them asynchronously (asynchronous assertion, synchronous release)
  /* verilator lint_off SYNCASYNCNET */
`ifdef VP_CSI2_RX
  // MIPI CSI-2 camera input (D-PHY RX, PPI)
  input  logic                byte_clk,
  input  logic                byte_rst_n,
  input  logic [NLANES*8-1:0] lane_data_i,
  input  logic [NLANES-1:0]   lane_valid_i,
`endif
  input  logic                pix_clk,
  input  logic                pix_rst_n,
  /* verilator lint_on SYNCASYNCNET */
  // AXI4-Lite slave (pix_clk)
  // s_axil: axil_if.slave (ip/shared/src/interfaces/axil_if.sv), ADDR_W = 15
  axil_if.slave s_axil,
  // Video out
`ifdef VP_HDMI
  output logic [9:0]          tmds0_o,
  output logic [9:0]          tmds1_o,
  output logic [9:0]          tmds2_o,
  output logic [9:0]          tmds_clk_o,
`endif
  // LVDS (OpenLDI 7:1) words for lvds_serializer: lanes 0-3 of links A / B
`ifdef VP_LVDS
  output logic [27:0]         lvds_a_o,
  output logic [27:0]         lvds_b_o,
  output logic [6:0]          lvds_clk_word_o,
  output logic                lvds_stb_o,
`endif
  // MIPI transmit D-PHYs (PPI style, see mipi_tx_engine), both on tx_byte_clk
`ifdef VP_MIPI_TX
  input  logic                tx_byte_clk,
  input  logic                tx_byte_rst_n,
`endif
`ifdef VP_DSI
  output logic [DSI_LANES*8-1:0]   dsi_lane_data_o,
  output logic [DSI_LANES-1:0]     dsi_lane_valid_o,
  output logic                dsi_hs_req_o,
  input  logic                dsi_tx_ready_i,
`endif
`ifdef VP_CSI2_TX
  output logic [CSITX_LANES*8-1:0] csitx_lane_data_o,
  output logic [CSITX_LANES-1:0]   csitx_lane_valid_o,
  output logic                csitx_hs_req_o,
  input  logic                csitx_tx_ready_i,
`endif
`ifdef VP_INSERT
  // Insert point after isp_csc (CTRL[7]): 24-bit AXI4-Stream video out to an
  // external block (e.g. vision_system) and back; tuser = SOF, tlast = EOL
  // ins_m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = 24
  axis_if.master ins_m_axis,
  // ins_s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = 24
  axis_if.slave ins_s_axis,
`endif
  // End-of-frame markers (pix_clk pulses, e.g. for a frame counter): the last pixel of a frame
  // leaving csi2_raw_unpack (first ISP stage, FRAME_SIZE height) / entering axis_to_video (last
  // stream stage, VTG v active height)
  output logic                eof_in_o,
  output logic                eof_out_o,
  output logic                stats_done_o       // pulse: new statistics available
);
`ifdef VP_INSERT
  assign ins_m_axis.tkeep = '1;      // not used by this block
`endif
`ifndef VP_CONFIGURATION_SV
  if (1) begin : g_no_config $error("video_pipeline: compile src/configuration.sv first (see scripts/build.f)"); end
`endif
  localparam int RW = 10;                        // RAW / linear RGB width
  // Interfaces built (configuration.sv)
`ifdef VP_CSI2_RX
  localparam bit BUILD_CSI2_RX = 1'b1;
`else
  localparam bit BUILD_CSI2_RX = 1'b0;
`endif
`ifdef VP_HDMI
  localparam bit BUILD_HDMI = 1'b1;
`else
  localparam bit BUILD_HDMI = 1'b0;
`endif
`ifdef VP_LVDS
  localparam bit BUILD_LVDS = 1'b1;
`else
  localparam bit BUILD_LVDS = 1'b0;
`endif
`ifdef VP_DSI
  localparam bit BUILD_DSI = 1'b1;
`else
  localparam bit BUILD_DSI = 1'b0;
`endif
`ifdef VP_CSI2_TX
  localparam bit BUILD_CSI2_TX = 1'b1;
`else
  localparam bit BUILD_CSI2_TX = 1'b0;
`endif
`ifdef VP_INSERT
  localparam bit BUILD_INSERT = 1'b1;
`else
  localparam bit BUILD_INSERT = 1'b0;
`endif
  wire clk = pix_clk, rst_n = pix_rst_n;

  // ================================================================ registers
  logic [29:0] sp_awaddr, sp_araddr;
  logic [1:0] sp_awvalid, sp_awready, sp_wvalid, sp_wready, sp_bvalid, sp_bready;
  logic [1:0] sp_arvalid, sp_arready, sp_rvalid, sp_rready;
  logic [63:0] sp_wdata, sp_rdata;
  logic [7:0] sp_wstrb;
  logic [3:0] sp_bresp, sp_rresp;
  axil_split #(                                   // video_pipeline_map_pkg: registers / scaler
    .ADDR_W(video_pipeline_map_pkg::ADDR_W),
    .SEL_BIT(video_pipeline_map_pkg::SPLIT_BIT)
  ) u_split (
    .clk,
    .rst_n,
    .s_awaddr(s_axil.awaddr[video_pipeline_map_pkg::ADDR_W-1:0]),
    .s_awvalid(s_axil.awvalid),
    .s_awready(s_axil.awready),
    .s_wdata(s_axil.wdata),
    .s_wstrb(s_axil.wstrb),
    .s_wvalid(s_axil.wvalid),
    .s_wready(s_axil.wready),
    .s_bresp(s_axil.bresp),
    .s_bvalid(s_axil.bvalid),
    .s_bready(s_axil.bready),
    .s_araddr(s_axil.araddr[video_pipeline_map_pkg::ADDR_W-1:0]),
    .s_arvalid(s_axil.arvalid),
    .s_arready(s_axil.arready),
    .s_rdata(s_axil.rdata),
    .s_rresp(s_axil.rresp),
    .s_rvalid(s_axil.rvalid),
    .s_rready(s_axil.rready),
    .m_awaddr(sp_awaddr),
    .m_awvalid(sp_awvalid),
    .m_awready(sp_awready),
    .m_wdata(sp_wdata),
    .m_wstrb(sp_wstrb),
    .m_wvalid(sp_wvalid),
    .m_wready(sp_wready),
    .m_bresp(sp_bresp),
    .m_bvalid(sp_bvalid),
    .m_bready(sp_bready),
    .m_araddr(sp_araddr),
    .m_arvalid(sp_arvalid),
    .m_arready(sp_arready),
    .m_rdata(sp_rdata),
    .m_rresp(sp_rresp),
    .m_rvalid(sp_rvalid),
    .m_rready(sp_rready)
  );

  // ---------------- registers (src/include/video_pipeline_regs.sv, generated from its JSON):
  // ID "VPIP" / VERSION / DATE at 0x00-0x08, register k of the map at 0x10 + 4 k (k = 1..63);
  // regs / rd keep that indexing (regs[k*32 +: 32]: value written, rd[k*32 +: 32]: value read)
  localparam int NREG = 64;
  logic [NREG*32-1:0] regs, rd;
  logic [31:0] gamma_data_d, dsi_cmd_d, dsi_cmd_byte_d;
  logic        gamma_addr_wr, gamma_data_wr, dsi_cmd_wr, dsi_cmd_byte_wr;
  assign regs[0 +: 32] = '0;
  // read-only registers have no written value
  assign regs[3*32 +: 32] = '0;
  assign regs[29*32 +: 32] = '0;
  assign regs[30*32 +: 32] = '0;
  assign regs[31*32 +: 32] = '0;
  assign regs[32*32 +: 32] = '0;
  assign regs[33*32 +: 32] = '0;
  assign regs[34*32 +: 32] = '0;
  assign regs[47*32 +: 32] = '0;
  assign regs[48*32 +: 32] = '0;
  assign regs[49*32 +: 32] = '0;
  assign regs[50*32 +: 32] = '0;
  assign regs[51*32 +: 32] = '0;
  assign regs[52*32 +: 32] = '0;
  assign regs[53*32 +: 32] = '0;
  assign regs[59*32 +: 32] = '0;
  assign regs[60*32 +: 32] = '0;
  assign regs[61*32 +: 32] = '0;
  assign regs[62*32 +: 32] = '0;
  assign regs[63*32 +: 32] = '0;
  assign regs[27*32 +: 32] = gamma_data_d;
  assign regs[57*32 +: 32] = dsi_cmd_d;
  assign regs[58*32 +: 32] = dsi_cmd_byte_d;
  axil_if #(.ADDR_W(14)) u_regs_s_axil ();       // the whole 16 KB window: DECERR above the map
  assign u_regs_s_axil.awaddr = sp_awaddr[13:0];
  assign u_regs_s_axil.awvalid = sp_awvalid[0];
  assign sp_awready[0] = u_regs_s_axil.awready;
  assign u_regs_s_axil.wdata = sp_wdata[31:0];
  assign u_regs_s_axil.wstrb = sp_wstrb[3:0];
  assign u_regs_s_axil.wvalid = sp_wvalid[0];
  assign sp_wready[0] = u_regs_s_axil.wready;
  assign sp_bresp[1:0] = u_regs_s_axil.bresp;
  assign sp_bvalid[0] = u_regs_s_axil.bvalid;
  assign u_regs_s_axil.bready = sp_bready[0];
  assign u_regs_s_axil.araddr = sp_araddr[13:0];
  assign u_regs_s_axil.arvalid = sp_arvalid[0];
  assign sp_arready[0] = u_regs_s_axil.arready;
  assign sp_rdata[31:0] = u_regs_s_axil.rdata;
  assign sp_rresp[1:0] = u_regs_s_axil.rresp;
  assign sp_rvalid[0] = u_regs_s_axil.rvalid;
  assign u_regs_s_axil.rready = sp_rready[0];
  video_pipeline_regs_if u_regs_r ();
  assign regs[1*32 +: 32] = u_regs_r.cfg_ctrl;
  assign regs[2*32 +: 32] = u_regs_r.cfg_bypass;
  assign u_regs_r.sts_status = rd[3*32 +: 32];
  assign regs[4*32 +: 32] = u_regs_r.cfg_csi;
  assign regs[5*32 +: 32] = u_regs_r.cfg_frame_size;
  assign regs[6*32 +: 32] = u_regs_r.cfg_blc_r;
  assign regs[7*32 +: 32] = u_regs_r.cfg_blc_gr;
  assign regs[8*32 +: 32] = u_regs_r.cfg_blc_gb;
  assign regs[9*32 +: 32] = u_regs_r.cfg_blc_b;
  assign regs[10*32 +: 32] = u_regs_r.cfg_wb_r;
  assign regs[11*32 +: 32] = u_regs_r.cfg_wb_g;
  assign regs[12*32 +: 32] = u_regs_r.cfg_wb_b;
  assign regs[13*32 +: 32] = u_regs_r.cfg_dpc_thr;
  assign regs[14*32 +: 32] = u_regs_r.cfg_ccm_c00;
  assign regs[15*32 +: 32] = u_regs_r.cfg_ccm_c01;
  assign regs[16*32 +: 32] = u_regs_r.cfg_ccm_c02;
  assign regs[17*32 +: 32] = u_regs_r.cfg_ccm_c10;
  assign regs[18*32 +: 32] = u_regs_r.cfg_ccm_c11;
  assign regs[19*32 +: 32] = u_regs_r.cfg_ccm_c12;
  assign regs[20*32 +: 32] = u_regs_r.cfg_ccm_c20;
  assign regs[21*32 +: 32] = u_regs_r.cfg_ccm_c21;
  assign regs[22*32 +: 32] = u_regs_r.cfg_ccm_c22;
  assign regs[23*32 +: 32] = u_regs_r.cfg_ccm_off_r;
  assign regs[24*32 +: 32] = u_regs_r.cfg_ccm_off_g;
  assign regs[25*32 +: 32] = u_regs_r.cfg_ccm_off_b;
  assign regs[26*32 +: 32] = u_regs_r.cfg_gamma_addr;
  assign gamma_addr_wr = u_regs_r.cfg_gamma_addr_wr;
  assign gamma_data_d = u_regs_r.cfg_gamma_data;
  assign gamma_data_wr = u_regs_r.cfg_gamma_data_wr;
  assign regs[28*32 +: 32] = u_regs_r.cfg_stat_thr;
  assign u_regs_r.sts_stat_sum_r = rd[29*32 +: 32];
  assign u_regs_r.sts_stat_sum_g = rd[30*32 +: 32];
  assign u_regs_r.sts_stat_sum_b = rd[31*32 +: 32];
  assign u_regs_r.sts_stat_pix = rd[32*32 +: 32];
  assign u_regs_r.sts_stat_clip = rd[33*32 +: 32];
  assign u_regs_r.sts_stat_frames = rd[34*32 +: 32];
  assign regs[35*32 +: 32] = u_regs_r.cfg_h_active;
  assign regs[36*32 +: 32] = u_regs_r.cfg_h_fp;
  assign regs[37*32 +: 32] = u_regs_r.cfg_h_sync;
  assign regs[38*32 +: 32] = u_regs_r.cfg_h_bp;
  assign regs[39*32 +: 32] = u_regs_r.cfg_v_active;
  assign regs[40*32 +: 32] = u_regs_r.cfg_v_fp;
  assign regs[41*32 +: 32] = u_regs_r.cfg_v_sync;
  assign regs[42*32 +: 32] = u_regs_r.cfg_v_bp;
  assign regs[43*32 +: 32] = u_regs_r.cfg_sync_pol;
  assign regs[44*32 +: 32] = u_regs_r.cfg_lock_max;
  assign regs[45*32 +: 32] = u_regs_r.cfg_start_level;
  assign regs[46*32 +: 32] = u_regs_r.cfg_avi;
  assign u_regs_r.sts_csi_frames = rd[47*32 +: 32];
  assign u_regs_r.sts_ecc_corr = rd[48*32 +: 32];
  assign u_regs_r.sts_ecc_err = rd[49*32 +: 32];
  assign u_regs_r.sts_crc_err = rd[50*32 +: 32];
  assign u_regs_r.sts_underflows = rd[51*32 +: 32];
  assign u_regs_r.sts_dpc_corr = rd[52*32 +: 32];
  assign u_regs_r.sts_csi_overflow = rd[53*32 +: 32];
  assign regs[54*32 +: 32] = u_regs_r.cfg_out_ctrl;
  assign regs[55*32 +: 32] = u_regs_r.cfg_dsi_gaps;
  assign regs[56*32 +: 32] = u_regs_r.cfg_csitx_gap;
  assign dsi_cmd_d = u_regs_r.cfg_dsi_cmd;
  assign dsi_cmd_wr = u_regs_r.cfg_dsi_cmd_wr;
  assign dsi_cmd_byte_d = u_regs_r.cfg_dsi_cmd_byte;
  assign dsi_cmd_byte_wr = u_regs_r.cfg_dsi_cmd_byte_wr;
  assign u_regs_r.sts_tx_status = rd[59*32 +: 32];
  assign u_regs_r.sts_dsi_drops = rd[60*32 +: 32];
  assign u_regs_r.sts_csitx_drops = rd[61*32 +: 32];
  assign u_regs_r.sts_csitx_frames = rd[62*32 +: 32];
  assign u_regs_r.sts_build_cfg = rd[63*32 +: 32];
  // not used: the write pulses of the registers that act by value
  wire unused_wr = &{1'b0, u_regs_r.cfg_avi_wr, u_regs_r.cfg_blc_b_wr, u_regs_r.cfg_blc_gb_wr, u_regs_r.cfg_blc_gr_wr,
                     u_regs_r.cfg_blc_r_wr, u_regs_r.cfg_bypass_wr, u_regs_r.cfg_ccm_c00_wr, u_regs_r.cfg_ccm_c01_wr,
                     u_regs_r.cfg_ccm_c02_wr, u_regs_r.cfg_ccm_c10_wr, u_regs_r.cfg_ccm_c11_wr,
                     u_regs_r.cfg_ccm_c12_wr, u_regs_r.cfg_ccm_c20_wr, u_regs_r.cfg_ccm_c21_wr,
                     u_regs_r.cfg_ccm_c22_wr, u_regs_r.cfg_ccm_off_b_wr, u_regs_r.cfg_ccm_off_g_wr,
                     u_regs_r.cfg_ccm_off_r_wr, u_regs_r.cfg_csi_wr, u_regs_r.cfg_csitx_gap_wr, u_regs_r.cfg_ctrl_wr,
                     u_regs_r.cfg_dpc_thr_wr, u_regs_r.cfg_dsi_gaps_wr, u_regs_r.cfg_frame_size_wr,
                     u_regs_r.cfg_h_active_wr, u_regs_r.cfg_h_bp_wr, u_regs_r.cfg_h_fp_wr, u_regs_r.cfg_h_sync_wr,
                     u_regs_r.cfg_lock_max_wr, u_regs_r.cfg_out_ctrl_wr, u_regs_r.cfg_start_level_wr,
                     u_regs_r.cfg_stat_thr_wr, u_regs_r.cfg_sync_pol_wr, u_regs_r.cfg_v_active_wr,
                     u_regs_r.cfg_v_bp_wr, u_regs_r.cfg_v_fp_wr, u_regs_r.cfg_v_sync_wr, u_regs_r.cfg_wb_b_wr,
                     u_regs_r.cfg_wb_g_wr, u_regs_r.cfg_wb_r_wr, 1'b0};
  video_pipeline_regs u_regs (
    .clk(clk),
    .rst_n(rst_n),
    .s_axil(u_regs_s_axil),
    .r(u_regs_r)
  );

  wire        out_en  = regs[1*32 + 0], hdmi_mode = regs[1*32 + 1], tpg = regs[1*32 + 2], lock_en = regs[1*32 + 3];
  wire [1:0]  cfa     = regs[1*32 + 4 +: 2];
  wire        bt709   = regs[1*32 + 6];
  wire [7:0]  byp     = regs[2*32 +: 8];
  wire [15:0] fw = regs[5*32 +: 16], fh = regs[5*32 + 16 +: 16];

  // ================================================================ CSI-2 (byte clock)
  axis_if #(.DATA_W(NLANES*8), .USER_W(1), .KEEP_W(NLANES)) b ();
  logic p_fs, p_corr, p_err, p_crc, p_ovf;
`ifdef VP_CSI2_RX
  // Data type / VC are quasi-static: change them only while the camera is stopped
  (* async_reg = "true" *) logic [7:0] csi_cfg_s1, csi_cfg_s2;
  always_ff @(posedge byte_clk) begin
    csi_cfg_s1 <= regs[4*32 +: 8];
    csi_cfg_s2 <= csi_cfg_s1;
  end
  axis_if #(.DATA_W(NLANES*8), .USER_W(1), .KEEP_W(NLANES)) c ();
  logic e_fs, e_fe, e_line, e_corr, e_err, e_crc, e_ovf;
  ppi_rx_if #(.NLANES(NLANES)) u_csi_ppi ();
  assign u_csi_ppi.lane_data = lane_data_i;
  assign u_csi_ppi.lane_valid = lane_valid_i;
  csi2_rx #(.NLANES(NLANES)) u_csi (
    .clk(byte_clk),
    .rst_n(byte_rst_n),
    .ppi(u_csi_ppi),
    .vc_i(csi_cfg_s2[7:6]),
    .dt_i(csi_cfg_s2[5:0]),
    .m_axis(c),
    .frame_start_o(e_fs),
    .frame_end_o(e_fe),
    .line_o(e_line),
    .ecc_corrected_o(e_corr),
    .ecc_error_o(e_err),
    .crc_error_o(e_crc),
    .overflow_o(e_ovf)
  );

  axis_async_bridge #(
    .DATA_W(NLANES*8),
    .DEPTH(CSI_FIFO),
    .USER_W(1)
  ) u_cdc (
    .s_clk(byte_clk),
    .s_rst_n(byte_rst_n),
    .s_axis(c),
    .m_clk(clk),
    .m_rst_n(rst_n),
    .m_axis(b)
  );

  // Status events into the pixel domain. A pulse closer than the synchroniser's round trip to the one
  // before is dropped (drop_o): the counters count events, e.g. CSI_OVERFLOW the overflow bursts the
  // synchroniser passes, not every word lost. Not used: the synchronisers' status, csi2_rx's frame-end
  // and line pulses.
  logic [4:0] ps_busy, ps_drop;
  wire unused_csi = &{1'b0, ps_busy, ps_drop, e_fe, e_line, 1'b0};
  pulse_sync u_ps_fs   (
    .src_clk(byte_clk),
    .src_rst_n(byte_rst_n),
    .pulse_i(e_fs),
    .busy_o(ps_busy[0]),
    .drop_o(ps_drop[0]),
    .dst_clk(clk),
    .dst_rst_n(rst_n),
    .pulse_o(p_fs)
  );
  pulse_sync u_ps_corr (
    .src_clk(byte_clk),
    .src_rst_n(byte_rst_n),
    .pulse_i(e_corr),
    .busy_o(ps_busy[1]),
    .drop_o(ps_drop[1]),
    .dst_clk(clk),
    .dst_rst_n(rst_n),
    .pulse_o(p_corr)
  );
  pulse_sync u_ps_err  (
    .src_clk(byte_clk),
    .src_rst_n(byte_rst_n),
    .pulse_i(e_err),
    .busy_o(ps_busy[2]),
    .drop_o(ps_drop[2]),
    .dst_clk(clk),
    .dst_rst_n(rst_n),
    .pulse_o(p_err)
  );
  pulse_sync u_ps_crc  (
    .src_clk(byte_clk),
    .src_rst_n(byte_rst_n),
    .pulse_i(e_crc),
    .busy_o(ps_busy[3]),
    .drop_o(ps_drop[3]),
    .dst_clk(clk),
    .dst_rst_n(rst_n),
    .pulse_o(p_crc)
  );
  pulse_sync u_ps_ovf  (
    .src_clk(byte_clk),
    .src_rst_n(byte_rst_n),
    .pulse_i(e_ovf),
    .busy_o(ps_busy[4]),
    .drop_o(ps_drop[4]),
    .dst_clk(clk),
    .dst_rst_n(rst_n),
    .pulse_o(p_ovf)
  );
`else
  // No camera: the ISP input stays idle
  assign b.tdata = '0;
  assign b.tkeep = '0;
  assign b.tlast = 1'b0;
  assign b.tuser = 1'b0;
  assign b.tvalid = 1'b0;
  assign p_fs = 1'b0;
  assign p_corr = 1'b0;
  assign p_err = 1'b0;
  assign p_crc = 1'b0;
  assign p_ovf = 1'b0;
`endif

  // ================================================================ ISP (pixel clock)
  axis_if #(.DATA_W(RW), .USER_W(1)) u ();
  csi2_raw_unpack #(
    .IN_BYTES(NLANES),
    .OUT_W(RW)
  ) u_unpack (
    .clk,
    .rst_n,
    .fmt_i(regs[4*32 +: 6]),
    .s_axis(b),
    .m_axis(u)
  );

  axis_if #(.DATA_W(RW), .USER_W(1)) g ();
  isp_blc_wb #(.PW(RW)) u_blc_wb (
    .clk,
    .rst_n,
    .cfa_i(cfa),
    .blc_bypass_i(byp[0]),
    .wb_bypass_i(byp[1]),
    .blc_i({regs[9*32 +: RW], regs[8*32 +: RW], regs[7*32 +: RW], regs[6*32 +: RW]}),
    .gain_r_i(regs[10*32 +: 12]),
    .gain_g_i(regs[11*32 +: 12]),
    .gain_b_i(regs[12*32 +: 12]),
    .s_axis(u),
    .m_axis(g)
  );

  axis_if #(.DATA_W(RW), .USER_W(1)) p ();
  logic dpc_corr;
  isp_dpc #(
    .PW(RW),
    .MAX_W(MAX_W)
  ) u_dpc (
    .clk,
    .rst_n,
    .width_i(fw),
    .height_i(fh),
    .bypass_i(byp[2]),
    .thr_i(regs[13*32 +: RW]),
    .corrected_o(dpc_corr),
    .s_axis(g),
    .m_axis(p)
  );

  axis_if #(.DATA_W(3*RW), .USER_W(1)) d ();
  isp_demosaic #(
    .PW(RW),
    .MAX_W(MAX_W)
  ) u_demosaic (
    .clk,
    .rst_n,
    .width_i(fw),
    .height_i(fh),
    .cfa_i(cfa),
    .bypass_i(byp[3]),
    .s_axis(p),
    .m_axis(d)
  );

  axis_if #(.DATA_W(3*RW), .USER_W(1)) m ();
  logic [9*16-1:0] coef;
  logic [3*16-1:0] offs;
  always_comb begin
    for (int i = 0; i < 9; i++) coef[i*16 +: 16] = regs[(14 + i)*32 +: 16];
    for (int i = 0; i < 3; i++) offs[i*16 +: 16] = regs[(23 + i)*32 +: 16];
  end
  isp_ccm #(.PW(RW)) u_ccm (
    .clk,
    .rst_n,
    .bypass_i(byp[4]),
    .coef_i(coef),
    .off_i(offs),
    .s_axis(d),
    .m_axis(m)
  );

  // Statistics on linear RGB (after the CCM)
  logic [39:0] st_r, st_g, st_b;
  logic [31:0] st_pix, st_clip, st_frames;
  isp_stats #(.CW(RW)) u_stats (
    .clk,
    .rst_n,
    .sat_thr_i(regs[28*32 +: RW]),
    .flush_i(1'b0),
    .tdata(m.tdata),
    .tuser(m.tuser),
    .tvalid(m.tvalid),
    .tready(m.tready),
    .sum_r_o(st_r),
    .sum_g_o(st_g),
    .sum_b_o(st_b),
    .pixels_o(st_pix),
    .clipped_o(st_clip),
    .frames_o(st_frames),
    .frame_done_o(stats_done_o)
  );

  // Gamma table write port: GAMMA_ADDR sets the index, GAMMA_DATA writes and increments
  logic [RW-1:0] gidx;
  logic g_we;
  logic [RW-1:0] g_wa;
  logic [7:0] g_wd;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      gidx <= '0;
      g_we <= 1'b0;
      g_wa <= '0;
      g_wd <= '0;
    end
    else begin
      g_we <= gamma_data_wr;
      if (gamma_addr_wr) gidx <= regs[26*32 +: RW];
      if (gamma_data_wr) begin
        g_wa <= gidx;
        g_wd <= gamma_data_d[7:0];
        gidx <= gidx + 1'b1;
      end
    end
  end
  axis_if #(.DATA_W(24), .USER_W(1)) gm ();
  isp_gamma #(
    .IN_W(RW),
    .OUT_W(8)
  ) u_gamma (
    .clk,
    .rst_n,
    .bypass_i(byp[5]),
    .lut_we_i(g_we),
    .lut_addr_i(g_wa),
    .lut_data_i(g_wd),
    .s_axis(m),
    .m_axis(gm)
  );

  logic [23:0] cq_d;
  logic cq_l, cq_u, cq_v, cq_r;
  axis_if #(.DATA_W(24)) u_csc_m_axis ();
  assign cq_d = u_csc_m_axis.tdata;
  assign cq_l = u_csc_m_axis.tlast;
  assign cq_u = u_csc_m_axis.tuser;
  assign cq_v = u_csc_m_axis.tvalid;
  assign u_csc_m_axis.tready = cq_r;
  isp_csc u_csc (
    .clk,
    .rst_n,
    .bypass_i(byp[6]),
    .bt709_i(bt709),
    .s_axis(gm),
    .m_axis(u_csc_m_axis)
  );

  // ================================================================ insert point (`VP_INSERT)
  // The route is chosen when a frame's SOF pixel is presented (CTRL[7] is
  // sampled only while no SOF is waiting, so it cannot change under it):
  //   insert - the frame goes out on ins_m_axis_*, and from then on the
  //            stream towards the scaler / output comes from ins_s_axis_*;
  //   direct - the frame goes straight on. Returned frames still in flight
  //            when the insert is switched off are drained.
  logic [23:0] cs_d;
  logic cs_l, cs_u, cs_v, cs_r;
  logic [23:0] ir_d;
  logic ir_l, ir_u, ir_v, ir_r, im_r;
  logic ins_en_s, ins_mode;
`ifdef VP_INSERT
  assign ins_m_axis.tdata = cq_d;
  assign ins_m_axis.tlast = cq_l;
  assign ins_m_axis.tuser = cq_u;
  assign im_r = ins_m_axis.tready;
  assign ir_d = ins_s_axis.tdata;
  assign ir_l = ins_s_axis.tlast;
  assign ir_u = ins_s_axis.tuser;
  assign ir_v = ins_s_axis.tvalid;
  assign ins_s_axis.tready = ir_r;
  wire ins_en = regs[1*32 + 7];
`else
  assign im_r = 1'b0;
  assign ir_d = '0;
  assign ir_l = 1'b0;
  assign ir_u = 1'b0;
  assign ir_v = 1'b0;
  wire ins_en = 1'b0;
`endif
  wire cq_sof     = cq_v && cq_u;
  wire ins_sel    = cq_sof ? ins_en_s : ins_mode;          // route of the beat presented by isp_csc
  wire ret_direct = !ins_mode || (cq_sof && !ins_sel);     // the stream on comes from isp_csc
`ifdef VP_INSERT
  assign ins_m_axis.tvalid = cq_v && ins_sel;
`endif
  assign cs_v = ret_direct ? (cq_v && !ins_sel) : ir_v;
  assign cs_d = ret_direct ? cq_d : ir_d;
  assign cs_l = ret_direct ? cq_l : ir_l;
  assign cs_u = ret_direct ? cq_u : ir_u;
  assign cq_r = ins_sel ? im_r : (ret_direct && cs_r);
  assign ir_r = ret_direct ? 1'b1 : cs_r;                  // drain returns that are no longer wanted
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ins_en_s <= 1'b0;
      ins_mode <= 1'b0;
    end
    else begin
      if (!cq_sof) ins_en_s <= ins_en;
      if (cq_sof && cq_r) ins_mode <= ins_sel;
    end
  end

  // ================================================================ scaler or bypass
  // Each frame is routed when its SOF pixel is presented: the route is
  // queued first (one stall cycle), so the output side takes the frames
  // back in order. Frame ends on the output side:
  //   bypass - when the next frame's SOF is presented at the input (the
  //            path has no buffer, so every pixel of the frame has passed);
  //   scaler - after V_ACTIVE lines (the display size), or early when the
  //            scaler starts another frame, or after 65536 idle clocks
  //            (a frame the scaler can no longer finish).
  // Scaler output that belongs to no queued frame is drained, so switching
  // the scaler in or out of the path (BYPASS[7]) recovers by itself.
  logic [23:0] o_d;
  logic o_l, o_u, o_v, o_r;
  logic [3:0] rq; // route queue, entry 0 first: 1 = scaler
  logic [2:0] rq_n;
  logic sof_pushed, sof_route, in_route;
  wire  new_route = SCALER ? !byp[7] : 1'b0;
  wire  at_sof    = cs_v && cs_u;
  wire  push      = at_sof && !sof_pushed && rq_n != 3'd4;
  wire  route_now = at_sof ? sof_route : in_route;
  wire  in_block  = at_sof && !sof_pushed;          // until its route is queued
  axis_if #(.DATA_W(24), .USER_W(1)) sc ();
  logic sc_in_r, by_r;
  assign cs_r = !in_block && (route_now ? sc_in_r : by_r);
  wire  in_beat = cs_v && cs_r;

  logic out_busy, out_route, by_started;
  logic [15:0] out_lines, idle;
  wire  [15:0] v_act = regs[39*32 +: 16];
  logic [3:0] rq_valid;
  always_comb for (int i = 0; i < 4; i++) rq_valid[i] = (3'(i) < rq_n) && rq[i];
  wire  sc_pending = (out_busy && out_route) || (|rq_valid);
  wire  pop        = !out_busy && rq_n != 0;
  wire  cur_route  = out_busy ? out_route : rq[0];
  wire  out_sel    = out_busy || pop;
  // A new SOF from the scaler ends the frame in progress and waits for the next one
  wire  sc_restart = out_busy && out_route && sc.tvalid && sc.tuser && out_lines != 0;
  // The next frame's SOF waits until the bypassed frame in progress is closed
  wire  by_cur     = out_sel && !cur_route;
  wire  by_hold    = out_busy && !out_route && by_started && at_sof;
  assign by_r = by_cur && o_r && !by_hold;
  assign sc.tready = (out_sel && cur_route) ? (o_r && !sc_restart) : !sc_pending;   // drain orphan output
  assign o_v  = out_sel && (cur_route ? (sc.tvalid && !sc_restart) : (cs_v && !route_now && !in_block && !by_hold));
  assign o_d  = cur_route ? sc.tdata : cs_d;
  assign o_l  = cur_route ? sc.tlast : cs_l;
  assign o_u  = cur_route ? sc.tuser : cs_u;
  wire  out_beat = o_v && o_r;
  wire  by_end   = by_hold && sof_pushed;
  wire  sc_end   = out_busy && out_route &&
                   ((out_beat && o_l && out_lines + 1'b1 >= v_act) ||            // full frame
                    sc_restart ||                                                // scaler restarted
                    (idle == 16'hFFFF));                                         // scaler stalled
  wire  out_end  = by_end || sc_end;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rq <= '0;
      rq_n <= '0;
      sof_pushed <= 1'b0;
      sof_route <= 1'b0;
      in_route <= 1'b0;
      out_busy <= 1'b0;
      out_route <= 1'b0;
      out_lines <= '0;
      idle <= '0;
      by_started <= 1'b0;
    end else begin
      if (push) begin
        sof_pushed <= 1'b1;
        sof_route <= new_route;
      end
      if (in_beat && cs_u) begin
        sof_pushed <= 1'b0;
        in_route <= sof_route;
      end
      if (pop) begin
        out_busy <= 1'b1;
        out_route <= rq[0];
        out_lines <= '0;
        idle <= '0;
        by_started <= 1'b0;
      end
      if (by_cur && in_beat && cs_u) by_started <= 1'b1;            // also in the pick clock
      if (out_beat && o_l) out_lines <= out_lines + 1'b1;
      if (out_busy) idle <= out_beat ? 16'd0 : (idle == 16'hFFFF ? idle : idle + 1'b1);
      if (out_end) out_busy <= 1'b0;
      case ({push, pop})
        2'b10: begin
          rq[rq_n[1:0]] <= new_route;                   // rq_n < 4 when pushing
          rq_n <= rq_n + 1'b1;
        end
        2'b01: begin
          rq <= {1'b0, rq[3:1]};
          rq_n <= rq_n - 1'b1;
        end
        2'b11: begin
          rq <= {1'b0, rq[3:1]};
          rq[2'(rq_n - 1'b1)] <= new_route;
        end
        default: ;
      endcase
    end
  end

  if (SCALER) begin : g_scaler
    axil_if #(.ADDR_W(14)) u_scaler_s_axil ();
    assign u_scaler_s_axil.awaddr = sp_awaddr[15 +: 14];
    assign u_scaler_s_axil.awvalid = sp_awvalid[1];
    assign sp_awready[1] = u_scaler_s_axil.awready;
    assign u_scaler_s_axil.wdata = sp_wdata[63:32];
    assign u_scaler_s_axil.wstrb = sp_wstrb[7:4];
    assign u_scaler_s_axil.wvalid = sp_wvalid[1];
    assign sp_wready[1] = u_scaler_s_axil.wready;
    assign sp_bresp[3:2] = u_scaler_s_axil.bresp;
    assign sp_bvalid[1] = u_scaler_s_axil.bvalid;
    assign u_scaler_s_axil.bready = sp_bready[1];
    assign u_scaler_s_axil.araddr = sp_araddr[15 +: 14];
    assign u_scaler_s_axil.arvalid = sp_arvalid[1];
    assign sp_arready[1] = u_scaler_s_axil.arready;
    assign sp_rdata[63:32] = u_scaler_s_axil.rdata;
    assign sp_rresp[3:2] = u_scaler_s_axil.rresp;
    assign sp_rvalid[1] = u_scaler_s_axil.rvalid;
    assign u_scaler_s_axil.rready = sp_rready[1];
    axis_if #(.DATA_W((3 * 8))) u_scaler_s_axis ();
    assign u_scaler_s_axis.tdata = cs_d;
    assign u_scaler_s_axis.tvalid = cs_v && route_now && !in_block;
    assign sc_in_r = u_scaler_s_axis.tready;
    assign u_scaler_s_axis.tuser = cs_u;
    assign u_scaler_s_axis.tlast = cs_l;
    axis_if #(.DATA_W((3 * 8))) u_scaler_m_axis ();   // bridge (generate scope)
    assign sc.tdata = u_scaler_m_axis.tdata;
    assign sc.tkeep = u_scaler_m_axis.tkeep;
    assign sc.tlast = u_scaler_m_axis.tlast;
    assign sc.tuser = u_scaler_m_axis.tuser;
    assign sc.tvalid = u_scaler_m_axis.tvalid;
    assign u_scaler_m_axis.tready = sc.tready;
    scaler_bilinear #(
      .CHANNELS(3),
      .COMP_W(8),
      .MAX_W(MAX_W),
      .MAX_H(4096),
      .ADDR_W(14),
      .LINE_BUF(1)
    ) u_scaler (
      .clk,
      .rst_n,
      .s_axil(u_scaler_s_axil),
      .s_axis(u_scaler_s_axis),
      .m_axis(u_scaler_m_axis)
    );
  end else begin : g_no_scaler
    assign sc_in_r = 1'b0;
    assign sc.tvalid = 1'b0;
    assign sc.tdata = '0;
    assign sc.tlast = 1'b0;
    assign sc.tuser = 1'b0;
    // Answer the scaler window with SLVERR (its address, data and strobes are not used); AW and W are
    // taken in any order, the response follows both
    wire unused_win = &{1'b0, sp_awaddr[28:15], sp_araddr[28:15], sp_wdata[63:32], sp_wstrb[7:4], 1'b0};
    logic aw_q, w_q, b_q, ar_q;
    assign sp_awready[1] = !aw_q && !b_q;
    assign sp_wready[1] = !w_q && !b_q;
    assign sp_bvalid[1] = b_q;
    assign sp_bresp[3:2] = 2'b10;
    assign sp_arready[1] = !ar_q;
    assign sp_rvalid[1] = ar_q;
    assign sp_rresp[3:2] = 2'b10;
    assign sp_rdata[63:32] = '0;
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        aw_q <= 1'b0;
        w_q <= 1'b0;
        b_q <= 1'b0;
        ar_q <= 1'b0;
      end
      else begin
        if (b_q && sp_bready[1]) begin
          b_q <= 1'b0;
          aw_q <= 1'b0;
          w_q <= 1'b0;
        end else begin
          if (sp_awvalid[1] && sp_awready[1]) aw_q <= 1'b1;
          if (sp_wvalid[1] && sp_wready[1]) w_q <= 1'b1;
          if (!b_q && (aw_q || sp_awvalid[1]) && (w_q || sp_wvalid[1])) b_q <= 1'b1;
        end
        if (sp_arvalid[1] && !ar_q) ar_q <= 1'b1;
        else if (sp_rready[1]) ar_q <= 1'b0;
      end
    end
  end

  // ================================================================ video output
  vid_if tim ();
  logic sof, eol, vbl, waiting, src_ready;
  logic [15:0] vx, vy;
  vid_timing_gen u_vtg (
    .clk,
    .rst_n,
    .enable_i(out_en),
    .h_active_i(regs[35*32 +: 16]),
    .h_fp_i(regs[36*32 +: 16]),
    .h_sync_i(regs[37*32 +: 16]),
    .h_bp_i(regs[38*32 +: 16]),
    .v_active_i(regs[39*32 +: 16]),
    .v_fp_i(regs[40*32 +: 16]),
    .v_sync_i(regs[41*32 +: 16]),
    .v_bp_i(regs[42*32 +: 16]),
    .hs_pol_i(regs[43*32 + 0]),
    .vs_pol_i(regs[43*32 + 1]),
    .lock_en_i(lock_en),
    .src_ready_i(src_ready),
    .lock_max_i(regs[44*32 +: 16]),
    .tim(tim),
    .x_o(vx),
    .y_o(vy),
    .sof_o(sof),
    .eol_o(eol),
    .vblank_o(vbl),
    .waiting_o(waiting)
  );

  // ================================================================ end-of-frame markers
  // Line count from the SOF beat (tuser); the tlast of line height - 1 ends the frame.
  logic [15:0] ln_in, ln_out;
  wire  [15:0] ln_in_c  = u.tuser ? 16'd0 : ln_in;
  wire  [15:0] ln_out_c = o_u ? 16'd0 : ln_out;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ln_in <= '0;
      ln_out <= '0;
      eof_in_o <= 1'b0;
      eof_out_o <= 1'b0;
    end
    else begin
      eof_in_o <= 1'b0;
      eof_out_o <= 1'b0;
      if (u.tvalid && u.tready) begin
        if (!u.tlast)                ln_in <= ln_in_c;
        else if (ln_in_c == fh - 16'd1) begin
          ln_in <= '0;
          eof_in_o <= 1'b1;
        end
        else                     ln_in <= ln_in_c + 16'd1;
      end
      if (o_v && o_r) begin
        if (!o_l)                ln_out <= ln_out_c;
        else if (ln_out_c == v_act - 16'd1) begin
          ln_out <= '0;
          eof_out_o <= 1'b1;
        end
        else                     ln_out <= ln_out_c + 16'd1;
      end
    end
  end

  vid_if #(.DATA_W(24)) v ();
  logic locked, underflow;
  axis_if #(.DATA_W(24)) u_out_s_axis ();
  assign u_out_s_axis.tdata = o_d;
  assign u_out_s_axis.tlast = o_l;
  assign u_out_s_axis.tuser = o_u;
  assign u_out_s_axis.tvalid = o_v;
  assign o_r = u_out_s_axis.tready;
  axis_to_video #(
    .PIX_W(24),
    .FIFO_DEPTH(OUT_FIFO)
  ) u_out (
    .clk,
    .rst_n,
    .tpg_en_i(tpg),
    .start_level_i(regs[45*32 +: 16]),
    .h_active_i(regs[35*32 +: 16]),
    .s_axis(u_out_s_axis),
    .tim(tim),
    .sof_i(sof),
    .vblank_i(vbl),
    .vid(v),
    .src_ready_o(src_ready),
    .locked_o(locked),
    .underflow_o(underflow)
  );

  // AVI InfoFrame follows the CSC: RGB when bypassed, else YCbCr 4:4:4 BT.601 / BT.709
`ifdef VP_HDMI
  wire csc_on = !byp[6];
  tmds_if u_hdmi_tmds ();
  assign tmds0_o = u_hdmi_tmds.ch0;
  assign tmds1_o = u_hdmi_tmds.ch1;
  assign tmds2_o = u_hdmi_tmds.ch2;
  assign tmds_clk_o = u_hdmi_tmds.clk;
  hdmi_tx u_hdmi (
    .clk,
    .rst_n,
    .hdmi_mode_i(hdmi_mode),
    .vs_pol_i(regs[43*32 + 1]),
    .avi_y_i(csc_on ? 2'd2 : 2'd0),
    .avi_c_i(csc_on ? (bt709 ? 2'd2 : 2'd1) : 2'd0),
    .avi_m_i(regs[46*32 + 8 +: 2]),
    .avi_vic_i(regs[46*32 +: 7]),
    .avi_q_i(regs[46*32 + 10 +: 2]),
    .vid(v),
    .tmds(u_hdmi_tmds)
  );
`endif

  // ================================================================ LVDS / DSI / CSI-2 outputs
  wire [31:0] oc = regs[54*32 +: 32];
`ifdef VP_LVDS
  lvds_tx u_lvds (
    .clk,
    .rst_n,
    .dual_i(oc[0]),
    .bpp18_i(oc[1]),
    .jeida_i(oc[2]),
    .vid(v),
    .link_a_o(lvds_a_o),
    .link_b_o(lvds_b_o),
    .clk_word_o(lvds_clk_word_o),
    .stb_o(lvds_stb_o)
    );
`endif

  logic dsi_drop, dsi_busy, dsi_busy_p, dsi_uf, ctx_drop, ctx_uf;
  // not reported: a DSI command over 64 payload bytes (cmd_err) or written into a full queue (cmd_ovf /
  // pay_ovf) is dropped - software keeps commands short and waits for TX_STATUS[0] = 0 between commands
  logic dsi_cmd_err, dsi_cmd_ovf, dsi_pay_ovf;
  logic [31:0] ctx_frames;
`ifdef VP_MIPI_TX
  // Byte-clock settings are quasi-static (change them with the outputs off)
  (* async_reg = "true" *) logic [31:0] oc_s1, oc_s2, dg_s1, dg_s2, cg_s1, cg_s2;
  always_ff @(posedge tx_byte_clk) begin
    oc_s1 <= oc;
    oc_s2 <= oc_s1;
    dg_s1 <= regs[55*32 +: 32];
    dg_s2 <= dg_s1;
    cg_s1 <= regs[56*32 +: 32];
    cg_s2 <= cg_s1;
  end
  // not used: the bits of OUT_CTRL / CSITX_GAP without a byte-clock function
  wire unused_tx = &{1'b0, oc_s2[31:12], oc_s2[8], oc_s2[4:0], cg_s2[31:16], 1'b0};
`endif
`ifdef VP_DSI
  ppi_tx_if #(.NLANES(DSI_LANES)) u_dsi_ppi ();
  assign dsi_lane_data_o = u_dsi_ppi.lane_data;
  assign dsi_lane_valid_o = u_dsi_ppi.lane_valid;
  assign dsi_hs_req_o = u_dsi_ppi.hs_req;
  assign u_dsi_ppi.tx_ready = dsi_tx_ready_i;
  dsi_tx #(.NLANES(DSI_LANES), .MAX_W(MAX_W)) u_dsi (
    .pclk(clk),
    .prst_n(rst_n),
    .video_en_i(oc[4]),
    .hs_pol_i(regs[43*32 + 0]),
    .vs_pol_i(regs[43*32 + 1]),
    .vid(v),
    .cmd_wr_i(dsi_cmd_wr),
    .cmd_i(dsi_cmd_d[24:0]),
    .cmd_byte_wr_i(dsi_cmd_byte_wr),
    .cmd_byte_i(dsi_cmd_byte_d[7:0]),
    .line_drop_o(dsi_drop),
    .bclk(tx_byte_clk),
    .brst_n(tx_byte_rst_n),
    .vc_i(oc_s2[7:6]),
    .eotp_i(oc_s2[5]),
    .sync_gap_i(dg_s2[15:0]),
    .line_gap_i(dg_s2[31:16]),
    .ppi(u_dsi_ppi),
    .cmd_busy_o(dsi_busy),
    .cmd_err_o(dsi_cmd_err),
    .cmd_ovf_o(dsi_cmd_ovf),
    .pay_ovf_o(dsi_pay_ovf),
    .underflow_o(dsi_uf)
    );
  bit_sync u_dsi_busy (
    .clk,
    .rst_n,
    .d_i(dsi_busy),
    .q_o(dsi_busy_p)
  );
`else
  assign dsi_drop = 1'b0;
  assign dsi_busy_p = 1'b0;
  assign dsi_busy = 1'b0;
  assign dsi_uf = 1'b0;
  assign {dsi_cmd_err, dsi_cmd_ovf, dsi_pay_ovf} = '0;
`endif
`ifdef VP_CSI2_TX
  ppi_tx_if #(.NLANES(CSITX_LANES)) u_csitx_ppi ();
  assign csitx_lane_data_o = u_csitx_ppi.lane_data;
  assign csitx_lane_valid_o = u_csitx_ppi.lane_valid;
  assign csitx_hs_req_o = u_csitx_ppi.hs_req;
  assign u_csitx_ppi.tx_ready = csitx_tx_ready_i;
  csi2_tx #(.NLANES(CSITX_LANES), .MAX_W(MAX_W)) u_csitx (
    .pclk(clk),
    .prst_n(rst_n),
    .enable_i(oc[8]),
    .vs_pol_i(regs[43*32 + 1]),
    .vid(v),
    .line_drop_o(ctx_drop),
    .frames_o(ctx_frames),
    .bclk(tx_byte_clk),
    .brst_n(tx_byte_rst_n),
    .vc_i(oc_s2[11:10]),
    .yuv422_i(oc_s2[9]),
    .lp_gap_i(cg_s2[15:0]),
    .ppi(u_csitx_ppi),
    .underflow_o(ctx_uf)
    );
`else
  assign ctx_drop = 1'b0;
  assign ctx_frames = '0;
  assign ctx_uf = 1'b0;
`endif
  // A byte engine that ran dry in a burst (underflow, tx_byte_clk) spoiled that line: counted with the
  // line drops (DSI_DROPS / CSITX_DROPS)
  logic dsi_uf_p, ctx_uf_p;
  logic [1:0] uf_busy, uf_drop;                   // not used (an underflow is at most one per line)
`ifdef VP_DSI
  pulse_sync u_dsi_uf (
    .src_clk(tx_byte_clk),
    .src_rst_n(tx_byte_rst_n),
    .pulse_i(dsi_uf),
    .busy_o(uf_busy[0]),
    .drop_o(uf_drop[0]),
    .dst_clk(clk),
    .dst_rst_n(rst_n),
    .pulse_o(dsi_uf_p)
  );
`else
  assign dsi_uf_p = 1'b0;
  assign uf_busy[0] = 1'b0;
  assign uf_drop[0] = 1'b0;
`endif
`ifdef VP_CSI2_TX
  pulse_sync u_ctx_uf (
    .src_clk(tx_byte_clk),
    .src_rst_n(tx_byte_rst_n),
    .pulse_i(ctx_uf),
    .busy_o(uf_busy[1]),
    .drop_o(uf_drop[1]),
    .dst_clk(clk),
    .dst_rst_n(rst_n),
    .pulse_o(ctx_uf_p)
  );
`else
  assign ctx_uf_p = 1'b0;
  assign uf_busy[1] = 1'b0;
  assign uf_drop[1] = 1'b0;
`endif
  logic [31:0] n_dsi_drop, n_ctx_drop;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      n_dsi_drop <= '0;
      n_ctx_drop <= '0;
    end
    else begin
      n_dsi_drop <= n_dsi_drop + 32'(dsi_drop) + 32'(dsi_uf_p);
      n_ctx_drop <= n_ctx_drop + 32'(ctx_drop) + 32'(ctx_uf_p);
    end
  end

  // ================================================================ counters and read-back
  logic [31:0] n_fs, n_corr, n_err, n_crc, n_under, n_dpc, n_ovf;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      n_fs <= '0;
      n_corr <= '0;
      n_err <= '0;
      n_crc <= '0;
      n_under <= '0;
      n_dpc <= '0;
      n_ovf <= '0;
    end
    else begin
      n_fs <= n_fs + p_fs;
      n_corr <= n_corr + p_corr;
      n_err <= n_err + p_err;
      n_crc <= n_crc + p_crc;
      n_under <= n_under + underflow;
      n_dpc <= n_dpc + dpc_corr;
      n_ovf <= n_ovf + p_ovf;
    end
  end
  always_comb begin
    rd = regs;
    rd[3*32 +: 32]  = {31'd0, locked};
    rd[27*32 +: 32] = '0;
    rd[29*32 +: 32] = st_r[31:0];
    rd[30*32 +: 32] = st_g[31:0];
    rd[31*32 +: 32] = st_b[31:0];
    rd[32*32 +: 32] = st_pix;
    rd[33*32 +: 32] = st_clip;
    rd[34*32 +: 32] = st_frames;
    rd[47*32 +: 32] = n_fs;
    rd[48*32 +: 32] = n_corr;
    rd[49*32 +: 32] = n_err;
    rd[50*32 +: 32] = n_crc;
    rd[51*32 +: 32] = n_under;
    rd[52*32 +: 32] = n_dpc;
    rd[53*32 +: 32] = n_ovf;
    rd[57*32 +: 32] = '0;
    rd[58*32 +: 32] = '0;
    rd[59*32 +: 32] = {31'd0, dsi_busy_p};
    rd[60*32 +: 32] = n_dsi_drop;
    rd[61*32 +: 32] = n_ctx_drop;
    rd[62*32 +: 32] = ctx_frames;
    rd[63*32 +: 32] = {25'd0, BUILD_INSERT, SCALER, BUILD_CSI2_TX, BUILD_DSI, BUILD_LVDS, BUILD_HDMI, BUILD_CSI2_RX};
  end
  // not used: register slots without a register (regs) and the values the register block reads itself
  // (rd), the address bits above each window, the 40-bit sums' upper bits (STAT_SUM_* report the low 32),
  // the video timing's unused outputs, the DSI command errors (see above), the synchronisers' status
  wire unused_ok = &{1'b0, regs[0 +: 32], rd, sp_awaddr[29], sp_awaddr[14], sp_araddr[29], sp_araddr[14],
                     st_r[39:32], st_g[39:32], st_b[39:32], uf_busy, uf_drop, dsi_cmd_err, dsi_cmd_ovf,
                     dsi_pay_ovf, eol, waiting, vx, vy, 1'b0};
  // not used in a build without these interfaces (configuration.sv)
`ifndef VP_INSERT
  wire unused_ins = &{1'b0, ir_r, 1'b0};
`endif
`ifndef VP_HDMI
  wire unused_hdmi = &{1'b0, hdmi_mode, 1'b0};
`endif
`ifndef VP_DSI
  wire unused_dsi = &{1'b0, dsi_cmd_wr, dsi_cmd_byte_wr, dsi_busy, dsi_uf, 1'b0};
`endif
`ifndef VP_CSI2_TX
  wire unused_ctx = &{1'b0, ctx_uf, 1'b0};
`endif
`ifndef VP_LVDS
`ifndef VP_MIPI_TX
  wire unused_oc = &{1'b0, oc, 1'b0};
`ifndef VP_HDMI
  wire unused_vid = &{1'b0, v.data, 1'b0};               // no video output built
`endif
`endif
`endif
endmodule
