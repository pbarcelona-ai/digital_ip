// ***************
// Filename: video_pipeline.sv
// Author: FPGA Cores 4 U
// Description: MIPI CSI-2 camera to HDMI / DVI video pipeline. Version 1.0.0.
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
//   AXI4-Lite (pix_clk), ADDR_W = 15: 0x0000-0x00FF pipeline registers,
//   0x4000-0x7FFF the scaler's own map (scaler_ctrl, base 0x4000).
//     0x000 ID          RO "VPIP"
//     0x004 CTRL        [0] output enable [1] HDMI (0 = DVI) [2] TPG
//                       [3] genlock [5:4] CFA (0 RGGB 1 GRBG 2 GBRG 3 BGGR)
//                       [6] CSC BT.709 (0 = BT.601)
//                       [7] insert: route the stream after isp_csc out
//                       through ins_m_axis_* and back in on ins_s_axis_*
//                       (`VP_INSERT; taken at the next frame start)
//     0x008 BYPASS      [0] BLC [1] WB [2] DPC [3] demosaic [4] CCM [5] gamma
//                       [6] CSC [7] scaler          (reset 0xC0: RGB out, no scaler)
//     0x00C STATUS      RO [0] output locked to the camera
//     0x010 CSI         [5:0] data type (reset 0x2B RAW10) [7:6] virtual channel
//     0x014 FRAME_SIZE  [15:0] camera width [31:16] height
//     0x018-0x024 BLC   R, Gr, Gb, B black levels
//     0x028-0x030 WB    R, G, B gains Q4.8 (reset 0x100)
//     0x034 DPC_THR     defect threshold (reset 64)
//     0x038-0x058 CCM   coefficients c00..c22, signed Q5.10 (reset identity)
//     0x05C-0x064 CCM   offsets R, G, B (signed)
//     0x068 GAMMA_ADDR  table index for the next GAMMA_DATA write
//     0x06C GAMMA_DATA  [7:0] writes table[index], index auto-increments
//     0x070 STAT_THR    clip threshold (10-bit, reset 1000)
//     0x074-0x07C STAT  RO sums of R, G, B (low 32 bits) of the last frame
//     0x080 STAT_PIX    RO pixels, 0x084 STAT_CLIP RO clipped pixels
//     0x088 STAT_FRAMES RO
//     0x08C-0x0A8 VTG   h active, h front porch, h sync, h back porch,
//                       v active, v front porch, v sync, v back porch
//     0x0AC SYNC_POL    [0] hsync [1] vsync active high
//     0x0B0 LOCK_MAX    genlock: max extra blanking lines (reset 1023)
//     0x0B4 START_LEVEL pixels buffered before a frame starts (reset 16)
//     0x0B8 AVI         [6:0] VIC [9:8] picture aspect [11:10] RGB range
//                       (colour space and colorimetry follow CSC settings)
//     0x0BC CSI_FRAMES  RO, 0x0C0 ECC_CORR RO, 0x0C4 ECC_ERR RO,
//     0x0C8 CRC_ERR RO, 0x0CC UNDERFLOWS RO, 0x0D0 DPC_CORR RO,
//     0x0D4 CSI_OVERFLOW RO (CSI words lost: the bridge FIFO was full)
//     0x0D8 OUT_CTRL    [0] LVDS dual link [1] LVDS 18 bpp [2] LVDS JEIDA
//                       [4] DSI video [5] DSI EoTp [7:6] DSI virtual channel
//                       [8] CSI-2 TX enable [9] CSI-2 TX YUV422 [11:10] its VC
//     0x0DC DSI_GAPS    [15:0] LP clocks after a sync packet, [31:16] after pixels
//     0x0E0 CSITX_GAP   LP clocks between CSI-2 TX packets
//     0x0E4 DSI_CMD     write: queue a DSI command {[24] long, [23:16] data
//                       type, [15:0] data / word count} (sent with DSI video off)
//     0x0E8 DSI_CMD_BYTE write: [7:0] next payload byte of a long command
//     0x0EC TX_STATUS   RO [0] DSI command queue busy
//     0x0F0 DSI_DROPS   RO lines DSI could not send in time
//     0x0F4 CSITX_DROPS RO lines CSI-2 TX could not send in time
//     0x0F8 CSITX_FRAMES RO frames sent by CSI-2 TX
//   The DSI, CSI-2 TX and LVDS outputs carry the same timed video as HDMI;
//   panels need RGB (CSC bypassed), CSI-2 YUV422 needs YCbCr (CSC on).
//   Scaler settings: clear its CTRL.ENABLE, wait for STATUS.BUSY = 0, then
//   change sizes / steps and enable it again (scaler_ctrl does not support
//   changing them while a frame is being generated).
//     0x0FC BUILD_CFG   RO interfaces built: [0] CSI-2 RX [1] HDMI [2] LVDS
//                       [3] DSI [4] CSI-2 TX [5] scaler [6] insert point
//   External interfaces are included or excluded with the `defines in
//   configuration.sv (compiled first, see scripts/build.f); an excluded
//   interface has no ports or logic and its registers read as 0.
//   Clocks - byte_clk (D-PHY), pix_clk (pipeline, registers, video out).
//   Resets - byte_rst_n, pix_rst_n, synchronous active low; assert both.
// Date: 2026-10-01
module video_pipeline #(
  parameter int NLANES     = 2,
  parameter int MAX_W      = 2048,               // longest camera / output line
  parameter int CSI_FIFO   = 2048,               // byte-clock to pixel-clock FIFO, words
  parameter int OUT_FIFO   = 2048,               // output pixel FIFO
  parameter bit SCALER     = 1,                  // include scaler_bilinear
  parameter int DSI_LANES  = 2,                  // MIPI DSI output lanes (1, 2, 4)
  parameter int CSITX_LANES = 2                  // MIPI CSI-2 output lanes (1, 2, 4)
) (
`ifdef VP_CSI2_RX
  // MIPI CSI-2 camera input (D-PHY RX, PPI)
  input  logic                byte_clk,
  input  logic                byte_rst_n,
  input  logic [NLANES*8-1:0] lane_data_i,
  input  logic [NLANES-1:0]   lane_valid_i,
`endif
  input  logic                pix_clk,
  input  logic                pix_rst_n,
  // AXI4-Lite slave (pix_clk)
  input  logic [14:0]         s_axil_awaddr,
  input  logic                s_axil_awvalid,
  output logic                s_axil_awready,
  input  logic [31:0]         s_axil_wdata,
  input  logic [3:0]          s_axil_wstrb,
  input  logic                s_axil_wvalid,
  output logic                s_axil_wready,
  output logic [1:0]          s_axil_bresp,
  output logic                s_axil_bvalid,
  input  logic                s_axil_bready,
  input  logic [14:0]         s_axil_araddr,
  input  logic                s_axil_arvalid,
  output logic                s_axil_arready,
  output logic [31:0]         s_axil_rdata,
  output logic [1:0]          s_axil_rresp,
  output logic                s_axil_rvalid,
  input  logic                s_axil_rready,
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
  output logic [23:0]         ins_m_axis_tdata,
  output logic                ins_m_axis_tlast,
  output logic                ins_m_axis_tuser,
  output logic                ins_m_axis_tvalid,
  input  logic                ins_m_axis_tready,
  input  logic [23:0]         ins_s_axis_tdata,
  input  logic                ins_s_axis_tlast,
  input  logic                ins_s_axis_tuser,
  input  logic                ins_s_axis_tvalid,
  output logic                ins_s_axis_tready,
`endif
  // End-of-frame markers (pix_clk pulses, e.g. for a frame counter): the last pixel of a frame
  // leaving csi2_raw_unpack (first ISP stage, FRAME_SIZE height) / entering axis_to_video (last
  // stream stage, VTG v active height)
  output logic                eof_in_o,
  output logic                eof_out_o,
  output logic                stats_done_o       // pulse: new statistics available
);
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
  logic [14:0] r_awaddr [2], r_araddr [2];
  logic [29:0] sp_awaddr, sp_araddr;
  logic [1:0] sp_awvalid, sp_awready, sp_wvalid, sp_wready, sp_bvalid, sp_bready;
  logic [1:0] sp_arvalid, sp_arready, sp_rvalid, sp_rready;
  logic [63:0] sp_wdata, sp_rdata;
  logic [7:0] sp_wstrb;
  logic [3:0] sp_bresp, sp_rresp;
  axil_split #(
    .ADDR_W(15),
    .SEL_BIT(14)
  ) u_split (
    .clk,
    .rst_n,
    .s_awaddr(s_axil_awaddr),
    .s_awvalid(s_axil_awvalid),
    .s_awready(s_axil_awready),
    .s_wdata(s_axil_wdata),
    .s_wstrb(s_axil_wstrb),
    .s_wvalid(s_axil_wvalid),
    .s_wready(s_axil_wready),
    .s_bresp(s_axil_bresp),
    .s_bvalid(s_axil_bvalid),
    .s_bready(s_axil_bready),
    .s_araddr(s_axil_araddr),
    .s_arvalid(s_axil_arvalid),
    .s_arready(s_axil_arready),
    .s_rdata(s_axil_rdata),
    .s_rresp(s_axil_rresp),
    .s_rvalid(s_axil_rvalid),
    .s_rready(s_axil_rready),
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

  localparam int NREG = 64;
  function automatic logic [NREG*32-1:0] reset_vals();
    logic [NREG*32-1:0] v;
    v = '0;
    v[2*32 +: 32]  = 32'h0000_00C0;              // BYPASS: CSC, scaler
    v[4*32 +: 32]  = 32'h0000_002B;              // CSI: RAW10, VC 0
    v[10*32 +: 32] = 32'd256;
    v[11*32 +: 32] = 32'd256;
    v[12*32 +: 32] = 32'd256;
    v[13*32 +: 32] = 32'd64;
    v[14*32 +: 32] = 32'd1024;
    v[18*32 +: 32] = 32'd1024;
    v[22*32 +: 32] = 32'd1024;
    v[28*32 +: 32] = 32'd1000;
    v[44*32 +: 32] = 32'd1023;
    v[45*32 +: 32] = 32'd16;
    v[46*32 +: 32] = {20'd0, 2'd0, 2'd2, 1'b0, 7'd0};   // aspect 16:9, VIC 0
    v[55*32 +: 32] = {16'd6, 16'd10};                    // DSI gaps
    v[56*32 +: 32] = 32'd8;                              // CSI-2 TX gap
    reset_vals = v;
  endfunction
  logic [NREG*32-1:0] regs, rd;
  logic [NREG-1:0] wr_pulse;
  logic [31:0] wr_data;
  ip_axil_regs #(
    .ADDR_W(8),
    .NREG(NREG),
    .RESET_VALS(reset_vals())
  ) u_regs (
    .aclk(clk),
    .aresetn(rst_n),
    .s_axil_awaddr(sp_awaddr[7:0]),
    .s_axil_awvalid(sp_awvalid[0]),
    .s_axil_awready(sp_awready[0]),
    .s_axil_wdata(sp_wdata[31:0]),
    .s_axil_wstrb(sp_wstrb[3:0]),
    .s_axil_wvalid(sp_wvalid[0]),
    .s_axil_wready(sp_wready[0]),
    .s_axil_bresp(sp_bresp[1:0]),
    .s_axil_bvalid(sp_bvalid[0]),
    .s_axil_bready(sp_bready[0]),
    .s_axil_araddr(sp_araddr[7:0]),
    .s_axil_arvalid(sp_arvalid[0]),
    .s_axil_arready(sp_arready[0]),
    .s_axil_rdata(sp_rdata[31:0]),
    .s_axil_rresp(sp_rresp[1:0]),
    .s_axil_rvalid(sp_rvalid[0]),
    .s_axil_rready(sp_rready[0]),
    .reg_o(regs),
    .wr_pulse_o(wr_pulse),
    .wr_data_o(wr_data),
    .rd_i(rd)
  );

  wire        out_en  = regs[1*32 + 0], hdmi_mode = regs[1*32 + 1], tpg = regs[1*32 + 2], lock_en = regs[1*32 + 3];
  wire [1:0]  cfa     = regs[1*32 + 4 +: 2];
  wire        bt709   = regs[1*32 + 6];
  wire [7:0]  byp     = regs[2*32 +: 8];
  wire [15:0] fw = regs[5*32 +: 16], fh = regs[5*32 + 16 +: 16];

  // ================================================================ CSI-2 (byte clock)
  logic [NLANES*8-1:0] b_data;
  logic [NLANES-1:0] b_keep;
  logic b_last, b_user, b_valid, b_ready;
  logic p_fs, p_corr, p_err, p_crc, p_ovf;
`ifdef VP_CSI2_RX
  // Data type / VC are quasi-static: change them only while the camera is stopped
  (* async_reg = "true" *) logic [7:0] csi_cfg_s1, csi_cfg_s2;
  always_ff @(posedge byte_clk) begin
    csi_cfg_s1 <= regs[4*32 +: 8];
    csi_cfg_s2 <= csi_cfg_s1;
  end
  logic [NLANES*8-1:0] c_data;
  logic [NLANES-1:0] c_keep;
  logic c_last, c_user, c_valid, c_ready;
  logic e_fs, e_fe, e_line, e_corr, e_err, e_crc, e_ovf;
  csi2_rx #(.NLANES(NLANES)) u_csi (
    .clk(byte_clk),
    .rst_n(byte_rst_n),
    .lane_data_i,
    .lane_valid_i,
    .vc_i(csi_cfg_s2[7:6]),
    .dt_i(csi_cfg_s2[5:0]),
    .m_axis_tdata(c_data),
    .m_axis_tkeep(c_keep),
    .m_axis_tlast(c_last),
    .m_axis_tuser(c_user),
    .m_axis_tvalid(c_valid),
    .m_axis_tready(c_ready),
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
    .s_axis_tdata(c_data),
    .s_axis_tkeep(c_keep),
    .s_axis_tlast(c_last),
    .s_axis_tuser(c_user),
    .s_axis_tvalid(c_valid),
    .s_axis_tready(c_ready),
    .m_clk(clk),
    .m_rst_n(rst_n),
    .m_axis_tdata(b_data),
    .m_axis_tkeep(b_keep),
    .m_axis_tlast(b_last),
    .m_axis_tuser(b_user),
    .m_axis_tvalid(b_valid),
    .m_axis_tready(b_ready)
  );

  // Status events into the pixel domain
  pulse_sync u_ps_fs   (
    .src_clk(byte_clk),
    .src_rst_n(byte_rst_n),
    .pulse_i(e_fs),
    .busy_o(),
    .drop_o(),
    .dst_clk(clk),
    .dst_rst_n(rst_n),
    .pulse_o(p_fs)
  );
  pulse_sync u_ps_corr (
    .src_clk(byte_clk),
    .src_rst_n(byte_rst_n),
    .pulse_i(e_corr),
    .busy_o(),
    .drop_o(),
    .dst_clk(clk),
    .dst_rst_n(rst_n),
    .pulse_o(p_corr)
  );
  pulse_sync u_ps_err  (
    .src_clk(byte_clk),
    .src_rst_n(byte_rst_n),
    .pulse_i(e_err),
    .busy_o(),
    .drop_o(),
    .dst_clk(clk),
    .dst_rst_n(rst_n),
    .pulse_o(p_err)
  );
  pulse_sync u_ps_crc  (
    .src_clk(byte_clk),
    .src_rst_n(byte_rst_n),
    .pulse_i(e_crc),
    .busy_o(),
    .drop_o(),
    .dst_clk(clk),
    .dst_rst_n(rst_n),
    .pulse_o(p_crc)
  );
  pulse_sync u_ps_ovf  (
    .src_clk(byte_clk),
    .src_rst_n(byte_rst_n),
    .pulse_i(e_ovf),
    .busy_o(),
    .drop_o(),
    .dst_clk(clk),
    .dst_rst_n(rst_n),
    .pulse_o(p_ovf)
  );
`else
  // No camera: the ISP input stays idle
  assign b_data = '0;
  assign b_keep = '0;
  assign b_last = 1'b0;
  assign b_user = 1'b0;
  assign b_valid = 1'b0;
  assign p_fs = 1'b0;
  assign p_corr = 1'b0;
  assign p_err = 1'b0;
  assign p_crc = 1'b0;
  assign p_ovf = 1'b0;
`endif

  // ================================================================ ISP (pixel clock)
  logic [RW-1:0] u_d;
  logic u_l, u_u, u_v, u_r;
  csi2_raw_unpack #(
    .IN_BYTES(NLANES),
    .OUT_W(RW)
  ) u_unpack (
    .clk,
    .rst_n,
    .fmt_i(regs[4*32 +: 6]),
    .s_axis_tdata(b_data),
    .s_axis_tkeep(b_keep),
    .s_axis_tlast(b_last),
    .s_axis_tuser(b_user),
    .s_axis_tvalid(b_valid),
    .s_axis_tready(b_ready),
    .m_axis_tdata(u_d),
    .m_axis_tlast(u_l),
    .m_axis_tuser(u_u),
    .m_axis_tvalid(u_v),
    .m_axis_tready(u_r)
  );

  logic [RW-1:0] g_d;
  logic g_l, g_u, g_v, g_r;
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
    .s_axis_tdata(u_d),
    .s_axis_tlast(u_l),
    .s_axis_tuser(u_u),
    .s_axis_tvalid(u_v),
    .s_axis_tready(u_r),
    .m_axis_tdata(g_d),
    .m_axis_tlast(g_l),
    .m_axis_tuser(g_u),
    .m_axis_tvalid(g_v),
    .m_axis_tready(g_r)
  );

  logic [RW-1:0] p_d;
  logic p_l, p_u, p_v, p_r, dpc_corr;
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
    .s_axis_tdata(g_d),
    .s_axis_tlast(g_l),
    .s_axis_tuser(g_u),
    .s_axis_tvalid(g_v),
    .s_axis_tready(g_r),
    .m_axis_tdata(p_d),
    .m_axis_tlast(p_l),
    .m_axis_tuser(p_u),
    .m_axis_tvalid(p_v),
    .m_axis_tready(p_r)
  );

  logic [3*RW-1:0] d_d;
  logic d_l, d_u, d_v, d_r;
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
    .s_axis_tdata(p_d),
    .s_axis_tlast(p_l),
    .s_axis_tuser(p_u),
    .s_axis_tvalid(p_v),
    .s_axis_tready(p_r),
    .m_axis_tdata(d_d),
    .m_axis_tlast(d_l),
    .m_axis_tuser(d_u),
    .m_axis_tvalid(d_v),
    .m_axis_tready(d_r)
  );

  logic [3*RW-1:0] m_d;
  logic m_l, m_u, m_v, m_r;
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
    .s_axis_tdata(d_d),
    .s_axis_tlast(d_l),
    .s_axis_tuser(d_u),
    .s_axis_tvalid(d_v),
    .s_axis_tready(d_r),
    .m_axis_tdata(m_d),
    .m_axis_tlast(m_l),
    .m_axis_tuser(m_u),
    .m_axis_tvalid(m_v),
    .m_axis_tready(m_r)
  );

  // Statistics on linear RGB (after the CCM)
  logic [39:0] st_r, st_g, st_b;
  logic [31:0] st_pix, st_clip, st_frames;
  isp_stats #(.CW(RW)) u_stats (
    .clk,
    .rst_n,
    .sat_thr_i(regs[28*32 +: RW]),
    .flush_i(1'b0),
    .tdata(m_d),
    .tuser(m_u),
    .tvalid(m_v),
    .tready(m_r),
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
      g_we <= wr_pulse[27];
      if (wr_pulse[26]) gidx <= wr_data[RW-1:0];
      if (wr_pulse[27]) begin
        g_wa <= gidx;
        g_wd <= wr_data[7:0];
        gidx <= gidx + 1'b1;
      end
    end
  end
  logic [23:0] gm_d;
  logic gm_l, gm_u, gm_v, gm_r;
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
    .s_axis_tdata(m_d),
    .s_axis_tlast(m_l),
    .s_axis_tuser(m_u),
    .s_axis_tvalid(m_v),
    .s_axis_tready(m_r),
    .m_axis_tdata(gm_d),
    .m_axis_tlast(gm_l),
    .m_axis_tuser(gm_u),
    .m_axis_tvalid(gm_v),
    .m_axis_tready(gm_r)
  );

  logic [23:0] cq_d;
  logic cq_l, cq_u, cq_v, cq_r;
  isp_csc u_csc (
    .clk,
    .rst_n,
    .bypass_i(byp[6]),
    .bt709_i(bt709),
    .s_axis_tdata(gm_d),
    .s_axis_tlast(gm_l),
    .s_axis_tuser(gm_u),
    .s_axis_tvalid(gm_v),
    .s_axis_tready(gm_r),
    .m_axis_tdata(cq_d),
    .m_axis_tlast(cq_l),
    .m_axis_tuser(cq_u),
    .m_axis_tvalid(cq_v),
    .m_axis_tready(cq_r)
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
  assign ins_m_axis_tdata = cq_d;
  assign ins_m_axis_tlast = cq_l;
  assign ins_m_axis_tuser = cq_u;
  assign im_r = ins_m_axis_tready;
  assign ir_d = ins_s_axis_tdata;
  assign ir_l = ins_s_axis_tlast;
  assign ir_u = ins_s_axis_tuser;
  assign ir_v = ins_s_axis_tvalid;
  assign ins_s_axis_tready = ir_r;
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
  assign ins_m_axis_tvalid = cq_v && ins_sel;
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
  logic [23:0] sc_d;
  logic sc_l, sc_u, sc_v, sc_r, sc_in_r, by_r;
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
  wire  sc_restart = out_busy && out_route && sc_v && sc_u && out_lines != 0;
  // The next frame's SOF waits until the bypassed frame in progress is closed
  wire  by_cur     = out_sel && !cur_route;
  wire  by_hold    = out_busy && !out_route && by_started && at_sof;
  assign by_r = by_cur && o_r && !by_hold;
  assign sc_r = (out_sel && cur_route) ? (o_r && !sc_restart) : !sc_pending;   // drain orphan output
  assign o_v  = out_sel && (cur_route ? (sc_v && !sc_restart) : (cs_v && !route_now && !in_block && !by_hold));
  assign o_d  = cur_route ? sc_d : cs_d;
  assign o_l  = cur_route ? sc_l : cs_l;
  assign o_u  = cur_route ? sc_u : cs_u;
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
          rq[rq_n] <= new_route;
          rq_n <= rq_n + 1'b1;
        end
        2'b01: begin
          rq <= {1'b0, rq[3:1]};
          rq_n <= rq_n - 1'b1;
        end
        2'b11: begin
          rq <= {1'b0, rq[3:1]};
          rq[rq_n - 1'b1] <= new_route;
        end
        default: ;
      endcase
    end
  end

  if (SCALER) begin : g_scaler
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
      .s_axil_awaddr(sp_awaddr[15 +: 14]),
      .s_axil_awvalid(sp_awvalid[1]),
      .s_axil_awready(sp_awready[1]),
      .s_axil_wdata(sp_wdata[63:32]),
      .s_axil_wstrb(sp_wstrb[7:4]),
      .s_axil_wvalid(sp_wvalid[1]),
      .s_axil_wready(sp_wready[1]),
      .s_axil_bresp(sp_bresp[3:2]),
      .s_axil_bvalid(sp_bvalid[1]),
      .s_axil_bready(sp_bready[1]),
      .s_axil_araddr(sp_araddr[15 +: 14]),
      .s_axil_arvalid(sp_arvalid[1]),
      .s_axil_arready(sp_arready[1]),
      .s_axil_rdata(sp_rdata[63:32]),
      .s_axil_rresp(sp_rresp[3:2]),
      .s_axil_rvalid(sp_rvalid[1]),
      .s_axil_rready(sp_rready[1]),
      .s_axis_tdata(cs_d),
      .s_axis_tvalid(cs_v && route_now && !in_block),
      .s_axis_tready(sc_in_r),
      .s_axis_tuser(cs_u),
      .s_axis_tlast(cs_l),
      .m_axis_tdata(sc_d),
      .m_axis_tvalid(sc_v),
      .m_axis_tready(sc_r),
      .m_axis_tuser(sc_u),
      .m_axis_tlast(sc_l)
    );
  end else begin : g_no_scaler
    assign sc_in_r = 1'b0;
    assign sc_v = 1'b0;
    assign sc_d = '0;
    assign sc_l = 1'b0;
    assign sc_u = 1'b0;
    // Answer the scaler window with SLVERR
    logic aw_q, b_q, ar_q;
    assign sp_awready[1] = !b_q;
    assign sp_wready[1] = !b_q;
    assign sp_bvalid[1] = b_q;
    assign sp_bresp[3:2] = 2'b10;
    assign sp_arready[1] = !ar_q;
    assign sp_rvalid[1] = ar_q;
    assign sp_rresp[3:2] = 2'b10;
    assign sp_rdata[63:32] = '0;
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        b_q <= 1'b0;
        ar_q <= 1'b0;
        aw_q <= 1'b0;
      end
      else begin
        if (sp_awvalid[1] && sp_wvalid[1] && !b_q) b_q <= 1'b1;
        else if (sp_bready[1]) b_q <= 1'b0;
        if (sp_arvalid[1] && !ar_q) ar_q <= 1'b1;
        else if (sp_rready[1]) ar_q <= 1'b0;
      end
    end
  end

  // ================================================================ video output
  logic de, hs, vs, sof, eol, vbl, waiting, src_ready;
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
    .de_o(de),
    .hs_o(hs),
    .vs_o(vs),
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
  wire  [15:0] ln_in_c  = u_u ? 16'd0 : ln_in;
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
      if (u_v && u_r) begin
        if (!u_l)                ln_in <= ln_in_c;
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

  logic [23:0] v_rgb;
  logic v_de, v_hs, v_vs, locked, underflow;
  axis_to_video #(
    .PIX_W(24),
    .FIFO_DEPTH(OUT_FIFO)
  ) u_out (
    .clk,
    .rst_n,
    .tpg_en_i(tpg),
    .start_level_i(regs[45*32 +: 16]),
    .h_active_i(regs[35*32 +: 16]),
    .s_axis_tdata(o_d),
    .s_axis_tlast(o_l),
    .s_axis_tuser(o_u),
    .s_axis_tvalid(o_v),
    .s_axis_tready(o_r),
    .de_i(de),
    .hs_i(hs),
    .vs_i(vs),
    .sof_i(sof),
    .vblank_i(vbl),
    .rgb_o(v_rgb),
    .de_o(v_de),
    .hs_o(v_hs),
    .vs_o(v_vs),
    .src_ready_o(src_ready),
    .locked_o(locked),
    .underflow_o(underflow)
  );

  // AVI InfoFrame follows the CSC: RGB when bypassed, else YCbCr 4:4:4 BT.601 / BT.709
`ifdef VP_HDMI
  wire csc_on = !byp[6];
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
    .rgb_i(v_rgb),
    .de_i(v_de),
    .hs_i(v_hs),
    .vs_i(v_vs),
    .tmds0_o,
    .tmds1_o,
    .tmds2_o,
    .tmds_clk_o
  );
`endif

  // ================================================================ LVDS / DSI / CSI-2 outputs
  wire [31:0] oc = regs[54*32 +: 32];
`ifdef VP_LVDS
  lvds_tx u_lvds (.clk, .rst_n, .dual_i(oc[0]), .bpp18_i(oc[1]), .jeida_i(oc[2]),
    .rgb_i(v_rgb), .de_i(v_de), .hs_i(v_hs), .vs_i(v_vs),
    .link_a_o(lvds_a_o), .link_b_o(lvds_b_o), .clk_word_o(lvds_clk_word_o), .stb_o(lvds_stb_o));
`endif

  logic dsi_drop, dsi_busy, dsi_busy_p, dsi_uf, ctx_drop, ctx_uf;
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
`endif
`ifdef VP_DSI
  dsi_tx #(.NLANES(DSI_LANES), .MAX_W(MAX_W)) u_dsi (.pclk(clk), .prst_n(rst_n), .video_en_i(oc[4]),
    .hs_pol_i(regs[43*32 + 0]), .vs_pol_i(regs[43*32 + 1]), .rgb_i(v_rgb), .de_i(v_de), .hs_i(v_hs), .vs_i(v_vs),
    .cmd_wr_i(wr_pulse[57]), .cmd_i(wr_data[24:0]), .cmd_byte_wr_i(wr_pulse[58]), .cmd_byte_i(wr_data[7:0]),
    .line_drop_o(dsi_drop), .bclk(tx_byte_clk), .brst_n(tx_byte_rst_n),
    .vc_i(oc_s2[7:6]), .eotp_i(oc_s2[5]), .sync_gap_i(dg_s2[15:0]), .line_gap_i(dg_s2[31:16]),
    .lane_data_o(dsi_lane_data_o), .lane_valid_o(dsi_lane_valid_o), .hs_req_o(dsi_hs_req_o), .tx_ready_i(dsi_tx_ready_i),
    .cmd_busy_o(dsi_busy), .underflow_o(dsi_uf));
  bit_sync u_dsi_busy (
    .clk,
    .rst_n,
    .d_i(dsi_busy),
    .q_o(dsi_busy_p)
  );
`else
  assign dsi_drop = 1'b0;
  assign dsi_busy_p = 1'b0;
`endif
`ifdef VP_CSI2_TX
  csi2_tx #(.NLANES(CSITX_LANES), .MAX_W(MAX_W)) u_csitx (.pclk(clk), .prst_n(rst_n), .enable_i(oc[8]),
    .vs_pol_i(regs[43*32 + 1]), .rgb_i(v_rgb), .de_i(v_de), .vs_i(v_vs), .line_drop_o(ctx_drop), .frames_o(ctx_frames),
    .bclk(tx_byte_clk), .brst_n(tx_byte_rst_n), .vc_i(oc_s2[11:10]), .yuv422_i(oc_s2[9]), .lp_gap_i(cg_s2[15:0]),
    .lane_data_o(csitx_lane_data_o), .lane_valid_o(csitx_lane_valid_o), .hs_req_o(csitx_hs_req_o), .tx_ready_i(csitx_tx_ready_i),
    .underflow_o(ctx_uf));
`else
  assign ctx_drop = 1'b0;
  assign ctx_frames = '0;
`endif
  logic [31:0] n_dsi_drop, n_ctx_drop;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      n_dsi_drop <= '0;
      n_ctx_drop <= '0;
    end
    else begin
      n_dsi_drop <= n_dsi_drop + dsi_drop;
      n_ctx_drop <= n_ctx_drop + ctx_drop;
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
    rd[0*32 +: 32]  = 32'h5650_4950;             // "VPIP"
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
endmodule
