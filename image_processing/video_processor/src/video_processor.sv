// ***************
// Filename: video_processor.sv
// Author: FPGA Cores 4 U
// Description: Top level of the video processing system (see
//   docs/system_block_diagram.svg). Version 2.0.0. Technology independent:
//   no target device is selected; a board wrapper adds the PLL / MMCM, the
//   vendor D-PHY RX / TX, differential buffers and I/O pads.
//
//     u_cpu        py_soc           control CPU: Python bytecode from SPI
//                                   flash, 2x UART, 2x I2C, 2x SPI, 96 GPIO,
//                                   intc, watchdog; external window
//                                   0x1_0000-0x1_FFFF -> video registers
//     u_axil_cdc   axi4_lite_cdc    cpu_clk -> pix_clk
//     u_vbus       py_axil_xbar     video register bus (axi4_lite_decoder)
//     u_pipe       video_pipeline   CSI-2 RX -> ISP -> [insert] -> scaler ->
//                                   timing -> hdmi_tx / lvds_tx / dsi_tx /
//                                   csi2_tx
//     u_vs_adapt   vs_stream_adapter frame admission, line gaps, return
//                                   FIFO (vision_system output never stalls)
//     u_vision     vision_system    lens-distortion correction at the
//                                   video_pipeline insert point (CTRL[7])
//     u_filter     blur_sharpen     blur / sharpen after vision_system, same
//                                   insert loop (MODE 0-3, 4 = pass-through)
//     u_irq_stats  pulse_sync       isp_stats frame done -> intc source 12
//     u_tmds_ser   tmds_serializer  10:1 HDMI / DVI
//     u_lvds_ser_a/b lvds_serializer 7:1 LVDS links A / B
//     u_rst_*      reset_sync       one per clock domain, from arst_n
//
//   CPU address map (py_soc, mem32[] in the firmware):
//     0x0_0100-0x0_C1FF  py_soc peripherals (see py_soc.sv)
//     0x1_0000-0x1_7FFF  video_pipeline (0x1_4000+ scaler)
//     0x1_8000-0x1_80FF  vision_system (axi_lite_regs)          `VP_VISION
//     0x1_8200-0x1_83FF  blur_sharpen                           `VP_FILTER
//   Interrupts: intc source 12 = isp_stats frame done (configure it as an
//   edge source), 13-15 spare (ext_irq_i).
//
//   Configuration (src/configuration.sv): `VP_CSI2_RX, `VP_HDMI, `VP_LVDS,
//   `VP_DSI, `VP_CSI2_TX select the external video interfaces, `VP_VISION
//   adds vision_system and `VP_FILTER blur_sharpen, both in the
//   video_pipeline insert loop (`VP_INSERT, enabled by CTRL[7]):
//     insert point -> [vs_stream_adapter -> vision_system] -> [blur_sharpen] -> back
//   With vision_system in the path, keep CTRL.LOCK (genlock) set: there is
//   no frame buffer to repeat a frame, so each display frame waits in
//   vertical blanking for the next corrected frame (the display follows
//   vision_system's output rate, up to LOCK_MAX extra lines). vision_system
//   frames are at most 720 x 720 (barrel_pkg).
//
//   Clocks: cpu_clk (CPU, CPU_HZ), pix_clk (video, registers, vision_system),
//   byte_clk (D-PHY RX), tmds_ser_clk = 10x pix_clk, lvds_ser_clk = 7x
//   (single link) or 3.5x (dual link) pix_clk, tx_byte_clk (D-PHY TX).
//   Reset: arst_n, asynchronous active low; each domain gets a synchronised
//   copy. The watchdog resets the CPU (wdt_reset_o shows it), not the video.
// Date: 2026-10-02
module video_processor #(
  // video
  parameter int NLANES      = 2,                 // camera D-PHY lanes (1, 2, 4)
  parameter int MAX_W       = 2048,              // longest camera / output line
  parameter int CSI_FIFO    = 2048,              // byte-clock to pixel-clock FIFO, words
  parameter int OUT_FIFO    = 2048,              // output pixel FIFO
  parameter bit SCALER      = 1,                 // include scaler_bilinear
  parameter int DSI_LANES   = 2,                 // MIPI DSI output lanes (1, 2, 4)
  parameter int CSITX_LANES = 2,                 // MIPI CSI-2 output lanes (1, 2, 4)
  // vision_system
  parameter bit VS_USE_EXT_FB = 1'b0,            // frame in external SDRAM (else on chip)
  parameter int VS_ADDR_W   = barrel_pkg::ADDR_W, // on-chip frame buffer address width
  parameter int VS_RET_FIFO = 1024,              // vision_system return FIFO, words
  // blur_sharpen
  parameter int FILT_N      = 5,                 // kernel size (3 or 5)
  // CPU
  parameter int CPU_HZ      = 100_000_000,
  parameter int UART_BAUD   = 115_200,
  parameter int I2C_HZ      = 100_000,
  parameter int SPI_HZ      = 1_000_000,
  parameter logic [23:0] BOOT_ADDR = 24'h00_0000, // firmware image in flash
  parameter int FLASH_CLKDIV = 4
) (
  input  logic                arst_n,
  input  logic                cpu_clk,
  input  logic                pix_clk,
  // ---------------- CPU external interfaces ----------------
  output logic                flash_sclk_o,      // SPI NOR flash (firmware)
  output logic                flash_cs_n_o,
  output logic                flash_mosi_o,
  input  logic                flash_miso_i,
  output logic [1:0]          uart_txd_o,        // UART 0 console, UART 1 host
  input  logic [1:0]          uart_rxd_i,
  input  logic [1:0]          i2c_scl_i,         // I2C 0 camera CCI, I2C 1 DDC / board
  output logic [1:0]          i2c_scl_o,         // (open drain: t = 1 releases)
  output logic [1:0]          i2c_scl_t,
  input  logic [1:0]          i2c_sda_i,
  output logic [1:0]          i2c_sda_o,
  output logic [1:0]          i2c_sda_t,
  output logic [1:0]          spi_sclk_o,        // SPI 0 / SPI 1, 2 chip selects each
  output logic [1:0]          spi_mosi_o,
  input  logic [1:0]          spi_miso_i,
  output logic [3:0]          spi_cs_n_o,
  input  logic [95:0]         gpio_i,            // 3 x 32 GPIO (t = 1: input)
  output logic [95:0]         gpio_o,
  output logic [95:0]         gpio_t,
  input  logic [2:0]          ext_irq_i,         // spare interrupts (intc 13-15), cpu_clk
  output logic                boot_done_o,
  output logic                boot_err_o,
  output logic                cpu_trap_o,
  output logic                wdt_reset_o,
`ifdef VP_CSI2_RX
  // ---------------- MIPI CSI-2 camera: D-PHY RX PPI ----------------
  input  logic                byte_clk,
  input  logic [NLANES*8-1:0] cam_lane_data_i,
  input  logic [NLANES-1:0]   cam_lane_valid_i,
`endif
`ifdef VP_HDMI
  // ---------------- HDMI / DVI: 4 differential output buffers ----------------
  input  logic                tmds_ser_clk,
  output logic [3:0]          tmds_serial_o,     // {clock, ch2, ch1, ch0}
`endif
`ifdef VP_LVDS
  // ---------------- LVDS panel: lanes 0-3 data, lane 4 clock, per link ----------------
  input  logic                lvds_ser_clk,
  output logic [4:0]          lvds_a_serial_o,
  output logic [4:0]          lvds_b_serial_o,   // dual link only, else idle
`endif
`ifdef VP_MIPI_TX
  input  logic                tx_byte_clk,
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
`ifdef VP_VISION
  // ---------------- vision_system frame store (VS_USE_EXT_FB = 1) ----------------
  output wire                 sdram_clk,
  output wire                 sdram_cke,
  output wire                 sdram_cs_n,
  output wire                 sdram_ras_n,
  output wire                 sdram_cas_n,
  output wire                 sdram_we_n,
  output wire [12:0]          sdram_a,
  output wire [1:0]           sdram_ba,
  output wire [7:0]           sdram_dqm,
  inout  wire [63:0]          sdram_dq,
`endif
  output logic                stats_done_o       // pulse (pix_clk): new statistics
);
`ifndef VP_CONFIGURATION_SV
  if (1) begin : g_no_config $error("video_processor: compile src/configuration.sv first (see scripts/build.f)"); end
`endif
`ifdef VP_VISION
  `ifndef VP_INSERT
  if (1) begin : g_no_insert $error("video_processor: VP_VISION needs VP_INSERT (see configuration.sv)"); end
  `endif
`endif

  // ================================================================ resets
  logic cpu_rst_n, pix_rst_n;
  reset_sync u_rst_cpu (.clk(cpu_clk), .arst_i(arst_n), .rst_o(cpu_rst_n));
  reset_sync u_rst_pix (.clk(pix_clk), .arst_i(arst_n), .rst_o(pix_rst_n));
`ifdef VP_CSI2_RX
  logic byte_rst_n;
  reset_sync u_rst_byte (.clk(byte_clk), .arst_i(arst_n), .rst_o(byte_rst_n));
`endif
`ifdef VP_MIPI_TX
  logic tx_byte_rst_n;
  reset_sync u_rst_tx_byte (.clk(tx_byte_clk), .arst_i(arst_n), .rst_o(tx_byte_rst_n));
`endif
`ifdef VP_HDMI
  logic tmds_ser_rst_n;
  reset_sync u_rst_tmds (.clk(tmds_ser_clk), .arst_i(arst_n), .rst_o(tmds_ser_rst_n));
`endif
`ifdef VP_LVDS
  logic lvds_ser_rst_n;
  reset_sync u_rst_lvds (.clk(lvds_ser_clk), .arst_i(arst_n), .rst_o(lvds_ser_rst_n));
`endif

  // ================================================================ control CPU
  logic [15:0] c_awaddr, c_araddr; logic [31:0] c_wdata, c_rdata; logic [3:0] c_wstrb; logic [1:0] c_bresp, c_rresp;
  logic c_awvalid, c_awready, c_wvalid, c_wready, c_bvalid, c_bready, c_arvalid, c_arready, c_rvalid, c_rready;
  logic irq_stats;
  py_soc #(.CLK_HZ(CPU_HZ), .UART_BAUD(UART_BAUD), .I2C_HZ(I2C_HZ), .SPI_HZ(SPI_HZ),
           .BOOT_ADDR(BOOT_ADDR), .FLASH_CLKDIV(FLASH_CLKDIV), .EXT_EN(1'b1)) u_cpu (
    .clk(cpu_clk), .rst_n(cpu_rst_n),
    .start_i(1'b0), .resume_i(1'b0), .resume_pc_i('0),
    .done_o(), .result_o(), .trap_o(cpu_trap_o), .trap_cause_o(), .trap_pc_o(),
    .boot_done_o, .boot_err_o, .boot_err_code_o(),
    .flash_sclk_o, .flash_cs_n_o, .flash_mosi_o, .flash_miso_i,
    .uart_txd_o, .uart_rxd_i,
    .i2c_scl_i, .i2c_scl_o, .i2c_scl_t, .i2c_sda_i, .i2c_sda_o, .i2c_sda_t,
    .spi_sclk_o, .spi_mosi_o, .spi_miso_i, .spi_cs_n_o,
    .gpio_i, .gpio_o, .gpio_t, .wdt_reset_o,
    .ext_irq_i({ext_irq_i, irq_stats}),
    .m_ext_axil_awaddr(c_awaddr), .m_ext_axil_awvalid(c_awvalid), .m_ext_axil_awready(c_awready),
    .m_ext_axil_wdata(c_wdata), .m_ext_axil_wstrb(c_wstrb), .m_ext_axil_wvalid(c_wvalid), .m_ext_axil_wready(c_wready),
    .m_ext_axil_bresp(c_bresp), .m_ext_axil_bvalid(c_bvalid), .m_ext_axil_bready(c_bready),
    .m_ext_axil_araddr(c_araddr), .m_ext_axil_arvalid(c_arvalid), .m_ext_axil_arready(c_arready),
    .m_ext_axil_rdata(c_rdata), .m_ext_axil_rresp(c_rresp), .m_ext_axil_rvalid(c_rvalid), .m_ext_axil_rready(c_rready));

  // isp_stats frame done (pix_clk pulse) -> intc source 12
  pulse_sync u_irq_stats (.src_clk(pix_clk), .src_rst_n(pix_rst_n), .pulse_i(stats_done_o), .busy_o(), .drop_o(),
    .dst_clk(cpu_clk), .dst_rst_n(cpu_rst_n), .pulse_o(irq_stats));

  // ================================================================ control interconnect (pix_clk)
  logic [15:0] v_awaddr, v_araddr; logic [31:0] v_wdata, v_rdata; logic [3:0] v_wstrb; logic [1:0] v_bresp, v_rresp;
  logic v_awvalid, v_awready, v_wvalid, v_wready, v_bvalid, v_bready, v_arvalid, v_arready, v_rvalid, v_rready;
  axi4_lite_cdc #(.ADDR_W(16)) u_axil_cdc (
    .s_clk(cpu_clk), .s_rst_n(cpu_rst_n),
    .s_axil_awaddr(c_awaddr), .s_axil_awvalid(c_awvalid), .s_axil_awready(c_awready),
    .s_axil_wdata(c_wdata), .s_axil_wstrb(c_wstrb), .s_axil_wvalid(c_wvalid), .s_axil_wready(c_wready),
    .s_axil_bresp(c_bresp), .s_axil_bvalid(c_bvalid), .s_axil_bready(c_bready),
    .s_axil_araddr(c_araddr), .s_axil_arvalid(c_arvalid), .s_axil_arready(c_arready),
    .s_axil_rdata(c_rdata), .s_axil_rresp(c_rresp), .s_axil_rvalid(c_rvalid), .s_axil_rready(c_rready),
    .m_clk(pix_clk), .m_rst_n(pix_rst_n),
    .m_axil_awaddr(v_awaddr), .m_axil_awvalid(v_awvalid), .m_axil_awready(v_awready),
    .m_axil_wdata(v_wdata), .m_axil_wstrb(v_wstrb), .m_axil_wvalid(v_wvalid), .m_axil_wready(v_wready),
    .m_axil_bresp(v_bresp), .m_axil_bvalid(v_bvalid), .m_axil_bready(v_bready),
    .m_axil_araddr(v_araddr), .m_axil_arvalid(v_arvalid), .m_axil_arready(v_arready),
    .m_axil_rdata(v_rdata), .m_axil_rresp(v_rresp), .m_axil_rvalid(v_rvalid), .m_axil_rready(v_rready));

  // Slaves: 0 video_pipeline, then vision_system and blur_sharpen when built
`ifdef VP_VISION
  localparam int NV = 1;
`else
  localparam int NV = 0;
`endif
`ifdef VP_FILTER
  localparam int NF = 1;
`else
  localparam int NF = 0;
`endif
  localparam int NS = 1 + NV + NF, S_VS = 1, S_FLT = 1 + NV;
  function automatic logic [NS*32-1:0] bus_map(input bit mask);
    logic [NS*32-1:0] m;
    m[0 +: 32] = mask ? 32'hFFFF_8000 : 32'h0000_0000;                                   // 0x0000-0x7FFF
    if (NV != 0) m[S_VS*32 +: 32]  = mask ? 32'hFFFF_FF00 : 32'h0000_8000;               // 0x8000-0x80FF
    if (NF != 0) m[S_FLT*32 +: 32] = mask ? 32'hFFFF_FE00 : 32'h0000_8200;               // 0x8200-0x83FF
    return m;
  endfunction
  localparam logic [NS*32-1:0] VBASE = bus_map(1'b0);
  localparam logic [NS*32-1:0] VMASK = bus_map(1'b1);
  logic [31:0] b_awaddr, b_araddr, b_wdata; logic [3:0] b_wstrb;
  logic [NS-1:0] b_awvalid, b_awready, b_wvalid, b_wready, b_bvalid, b_bready, b_arvalid, b_arready, b_rvalid, b_rready;
  logic [NS*2-1:0] b_bresp, b_rresp; logic [NS*32-1:0] b_rdata;
  py_axil_xbar #(.NSLAVE(NS), .BASE(VBASE), .MASK(VMASK)) u_vbus (
    .aclk(pix_clk), .aresetn(pix_rst_n),
    .s_axil_awaddr({16'd0, v_awaddr}), .s_axil_awvalid(v_awvalid), .s_axil_awready(v_awready),
    .s_axil_wdata(v_wdata), .s_axil_wstrb(v_wstrb), .s_axil_wvalid(v_wvalid), .s_axil_wready(v_wready),
    .s_axil_bresp(v_bresp), .s_axil_bvalid(v_bvalid), .s_axil_bready(v_bready),
    .s_axil_araddr({16'd0, v_araddr}), .s_axil_arvalid(v_arvalid), .s_axil_arready(v_arready),
    .s_axil_rdata(v_rdata), .s_axil_rresp(v_rresp), .s_axil_rvalid(v_rvalid), .s_axil_rready(v_rready),
    .m_axil_awaddr(b_awaddr), .m_axil_awvalid(b_awvalid), .m_axil_awready(b_awready),
    .m_axil_wdata(b_wdata), .m_axil_wstrb(b_wstrb), .m_axil_wvalid(b_wvalid), .m_axil_wready(b_wready),
    .m_axil_bresp(b_bresp), .m_axil_bvalid(b_bvalid), .m_axil_bready(b_bready),
    .m_axil_araddr(b_araddr), .m_axil_arvalid(b_arvalid), .m_axil_arready(b_arready),
    .m_axil_rdata(b_rdata), .m_axil_rresp(b_rresp), .m_axil_rvalid(b_rvalid), .m_axil_rready(b_rready));

  // ================================================================ video pipeline
`ifdef VP_HDMI
  logic [9:0]  tmds0, tmds1, tmds2, tmds_clk;
`endif
`ifdef VP_LVDS
  logic [27:0] lvds_a, lvds_b; logic [6:0] lvds_clk_word; logic lvds_stb;
`endif
`ifdef VP_INSERT
  logic [23:0] im_d, ir_d; logic im_l, im_u, im_v, im_r, ir_l, ir_u, ir_v, ir_r;
`endif
  video_pipeline #(
    .NLANES(NLANES), .MAX_W(MAX_W), .CSI_FIFO(CSI_FIFO), .OUT_FIFO(OUT_FIFO),
    .SCALER(SCALER), .DSI_LANES(DSI_LANES), .CSITX_LANES(CSITX_LANES)
  ) u_pipe (
`ifdef VP_CSI2_RX
    .byte_clk, .byte_rst_n, .lane_data_i(cam_lane_data_i), .lane_valid_i(cam_lane_valid_i),
`endif
    .pix_clk, .pix_rst_n,
    .s_axil_awaddr(b_awaddr[14:0]), .s_axil_awvalid(b_awvalid[0]), .s_axil_awready(b_awready[0]),
    .s_axil_wdata(b_wdata), .s_axil_wstrb(b_wstrb), .s_axil_wvalid(b_wvalid[0]), .s_axil_wready(b_wready[0]),
    .s_axil_bresp(b_bresp[1:0]), .s_axil_bvalid(b_bvalid[0]), .s_axil_bready(b_bready[0]),
    .s_axil_araddr(b_araddr[14:0]), .s_axil_arvalid(b_arvalid[0]), .s_axil_arready(b_arready[0]),
    .s_axil_rdata(b_rdata[31:0]), .s_axil_rresp(b_rresp[1:0]), .s_axil_rvalid(b_rvalid[0]), .s_axil_rready(b_rready[0]),
`ifdef VP_HDMI
    .tmds0_o(tmds0), .tmds1_o(tmds1), .tmds2_o(tmds2), .tmds_clk_o(tmds_clk),
`endif
`ifdef VP_LVDS
    .lvds_a_o(lvds_a), .lvds_b_o(lvds_b), .lvds_clk_word_o(lvds_clk_word), .lvds_stb_o(lvds_stb),
`endif
`ifdef VP_MIPI_TX
    .tx_byte_clk, .tx_byte_rst_n,
`endif
`ifdef VP_DSI
    .dsi_lane_data_o, .dsi_lane_valid_o, .dsi_hs_req_o, .dsi_tx_ready_i,
`endif
`ifdef VP_CSI2_TX
    .csitx_lane_data_o, .csitx_lane_valid_o, .csitx_hs_req_o, .csitx_tx_ready_i,
`endif
`ifdef VP_INSERT
    .ins_m_axis_tdata(im_d), .ins_m_axis_tlast(im_l), .ins_m_axis_tuser(im_u), .ins_m_axis_tvalid(im_v), .ins_m_axis_tready(im_r),
    .ins_s_axis_tdata(ir_d), .ins_s_axis_tlast(ir_l), .ins_s_axis_tuser(ir_u), .ins_s_axis_tvalid(ir_v), .ins_s_axis_tready(ir_r),
`endif
    .stats_done_o);

  // ================================================================ vision_system at the insert point
`ifdef VP_INSERT
  logic [23:0] vo_d; logic vo_l, vo_u, vo_v, vo_r;   // after vision_system (or straight from the insert point)
`endif
`ifdef VP_VISION
  logic [23:0] va_d, vr_d; logic va_l, va_u, va_v, va_r, vr_l, vr_u, vr_v, vr_r;
  vs_stream_adapter #(.RET_FIFO(VS_RET_FIFO)) u_vs_adapt (.clk(pix_clk), .rst_n(pix_rst_n),
    .s_axis_tdata(im_d), .s_axis_tlast(im_l), .s_axis_tuser(im_u), .s_axis_tvalid(im_v), .s_axis_tready(im_r),
    .m_axis_tdata(va_d), .m_axis_tlast(va_l), .m_axis_tuser(va_u), .m_axis_tvalid(va_v), .m_axis_tready(va_r),
    .r_s_axis_tdata(vr_d), .r_s_axis_tlast(vr_l), .r_s_axis_tuser(vr_u), .r_s_axis_tvalid(vr_v), .r_s_axis_tready(vr_r),
    .r_m_axis_tdata(vo_d), .r_m_axis_tlast(vo_l), .r_m_axis_tuser(vo_u), .r_m_axis_tvalid(vo_v), .r_m_axis_tready(vo_r),
    .frames_o(), .drops_o(), .ret_drops_o());
  vision_system #(.ADDR_W(VS_ADDR_W), .USE_EXT_FB(VS_USE_EXT_FB)) u_vision (
    .clk(pix_clk), .rst_n(pix_rst_n),
    .s_axis_tvalid(va_v), .s_axis_tready(va_r), .s_axis_tdata(va_d), .s_axis_tlast(va_l), .s_axis_tuser(va_u),
    .m_axis_tvalid(vr_v), .m_axis_tready(vr_r), .m_axis_tdata(vr_d), .m_axis_tlast(vr_l), .m_axis_tuser(vr_u),
    .s_axil_awaddr(b_awaddr[7:0]), .s_axil_awvalid(b_awvalid[S_VS]), .s_axil_awready(b_awready[S_VS]),
    .s_axil_wdata(b_wdata), .s_axil_wstrb(b_wstrb), .s_axil_wvalid(b_wvalid[S_VS]), .s_axil_wready(b_wready[S_VS]),
    .s_axil_bresp(b_bresp[S_VS*2 +: 2]), .s_axil_bvalid(b_bvalid[S_VS]), .s_axil_bready(b_bready[S_VS]),
    .s_axil_araddr(b_araddr[7:0]), .s_axil_arvalid(b_arvalid[S_VS]), .s_axil_arready(b_arready[S_VS]),
    .s_axil_rdata(b_rdata[S_VS*32 +: 32]), .s_axil_rresp(b_rresp[S_VS*2 +: 2]), .s_axil_rvalid(b_rvalid[S_VS]), .s_axil_rready(b_rready[S_VS]),
    .sdram_clk, .sdram_cke, .sdram_cs_n, .sdram_ras_n, .sdram_cas_n, .sdram_we_n,
    .sdram_a, .sdram_ba, .sdram_dqm, .sdram_dq);
`elsif VP_INSERT
  assign vo_d = im_d; assign vo_l = im_l; assign vo_u = im_u; assign vo_v = im_v; assign im_r = vo_r;
`endif

  // ================================================================ blur_sharpen after vision_system
`ifdef VP_FILTER
  blur_sharpen #(.N(FILT_N), .C(3), .CW(8), .MAX_W(MAX_W)) u_filter (.clk(pix_clk), .rst_n(pix_rst_n),
    .s_axil_awaddr(b_awaddr[8:0]), .s_axil_awvalid(b_awvalid[S_FLT]), .s_axil_awready(b_awready[S_FLT]),
    .s_axil_wdata(b_wdata), .s_axil_wstrb(b_wstrb), .s_axil_wvalid(b_wvalid[S_FLT]), .s_axil_wready(b_wready[S_FLT]),
    .s_axil_bresp(b_bresp[S_FLT*2 +: 2]), .s_axil_bvalid(b_bvalid[S_FLT]), .s_axil_bready(b_bready[S_FLT]),
    .s_axil_araddr(b_araddr[8:0]), .s_axil_arvalid(b_arvalid[S_FLT]), .s_axil_arready(b_arready[S_FLT]),
    .s_axil_rdata(b_rdata[S_FLT*32 +: 32]), .s_axil_rresp(b_rresp[S_FLT*2 +: 2]), .s_axil_rvalid(b_rvalid[S_FLT]),
    .s_axil_rready(b_rready[S_FLT]),
    .s_axis_tdata(vo_d), .s_axis_tlast(vo_l), .s_axis_tuser(vo_u), .s_axis_tvalid(vo_v), .s_axis_tready(vo_r),
    .m_axis_tdata(ir_d), .m_axis_tlast(ir_l), .m_axis_tuser(ir_u), .m_axis_tvalid(ir_v), .m_axis_tready(ir_r));
`elsif VP_INSERT
  assign ir_d = vo_d; assign ir_l = vo_l; assign ir_u = vo_u; assign ir_v = vo_v; assign vo_r = ir_r;
`endif

  // ================================================================ serializers
`ifdef VP_HDMI
  tmds_serializer u_tmds_ser (
    .pix_clk, .pix_rst_n, .tmds0_i(tmds0), .tmds1_i(tmds1), .tmds2_i(tmds2), .tmds_clk_i(tmds_clk),
    .ser_clk(tmds_ser_clk), .ser_rst_n(tmds_ser_rst_n), .serial_o(tmds_serial_o));
`endif
`ifdef VP_LVDS
  lvds_serializer #(.NL(5)) u_lvds_ser_a (
    .pix_clk, .pix_rst_n, .words_i({lvds_clk_word, lvds_a}), .stb_i(lvds_stb),
    .ser_clk(lvds_ser_clk), .ser_rst_n(lvds_ser_rst_n), .serial_o(lvds_a_serial_o));
  lvds_serializer #(.NL(5)) u_lvds_ser_b (
    .pix_clk, .pix_rst_n, .words_i({lvds_clk_word, lvds_b}), .stb_i(lvds_stb),
    .ser_clk(lvds_ser_clk), .ser_rst_n(lvds_ser_rst_n), .serial_o(lvds_b_serial_o));
`endif
endmodule
