// ***************
// Filename: video_processor.sv
// Author: FPGA Cores 4 U
// Description: Top level of the video processing system (see
//   docs/system_block_diagram.svg). Version 2.0.0. Technology independent:
//   no target device is selected; a board wrapper adds the vendor D-PHY
//   RX / TX, differential buffers and I/O pads. All clocks except the
//   camera byte clock are generated inside from one board reference clock.
//
//     u_cpu        py_soc           CPU system: clock generator (clk_gen,
//                                   two digital PLLs: every clock of the
//                                   design from ref_clk), Python bytecode
//                                   CPU booting from SPI flash, 2x UART,
//                                   2x I2C, 2x SPI, 96 GPIO, intc, watchdog;
//                                   external window 0x1_0000-0x1_FFFF ->
//                                   video registers
//     u_core_up    bit_sync         core logic out of reset (pix_rst_n) ->
//                                   cpu_clk, for the EXT window gate
//     (EXT gate)   inline           passes the CPU's video register window
//                                   to u_axil_cdc only while the core logic
//                                   is out of reset, else answers SLVERR
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
//     g_trk[c].u_track object_tracker x4 detectors (pedestrian, face, automobile, vehicle): box of the object
//                                   pixels in a search window, per frame, for
//                                   the CPU's tracking loop (passive tap after
//                                   blur_sharpen)
//     u_feat       feature_detect_top per-pixel edge and motion features
//                                   shared by the detectors (passive tap
//                                   after blur_sharpen)
//     u_overlay   symbol_overlay   boxes / crosshairs drawn over the video
//                                   (the tracked target: dashed box), last in
//                                   the insert loop
//     u_frame_cnt  frame_counter    frames out of the first pipeline stage
//                                   (csi2_raw_unpack) and into the last one
//                                   (axis_to_video): end-of-frame interrupts
//                                   13 / 14 (bit_sync to cpu_clk) and their
//                                   counts; plus frames into and out of
//                                   vision_system and measured by
//                                   object_tracker; every marker time
//                                   stamped (us) in its event log, so the CPU
//                                   reports them in the order they happened
//     u_irq_stats  pulse_sync       isp_stats frame done -> intc source 12
//     u_tmds_ser   tmds_serializer  10:1 HDMI / DVI
//     u_lvds_ser_a/b lvds_serializer 7:1 LVDS links A / B
//     u_rst_*      reset_sync       one per core clock domain, all from the
//                                   CPU system's core reset output only
//                                   (the CPU clock domain reset comes from
//                                   py_soc, released once its PLL locks)
//
//   CPU address map (src/video_processor_map_pkg.sv, which imports
//   py_soc_map_pkg and video_pipeline_map_pkg; the decoder u_vbus below, the
//   testbench and the firmware read it; mem32[] in the firmware):
//     0x0_0100-0x0_C1FF  py_soc peripherals (see py_soc.sv)
//     0x1_0000-0x1_7FFF  video_pipeline (0x1_4000+ scaler)
//     0x1_8000-0x1_80FF  vision_system (axi_lite_regs)          `VP_VISION
//     0x1_8200-0x1_83FF  blur_sharpen                           `VP_FILTER
//     0x1_8400-0x1_84FF  frame_counter
//     0x1_8500-0x1_85FF  feature_detect: edge / motion features `VP_TRACK
//     0x1_8C00-0x1_8FFF  symbol_overlay                         `VP_TRACK
//     0x1_9000-0x1_97FF  object_tracker x NTRK (4): detectors   `VP_TRACK
//                        0x1_9000 pedestrian, 0x1_9200 face, 0x1_9400
//                        automobile, 0x1_9600 other vehicle
//   While the core logic is in reset (CORE_RESET = 0) every access to
//   0x1_0000-0x1_FFFF completes with SLVERR (read data 0); just after the
//   release an access waits until the core logic is out of reset.
//   Interrupts: intc source 12 = isp_stats frame done (configure it as an
//   edge source), 13 = end of frame at the first pipeline stage, 14 = end of
//   frame at the last stage (frame_counter STATUS, level: write 1 to clear),
//   15 spare (ext_irq_i).
//
//   Configuration (src/configuration.sv): `VP_CSI2_RX, `VP_HDMI, `VP_LVDS,
//   `VP_DSI, `VP_CSI2_TX select the external video interfaces, `VP_VISION
//   adds vision_system, `VP_FILTER blur_sharpen and `VP_TRACK object_tracker
//   with symbol_overlay, all in the video_pipeline insert loop (`VP_INSERT,
//   enabled by CTRL[7]):
//     insert point -> [vs_stream_adapter -> vision_system] -> [blur_sharpen]
//       -> [object_tracker (tap) -> symbol_overlay] -> back
//   With vision_system in the path, keep CTRL.LOCK (genlock) set: there is
//   no frame buffer to repeat a frame, so each display frame waits in
//   vertical blanking for the next corrected frame (the display follows
//   vision_system's output rate, up to LOCK_MAX extra lines). vision_system
//   frames are at most 720 x 720 (barrel_pkg).
//
//   Clocks (defaults; see docs/clock_diagram.svg): ref_clk, the board
//   oscillator, 33.333 MHz (REF_KHZ). py_soc's clock generator makes
//     cpu_clk      = ref x CPU_M / (CPU_D x CPU_O) = x24 / 4 = 200 MHz
//                    (CPU PLL oscillator 800 MHz), CPU and peripherals
//   and, from cpu_clk (video PLL oscillator cpu_clk x VID_M / VID_D = x35
//   = 7 GHz, phase-aligned outputs):
//     pix_clk      = / PIX_O  (70) = 100 MHz, core logic: video pipeline,
//                    registers, vision_system, blur_sharpen, SDRAM
//     tmds_ser_clk = / TMDS_O (7)  = 1 GHz, 10x pix_clk (HDMI 1 Gbit/s)
//     lvds_ser_clk = / LVDS_O (10) = 700 MHz, 7x pix_clk (single link;
//                    dual link 3.5x: LVDS_O = 20)
//     tx_byte_clk  = / TXB_O  (56) = 125 MHz, D-PHY TX (1 Gbit/s per lane)
//   byte_clk (D-PHY RX) is recovered from the camera clock lane: an input.
//   SYSCTL CLK_EN gates each video clock (reset value CLK_EN_RST: core and
//   MIPI byte clocks on, the display serial clocks off until the firmware's
//   video set-up turns them on). CPU peripherals, one parameter set per
//   instance: UART0 console / UART1 host 115200 baud, I2C0 camera CCI
//   400 kHz, I2C1 DDC / EEPROM 100 kHz, SPI0 panel / touch 10 MHz, SPI1
//   ADC / sensors 2 MHz, boot flash 33 MHz (FLASH_CLKDIV 3); FIFOs 16 words.
//   For synthesis the PLL oscillators (dpll_dco) are black boxes: replace
//   them, or clk_gen, with the device PLL / MMCM.
//   Reset: arst_n, external, asynchronous active low, resets the CPU system
//   (py_soc, held until its CPU PLL locks). Its release starts the boot:
//   py_boot loads the firmware from flash, the firmware tests the CPU
//   peripherals and then releases the core logic reset by writing SYSCTL
//   CORE_RESET (py_soc core_rst_n_o, only while the video PLL is locked).
//   Until then every other block (video_pipeline, vision_system,
//   blur_sharpen, frame_counter, serializers) is held in reset: their only
//   reset is the CPU system's reset output core_rst_n_o, synchronised per
//   clock domain (reset_sync). arst_n reaches them through the CPU: it
//   resets py_soc, which clears CORE_RESET (one cpu_clk edge later).
//   core_rst_n_o shows the released state to the board. The watchdog resets
//   the CPU (wdt_reset_o shows it), which clears CORE_RESET and so puts the
//   core logic back into reset until the firmware has booted again.
// Date: 2026-10-15
module video_processor #(
  // video
  parameter int NLANES      = 2,                 // camera D-PHY lanes (1, 2, 4)
  parameter int MAX_W       = 2048,              // longest camera / output line
  parameter int FEAT_MAX_H  = 1152,              // feature_detect: most lines (background cells)
  parameter int FEAT_CELL_LOG2 = 3,              // feature_detect: background cells of 2^n pixels square
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
  // clocks (py_soc clock generator): board reference -> CPU clock -> video clocks
  parameter longint REF_KHZ = 33_333,            // board oscillator, 33.333 MHz
  parameter int CPU_M       = 24,                // CPU PLL: ref x 24 = 800 MHz oscillator
  parameter int CPU_D       = 1,
  parameter int CPU_O       = 4,                 // cpu_clk = 800 / 4 = 200 MHz
  parameter int CPU_HZ      = 200_000_000,       // nominal cpu_clk (peripheral dividers), = the CPU PLL setting
  parameter int VID_M       = 35,                // video PLL: cpu_clk x 35 = 7 GHz oscillator
  parameter int VID_D       = 1,
  parameter int PIX_O       = 70,                // pix_clk (core logic) = 100 MHz
  parameter int TMDS_O      = 7,                 // tmds_ser_clk = 1 GHz (10x)
  parameter int LVDS_O      = 10,                // lvds_ser_clk = 700 MHz (7x single, 20 for dual link 3.5x)
  parameter int TXB_O       = 56,                // tx_byte_clk = 125 MHz
  parameter logic [3:0] CLK_EN_RST = 4'b1001,    // SYSCTL CLK_EN reset: {byte, LVDS, TMDS, core}
  parameter int PLL_MISMATCH_PPM = 0,            // PLL oscillator error (simulation model only)
  // CPU peripherals, one parameter set per instance (FIFOs: py_stream_port words, power of two >= 2)
  parameter int UART0_BAUD    = 115_200,         // UART 0: debug console
  parameter int UART0_TX_FIFO = 16,
  parameter int UART0_RX_FIFO = 16,
  parameter int UART1_BAUD    = 115_200,         // UART 1: host / control link
  parameter int UART1_TX_FIFO = 16,
  parameter int UART1_RX_FIFO = 16,
  parameter int I2C0_HZ       = 400_000,         // I2C 0: camera sensor CCI, fast mode
  parameter int I2C0_TX_FIFO  = 16,
  parameter int I2C0_RX_FIFO  = 16,
  parameter int I2C1_HZ       = 100_000,         // I2C 1: HDMI DDC / EDID, EEPROM, standard mode
  parameter int I2C1_TX_FIFO  = 16,
  parameter int I2C1_RX_FIFO  = 16,
  parameter int SPI0_HZ       = 10_000_000,      // SPI 0: panel initialisation / touch
  parameter int SPI0_DATA_W   = 16,              // max bits per SPI word (<= 24)
  parameter int SPI0_TX_FIFO  = 16,
  parameter int SPI0_RX_FIFO  = 16,
  parameter int SPI1_HZ       = 2_000_000,       // SPI 1: ADC, sensors
  parameter int SPI1_DATA_W   = 16,
  parameter int SPI1_TX_FIFO  = 16,
  parameter int SPI1_RX_FIFO  = 16,
  parameter logic [23:0] BOOT_ADDR = 24'h00_0000, // firmware image in flash
  parameter int CPU_CODE_AW   = 14,              // CPU code memory 2**CPU_CODE_AW bytes (16 KB: firmware with register logging)
  parameter int FLASH_CLKDIV  = 3,               // boot flash sclk = cpu_clk / 6 = 33 MHz
  parameter int FLASH_TX_FIFO = 16,
  parameter int FLASH_RX_FIFO = 16
) (
  input  logic                arst_n,
  input  logic                ref_clk,           // board reference clock (REF_KHZ)
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
  input  logic [0:0]          ext_irq_i,         // spare interrupt (intc 15), cpu_clk
  output logic                boot_done_o,
  output logic                boot_err_o,
  output logic                cpu_trap_o,
  output logic                wdt_reset_o,
  output logic                core_rst_n_o,      // core logic out of reset (released by the CPU)
`ifdef VP_CSI2_RX
  // ---------------- MIPI CSI-2 camera: D-PHY RX PPI ----------------
  input  logic                byte_clk,
  input  logic [NLANES*8-1:0] cam_lane_data_i,
  input  logic [NLANES-1:0]   cam_lane_valid_i,
`endif
`ifdef VP_HDMI
  // ---------------- HDMI / DVI: 4 differential output buffers ----------------
  output logic [3:0]          tmds_serial_o,     // {clock, ch2, ch1, ch0}
`endif
`ifdef VP_LVDS
  // ---------------- LVDS panel: lanes 0-3 data, lane 4 clock, per link ----------------
  output logic [4:0]          lvds_a_serial_o,
  output logic [4:0]          lvds_b_serial_o,   // dual link only, else idle
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
  // CPU_HZ (peripheral dividers, PIX_HZ, TS_DIV) must match the CPU PLL setting (0.1 %: the 33.333 MHz
  // reference gives 199.998 MHz for 200 MHz)
  localparam longint CPU_HZ_PLL = REF_KHZ * 1000 * CPU_M / (CPU_D * CPU_O);
  localparam longint CPU_HZ_ERR = CPU_HZ_PLL > CPU_HZ ? CPU_HZ_PLL - CPU_HZ : longint'(CPU_HZ) - CPU_HZ_PLL;
  if (CPU_HZ_ERR > CPU_HZ / 1000) begin : g_bad_cpu_hz
    $error("video_processor: CPU_HZ does not match REF_KHZ * CPU_M / (CPU_D * CPU_O)");
  end

  // ================================================================ clocks
  // Generated by py_soc's clock generator (clk_gen): see the header
  logic cpu_clk, pix_clk, tmds_ser_clk, lvds_ser_clk, tx_byte_clk;

  // ================================================================ resets
  // CPU system: the external reset. Core logic: only the CPU system's reset output (SYSCTL
  // CORE_RESET, a cpu_clk register that every CPU reset clears), synchronised per clock domain.
  // cpu_rst_n: from py_soc (arst_n, released on cpu_clk once the CPU PLL is locked)
  logic cpu_rst_n, pix_rst_n, core_rel;
  wire  core_arst_n = core_rel;
  assign core_rst_n_o = core_rel;
  reset_sync u_rst_pix (
    .clk(pix_clk),
    .arst_i(core_arst_n),
    .rst_o(pix_rst_n)
  );
`ifdef VP_CSI2_RX
  logic byte_rst_n;
  reset_sync u_rst_byte (
    .clk(byte_clk),
    .arst_i(core_arst_n),
    .rst_o(byte_rst_n)
  );
`endif
`ifdef VP_MIPI_TX
  logic tx_byte_rst_n;
  reset_sync u_rst_tx_byte (
    .clk(tx_byte_clk),
    .arst_i(core_arst_n),
    .rst_o(tx_byte_rst_n)
  );
`endif
`ifdef VP_HDMI
  logic tmds_ser_rst_n;
  reset_sync u_rst_tmds (
    .clk(tmds_ser_clk),
    .arst_i(core_arst_n),
    .rst_o(tmds_ser_rst_n)
  );
`endif
`ifdef VP_LVDS
  logic lvds_ser_rst_n;
  reset_sync u_rst_lvds (
    .clk(lvds_ser_clk),
    .arst_i(core_arst_n),
    .rst_o(lvds_ser_rst_n)
  );
`endif

  // ================================================================ control CPU
  logic [15:0] c_awaddr, c_araddr;
  logic [31:0] c_wdata, c_rdata;
  logic [3:0] c_wstrb;
  logic [1:0] c_bresp, c_rresp;
  logic c_awvalid, c_awready, c_wvalid, c_wready, c_bvalid, c_bready, c_arvalid, c_arready, c_rvalid, c_rready;
  logic irq_stats;
  logic [1:0] irq_frame;
  py_soc #(
    .CLK_HZ(CPU_HZ),
    .UART0_BAUD(UART0_BAUD),
    .UART0_TX_FIFO(UART0_TX_FIFO),
    .UART0_RX_FIFO(UART0_RX_FIFO),
    .UART1_BAUD(UART1_BAUD),
    .UART1_TX_FIFO(UART1_TX_FIFO),
    .UART1_RX_FIFO(UART1_RX_FIFO),
    .I2C0_HZ(I2C0_HZ),
    .I2C0_TX_FIFO(I2C0_TX_FIFO),
    .I2C0_RX_FIFO(I2C0_RX_FIFO),
    .I2C1_HZ(I2C1_HZ),
    .I2C1_TX_FIFO(I2C1_TX_FIFO),
    .I2C1_RX_FIFO(I2C1_RX_FIFO),
    .SPI0_HZ(SPI0_HZ),
    .SPI0_DATA_W(SPI0_DATA_W),
    .SPI0_TX_FIFO(SPI0_TX_FIFO),
    .SPI0_RX_FIFO(SPI0_RX_FIFO),
    .SPI1_HZ(SPI1_HZ),
    .SPI1_DATA_W(SPI1_DATA_W),
    .SPI1_TX_FIFO(SPI1_TX_FIFO),
    .SPI1_RX_FIFO(SPI1_RX_FIFO),
    .FLASH_TX_FIFO(FLASH_TX_FIFO),
    .FLASH_RX_FIFO(FLASH_RX_FIFO),
    .BOOT_ADDR(BOOT_ADDR),
    .CODE_AW(CPU_CODE_AW),
    .STACK_DEPTH(64),                              // the tracking firmware calls deep, an interrupt on top
    .N_FRAMES(24),
    .FLASH_CLKDIV(FLASH_CLKDIV),
    .EXT_EN(1'b1),
    .CLKGEN_EN(1'b1),
    .REF_KHZ(REF_KHZ),
    .CPU_M(CPU_M),
    .CPU_D(CPU_D),
    .CPU_O(CPU_O),
    .CPU_VCO_MIN_KHZ(400_000),
    .CPU_VCO_MAX_KHZ(1_600_000),
    .NCLK(4),
    .CLK_M(VID_M),
    .CLK_D(VID_D),
    .CLK_O({16'(TXB_O), 16'(LVDS_O), 16'(TMDS_O), 16'(PIX_O)}),
    .CLK_VCO_MIN_KHZ(2_500_000),
    .CLK_VCO_MAX_KHZ(7_500_000),
    .CLK_EN_RST(CLK_EN_RST),
    .CPU_MISMATCH_PPM(PLL_MISMATCH_PPM),
    .CLK_MISMATCH_PPM(-PLL_MISMATCH_PPM)
  ) u_cpu (
    .clk(ref_clk),
    .rst_n(arst_n),
    .cpu_clk_o(cpu_clk),
    .cpu_rst_n_o(cpu_rst_n),
    .clk_o({tx_byte_clk, lvds_ser_clk, tmds_ser_clk, pix_clk}),
    .start_i(1'b0),
    .resume_i(1'b0),
    .resume_pc_i('0),
    .done_o(),
    .result_o(),
    .trap_o(cpu_trap_o),
    .trap_cause_o(),
    .trap_pc_o(),
    .boot_done_o,
    .boot_err_o,
    .boot_err_code_o(),
    .flash_sclk_o,
    .flash_cs_n_o,
    .flash_mosi_o,
    .flash_miso_i,
    .uart_txd_o,
    .uart_rxd_i,
    .i2c_scl_i,
    .i2c_scl_o,
    .i2c_scl_t,
    .i2c_sda_i,
    .i2c_sda_o,
    .i2c_sda_t,
    .spi_sclk_o,
    .spi_mosi_o,
    .spi_miso_i,
    .spi_cs_n_o,
    .gpio_i,
    .gpio_o,
    .gpio_t,
    .wdt_reset_o,
    .core_rst_n_o(core_rel),
    .ext_irq_i({ext_irq_i, irq_frame, irq_stats}),
    .m_ext_axil_awaddr(c_awaddr),
    .m_ext_axil_awvalid(c_awvalid),
    .m_ext_axil_awready(c_awready),
    .m_ext_axil_wdata(c_wdata),
    .m_ext_axil_wstrb(c_wstrb),
    .m_ext_axil_wvalid(c_wvalid),
    .m_ext_axil_wready(c_wready),
    .m_ext_axil_bresp(c_bresp),
    .m_ext_axil_bvalid(c_bvalid),
    .m_ext_axil_bready(c_bready),
    .m_ext_axil_araddr(c_araddr),
    .m_ext_axil_arvalid(c_arvalid),
    .m_ext_axil_arready(c_arready),
    .m_ext_axil_rdata(c_rdata),
    .m_ext_axil_rresp(c_rresp),
    .m_ext_axil_rvalid(c_rvalid),
    .m_ext_axil_rready(c_rready)
  );

  // isp_stats frame done (pix_clk pulse) -> intc source 12
  pulse_sync u_irq_stats (
    .src_clk(pix_clk),
    .src_rst_n(pix_rst_n),
    .pulse_i(stats_done_o),
    .busy_o(),
    .drop_o(),
    .dst_clk(cpu_clk),
    .dst_rst_n(cpu_rst_n),
    .pulse_o(irq_stats)
  );

  // ================================================================ EXT window gate (cpu_clk)
  // axi4_lite_cdc needs both of its sides reset together, and its pix_clk side is reset with the core
  // logic (CORE_RESET), not with the CPU. The gate passes the CPU's EXT window to the bridge only while
  // the core logic is out of reset (pix_rst_n, synchronised to cpu_clk: the pix_clk side is released
  // first and reset first) and holds the bridge's cpu_clk side in reset otherwise. Closed while
  // CORE_RESET = 0, it answers every access itself with SLVERR (read data 0), so the CPU never waits on
  // a bridge in reset; an access in flight when the core logic goes into reset completes with SLVERR.
  // Closed while CORE_RESET = 1 (the core logic is being released), a new access waits for the gate to
  // open, as it would have waited in the bridge. It opens only between accesses. (With the core clock
  // gated off by SYSCTL CLK_EN the core logic never leaves reset, and such an access waits forever.)
  logic core_up;                                     // core logic out of reset, in cpu_clk
  logic ext_pass;                                    // gate open: accesses go to the bridge
  logic ext_hold;                                    // gate closed, core logic being released: wait
  logic got_aw, got_w, got_ar;                       // CPU handshakes of the access in flight
  logic [31:0] g_rdata;
  logic [1:0] g_bresp, g_rresp;
  logic g_awvalid, g_awready, g_wvalid, g_wready, g_bvalid, g_bready, g_arvalid, g_arready, g_rvalid, g_rready;
  bit_sync u_core_up (
    .clk(cpu_clk),
    .rst_n(cpu_rst_n),
    .d_i(pix_rst_n),
    .q_o(core_up)
  );
  always_ff @(posedge cpu_clk) begin
    if (!cpu_rst_n) begin
      ext_pass <= 1'b0;
      got_aw <= 1'b0;
      got_w <= 1'b0;
      got_ar <= 1'b0;
    end else begin
      if (c_bvalid && c_bready) begin
        got_aw <= 1'b0;
        got_w <= 1'b0;
      end
      if (c_rvalid && c_rready) got_ar <= 1'b0;
      if (c_awvalid && c_awready) got_aw <= 1'b1;
      if (c_wvalid && c_wready) got_w <= 1'b1;
      if (c_arvalid && c_arready) got_ar <= 1'b1;
      // open only while holding (no CPU handshake can happen in that cycle); close as soon as
      // CORE_RESET clears, before pix_rst_n is even synchronised back
      if (!core_up || !core_rel) ext_pass <= 1'b0;
      else if (!got_aw && !got_w && !got_ar) ext_pass <= 1'b1;
    end
  end
  assign ext_hold  = !ext_pass && core_rel && !got_aw && !got_w && !got_ar;
  assign g_awvalid = c_awvalid && ext_pass;
  assign g_wvalid  = c_wvalid && ext_pass;
  assign g_bready  = c_bready && ext_pass;
  assign g_arvalid = c_arvalid && ext_pass;
  assign g_rready  = c_rready && ext_pass;
  assign c_awready = ext_pass ? g_awready : !ext_hold && !got_aw;
  assign c_wready  = ext_pass ? g_wready : !ext_hold && !got_w;
  assign c_bvalid  = ext_pass ? g_bvalid : got_aw && got_w;
  assign c_bresp   = ext_pass ? g_bresp : 2'b10;     // SLVERR
  assign c_arready = ext_pass ? g_arready : !ext_hold && !got_ar;
  assign c_rvalid  = ext_pass ? g_rvalid : got_ar;
  assign c_rdata   = ext_pass ? g_rdata : 32'd0;
  assign c_rresp   = ext_pass ? g_rresp : 2'b10;     // SLVERR

  // ================================================================ control interconnect (pix_clk)
  logic [15:0] v_awaddr, v_araddr;
  logic [31:0] v_wdata, v_rdata;
  logic [3:0] v_wstrb;
  logic [1:0] v_bresp, v_rresp;
  logic v_awvalid, v_awready, v_wvalid, v_wready, v_bvalid, v_bready, v_arvalid, v_arready, v_rvalid, v_rready;
  axi4_lite_cdc #(.ADDR_W(16)) u_axil_cdc (
    .s_clk(cpu_clk),
    .s_rst_n(cpu_rst_n && ext_pass),                 // reset while the gate is closed
    .s_axil_awaddr(c_awaddr),
    .s_axil_awvalid(g_awvalid),
    .s_axil_awready(g_awready),
    .s_axil_wdata(c_wdata),
    .s_axil_wstrb(c_wstrb),
    .s_axil_wvalid(g_wvalid),
    .s_axil_wready(g_wready),
    .s_axil_bresp(g_bresp),
    .s_axil_bvalid(g_bvalid),
    .s_axil_bready(g_bready),
    .s_axil_araddr(c_araddr),
    .s_axil_arvalid(g_arvalid),
    .s_axil_arready(g_arready),
    .s_axil_rdata(g_rdata),
    .s_axil_rresp(g_rresp),
    .s_axil_rvalid(g_rvalid),
    .s_axil_rready(g_rready),
    .m_clk(pix_clk),
    .m_rst_n(pix_rst_n),
    .m_axil_awaddr(v_awaddr),
    .m_axil_awvalid(v_awvalid),
    .m_axil_awready(v_awready),
    .m_axil_wdata(v_wdata),
    .m_axil_wstrb(v_wstrb),
    .m_axil_wvalid(v_wvalid),
    .m_axil_wready(v_wready),
    .m_axil_bresp(v_bresp),
    .m_axil_bvalid(v_bvalid),
    .m_axil_bready(v_bready),
    .m_axil_araddr(v_araddr),
    .m_axil_arvalid(v_arvalid),
    .m_axil_arready(v_arready),
    .m_axil_rdata(v_rdata),
    .m_axil_rresp(v_rresp),
    .m_axil_rvalid(v_rvalid),
    .m_axil_rready(v_rready)
  );

  // Slaves: 0 video_pipeline, then vision_system and blur_sharpen when built, then frame_counter, then
  // object_tracker x NTRK, symbol_overlay and feature_detect when built
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
`ifdef VP_TRACK
  localparam int NT = 1;
`else
  localparam int NT = 0;
`endif
  localparam int NTRK = video_processor_map_pkg::NTRK;   // object_tracker detectors (one per object class)
  localparam int NS = 2 + NV + NF + (NTRK + 2) * NT, S_VS = 1, S_FLT = 1 + NV, S_FC = 1 + NV + NF, S_TRK = 2 + NV + NF,
                 S_OVL = 2 + NV + NF + NTRK, S_FEAT = 3 + NV + NF + NTRK;
  // windows from the memory map package (src/video_processor_map_pkg.sv); the optional windows are
  // compiled only with their block, so no part-select of an unbuilt slave is out of range
  function automatic logic [NS*32-1:0] bus_map(input bit mask);
    logic [NS*32-1:0] m;
    m[0 +: 32] = mask ? video_processor_map_pkg::VP_MASK : video_processor_map_pkg::VP_OFFSET;
`ifdef VP_VISION
    m[S_VS*32 +: 32]  = mask ? video_processor_map_pkg::VS_MASK : video_processor_map_pkg::VS_OFFSET;
`endif
`ifdef VP_FILTER
    m[S_FLT*32 +: 32] = mask ? video_processor_map_pkg::FLT_MASK : video_processor_map_pkg::FLT_OFFSET;
`endif
    m[S_FC*32 +: 32] = mask ? video_processor_map_pkg::FC_MASK : video_processor_map_pkg::FC_OFFSET;
`ifdef VP_TRACK
    for (int c = 0; c < NTRK; c++)
      m[(S_TRK + c)*32 +: 32] = mask ? video_processor_map_pkg::TRK_MASK
                                     : video_processor_map_pkg::TRK_OFFSET + 32'(c) * video_processor_map_pkg::TRK_STRIDE;
    m[S_OVL*32 +: 32] = mask ? video_processor_map_pkg::OVL_MASK : video_processor_map_pkg::OVL_OFFSET;
    m[S_FEAT*32 +: 32] = mask ? video_processor_map_pkg::FEAT_MASK : video_processor_map_pkg::FEAT_OFFSET;
`endif
    return m;
  endfunction
  localparam logic [NS*32-1:0] VBASE = bus_map(1'b0);
  localparam logic [NS*32-1:0] VMASK = bus_map(1'b1);
  logic [31:0] b_awaddr, b_araddr, b_wdata;
  logic [3:0] b_wstrb;
  logic [NS-1:0] b_awvalid, b_awready, b_wvalid, b_wready, b_bvalid, b_bready, b_arvalid, b_arready, b_rvalid, b_rready;
  logic [NS*2-1:0] b_bresp, b_rresp;
  logic [NS*32-1:0] b_rdata;
  py_axil_xbar #(
    .NSLAVE(NS),
    .BASE(VBASE),
    .MASK(VMASK)
  ) u_vbus (
    .aclk(pix_clk),
    .aresetn(pix_rst_n),
    .s_axil_awaddr({16'd0, v_awaddr}),
    .s_axil_awvalid(v_awvalid),
    .s_axil_awready(v_awready),
    .s_axil_wdata(v_wdata),
    .s_axil_wstrb(v_wstrb),
    .s_axil_wvalid(v_wvalid),
    .s_axil_wready(v_wready),
    .s_axil_bresp(v_bresp),
    .s_axil_bvalid(v_bvalid),
    .s_axil_bready(v_bready),
    .s_axil_araddr({16'd0, v_araddr}),
    .s_axil_arvalid(v_arvalid),
    .s_axil_arready(v_arready),
    .s_axil_rdata(v_rdata),
    .s_axil_rresp(v_rresp),
    .s_axil_rvalid(v_rvalid),
    .s_axil_rready(v_rready),
    .m_axil_awaddr(b_awaddr),
    .m_axil_awvalid(b_awvalid),
    .m_axil_awready(b_awready),
    .m_axil_wdata(b_wdata),
    .m_axil_wstrb(b_wstrb),
    .m_axil_wvalid(b_wvalid),
    .m_axil_wready(b_wready),
    .m_axil_bresp(b_bresp),
    .m_axil_bvalid(b_bvalid),
    .m_axil_bready(b_bready),
    .m_axil_araddr(b_araddr),
    .m_axil_arvalid(b_arvalid),
    .m_axil_arready(b_arready),
    .m_axil_rdata(b_rdata),
    .m_axil_rresp(b_rresp),
    .m_axil_rvalid(b_rvalid),
    .m_axil_rready(b_rready)
  );

  // ================================================================ video pipeline
`ifdef VP_HDMI
  logic [9:0]  tmds0, tmds1, tmds2, tmds_clk;
`endif
`ifdef VP_LVDS
  logic [27:0] lvds_a, lvds_b;
  logic [6:0] lvds_clk_word;
  logic lvds_stb;
`endif
`ifdef VP_INSERT
  logic [23:0] im_d, ir_d;
  logic im_l, im_u, im_v, im_r, ir_l, ir_u, ir_v, ir_r;
`endif
  logic eof_first, eof_last;                         // end-of-frame markers of the first / last stage
  video_pipeline #(
    .NLANES(NLANES),
    .MAX_W(MAX_W),
    .CSI_FIFO(CSI_FIFO),
    .OUT_FIFO(OUT_FIFO),
    .SCALER(SCALER),
    .DSI_LANES(DSI_LANES),
    .CSITX_LANES(CSITX_LANES)
  ) u_pipe (
`ifdef VP_CSI2_RX
    .byte_clk,
    .byte_rst_n,
    .lane_data_i(cam_lane_data_i),
    .lane_valid_i(cam_lane_valid_i),
`endif
    .pix_clk,
    .pix_rst_n,
    .s_axil_awaddr(b_awaddr[14:0]),
    .s_axil_awvalid(b_awvalid[0]),
    .s_axil_awready(b_awready[0]),
    .s_axil_wdata(b_wdata),
    .s_axil_wstrb(b_wstrb),
    .s_axil_wvalid(b_wvalid[0]),
    .s_axil_wready(b_wready[0]),
    .s_axil_bresp(b_bresp[1:0]),
    .s_axil_bvalid(b_bvalid[0]),
    .s_axil_bready(b_bready[0]),
    .s_axil_araddr(b_araddr[14:0]),
    .s_axil_arvalid(b_arvalid[0]),
    .s_axil_arready(b_arready[0]),
    .s_axil_rdata(b_rdata[31:0]),
    .s_axil_rresp(b_rresp[1:0]),
    .s_axil_rvalid(b_rvalid[0]),
    .s_axil_rready(b_rready[0]),
`ifdef VP_HDMI
    .tmds0_o(tmds0),
    .tmds1_o(tmds1),
    .tmds2_o(tmds2),
    .tmds_clk_o(tmds_clk),
`endif
`ifdef VP_LVDS
    .lvds_a_o(lvds_a),
    .lvds_b_o(lvds_b),
    .lvds_clk_word_o(lvds_clk_word),
    .lvds_stb_o(lvds_stb),
`endif
`ifdef VP_MIPI_TX
    .tx_byte_clk,
    .tx_byte_rst_n,
`endif
`ifdef VP_DSI
    .dsi_lane_data_o,
    .dsi_lane_valid_o,
    .dsi_hs_req_o,
    .dsi_tx_ready_i,
`endif
`ifdef VP_CSI2_TX
    .csitx_lane_data_o,
    .csitx_lane_valid_o,
    .csitx_hs_req_o,
    .csitx_tx_ready_i,
`endif
`ifdef VP_INSERT
    .ins_m_axis_tdata(im_d),
    .ins_m_axis_tlast(im_l),
    .ins_m_axis_tuser(im_u),
    .ins_m_axis_tvalid(im_v),
    .ins_m_axis_tready(im_r),
    .ins_s_axis_tdata(ir_d),
    .ins_s_axis_tlast(ir_l),
    .ins_s_axis_tuser(ir_u),
    .ins_s_axis_tvalid(ir_v),
    .ins_s_axis_tready(ir_r),
`endif
    .eof_in_o(eof_first),
    .eof_out_o(eof_last),
    .stats_done_o);

  // ================================================================ frame counters
  // Interrupt levels (pix_clk) synchronised to cpu_clk; the CPU clears them through STATUS. Channels,
  // in pipeline order: 0 end of frame out of csi2_raw_unpack (interrupt 13), 2 frame admitted into
  // vision_system (start of frame), 3 corrected frame out of vision_system (start of frame), 4
  // object_tracker measured a frame (end of frame after blur_sharpen), 1 end of frame into
  // axis_to_video (interrupt 14). Every channel's markers can go to the event log (EV_EN), time
  // stamped in microseconds, so the CPU reports the events in the order they happened.
  localparam longint PIX_HZ = longint'(CPU_HZ) * VID_M / (VID_D * PIX_O);
  localparam int TS_DIV = (PIX_HZ + 500_000) / 1_000_000;                   // pix_clk ticks per microsecond
  logic [4:0] irq_frame_pix;
  logic ev_vs_in, ev_vs_out, ev_trk;                 // driven below (0 when the block is not built)
`ifndef VP_INSERT
  assign ev_vs_in = 1'b0;
  assign ev_vs_out = 1'b0;
  assign ev_trk = 1'b0;
`endif
  frame_counter_top #(
    .NCH(5),
    .EVQ(128),
    .TS_DIV(TS_DIV < 1 ? 1 : TS_DIV)
  ) u_frame_cnt (
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .eof_i({ev_trk, ev_vs_out, ev_vs_in, eof_last, eof_first}),
    .irq_o(irq_frame_pix),
    .s_axil_awaddr(b_awaddr[7:0]),
    .s_axil_awvalid(b_awvalid[S_FC]),
    .s_axil_awready(b_awready[S_FC]),
    .s_axil_wdata(b_wdata),
    .s_axil_wstrb(b_wstrb),
    .s_axil_wvalid(b_wvalid[S_FC]),
    .s_axil_wready(b_wready[S_FC]),
    .s_axil_bresp(b_bresp[S_FC*2 +: 2]),
    .s_axil_bvalid(b_bvalid[S_FC]),
    .s_axil_bready(b_bready[S_FC]),
    .s_axil_araddr(b_araddr[7:0]),
    .s_axil_arvalid(b_arvalid[S_FC]),
    .s_axil_arready(b_arready[S_FC]),
    .s_axil_rdata(b_rdata[S_FC*32 +: 32]),
    .s_axil_rresp(b_rresp[S_FC*2 +: 2]),
    .s_axil_rvalid(b_rvalid[S_FC]),
    .s_axil_rready(b_rready[S_FC])
  );
  // Levels: after the CPU's STATUS write-1-to-clear completes (B response), the level takes about 2
  // more cpu_clk cycles to drop at the intc. The handler must not return right after the clear: it
  // reads STATUS back first (sw/video_proc.py isr), or it could see the stale level and re-enter once.
  bit_sync u_irq_frame0 (
    .clk(cpu_clk),
    .rst_n(cpu_rst_n),
    .d_i(irq_frame_pix[0]),
    .q_o(irq_frame[0])
  );
  bit_sync u_irq_frame1 (
    .clk(cpu_clk),
    .rst_n(cpu_rst_n),
    .d_i(irq_frame_pix[1]),
    .q_o(irq_frame[1])
  );

  // ================================================================ vision_system at the insert point
`ifdef VP_INSERT
  logic [23:0] vo_d; // after vision_system (or straight from the insert point)
  logic vo_l, vo_u, vo_v, vo_r;
`endif
`ifdef VP_VISION
  logic [23:0] va_d, vr_d;
  logic va_l, va_u, va_v, va_r, vr_l, vr_u, vr_v, vr_r;
  vs_stream_adapter #(
    .GAP(barrel_pkg::LINE_GAP_CYCLES + 3),
    .RET_FIFO(VS_RET_FIFO)
  ) u_vs_adapt (
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .s_axis_tdata(im_d),
    .s_axis_tlast(im_l),
    .s_axis_tuser(im_u),
    .s_axis_tvalid(im_v),
    .s_axis_tready(im_r),
    .m_axis_tdata(va_d),
    .m_axis_tlast(va_l),
    .m_axis_tuser(va_u),
    .m_axis_tvalid(va_v),
    .m_axis_tready(va_r),
    .r_s_axis_tdata(vr_d),
    .r_s_axis_tlast(vr_l),
    .r_s_axis_tuser(vr_u),
    .r_s_axis_tvalid(vr_v),
    .r_s_axis_tready(vr_r),
    .r_m_axis_tdata(vo_d),
    .r_m_axis_tlast(vo_l),
    .r_m_axis_tuser(vo_u),
    .r_m_axis_tvalid(vo_v),
    .r_m_axis_tready(vo_r),
    .frames_o(),
    .drops_o(),
    .ret_drops_o()
  );
  assign ev_vs_in = va_v && va_r && va_u;           // frame admitted into vision_system
  assign ev_vs_out = vr_v && vr_r && vr_u;          // corrected frame starts coming out
  vision_system #(
    .ADDR_W(VS_ADDR_W),
    .USE_EXT_FB(VS_USE_EXT_FB)
  ) u_vision (
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .s_axis_tvalid(va_v),
    .s_axis_tready(va_r),
    .s_axis_tdata(va_d),
    .s_axis_tlast(va_l),
    .s_axis_tuser(va_u),
    .m_axis_tvalid(vr_v),
    .m_axis_tready(vr_r),
    .m_axis_tdata(vr_d),
    .m_axis_tlast(vr_l),
    .m_axis_tuser(vr_u),
    .s_axil_awaddr(b_awaddr[7:0]),
    .s_axil_awvalid(b_awvalid[S_VS]),
    .s_axil_awready(b_awready[S_VS]),
    .s_axil_wdata(b_wdata),
    .s_axil_wstrb(b_wstrb),
    .s_axil_wvalid(b_wvalid[S_VS]),
    .s_axil_wready(b_wready[S_VS]),
    .s_axil_bresp(b_bresp[S_VS*2 +: 2]),
    .s_axil_bvalid(b_bvalid[S_VS]),
    .s_axil_bready(b_bready[S_VS]),
    .s_axil_araddr(b_araddr[7:0]),
    .s_axil_arvalid(b_arvalid[S_VS]),
    .s_axil_arready(b_arready[S_VS]),
    .s_axil_rdata(b_rdata[S_VS*32 +: 32]),
    .s_axil_rresp(b_rresp[S_VS*2 +: 2]),
    .s_axil_rvalid(b_rvalid[S_VS]),
    .s_axil_rready(b_rready[S_VS]),
    .sdram_clk,
    .sdram_cke,
    .sdram_cs_n,
    .sdram_ras_n,
    .sdram_cas_n,
    .sdram_we_n,
    .sdram_a,
    .sdram_ba,
    .sdram_dqm,
    .sdram_dq
  );
`elsif VP_INSERT
  assign ev_vs_in = 1'b0;
  assign ev_vs_out = 1'b0;
  assign vo_d = im_d;
  assign vo_l = im_l;
  assign vo_u = im_u;
  assign vo_v = im_v;
  assign im_r = vo_r;
`endif

  // ================================================================ blur_sharpen after vision_system
`ifdef VP_INSERT
  logic [23:0] fo_d; // after blur_sharpen (or straight from vision_system)
  logic fo_l, fo_u, fo_v, fo_r;
`endif
`ifdef VP_FILTER
  blur_sharpen_top #(.N(FILT_N), .C(3), .CW(8), .MAX_W(MAX_W)) u_filter (.clk(pix_clk), .rst_n(pix_rst_n),
    .s_axil_awaddr(b_awaddr[8:0]), .s_axil_awvalid(b_awvalid[S_FLT]), .s_axil_awready(b_awready[S_FLT]),
    .s_axil_wdata(b_wdata), .s_axil_wstrb(b_wstrb), .s_axil_wvalid(b_wvalid[S_FLT]), .s_axil_wready(b_wready[S_FLT]),
    .s_axil_bresp(b_bresp[S_FLT*2 +: 2]), .s_axil_bvalid(b_bvalid[S_FLT]), .s_axil_bready(b_bready[S_FLT]),
    .s_axil_araddr(b_araddr[8:0]), .s_axil_arvalid(b_arvalid[S_FLT]), .s_axil_arready(b_arready[S_FLT]),
    .s_axil_rdata(b_rdata[S_FLT*32 +: 32]), .s_axil_rresp(b_rresp[S_FLT*2 +: 2]), .s_axil_rvalid(b_rvalid[S_FLT]),
    .s_axil_rready(b_rready[S_FLT]),
    .s_axis_tdata(vo_d), .s_axis_tlast(vo_l), .s_axis_tuser(vo_u), .s_axis_tvalid(vo_v), .s_axis_tready(vo_r),
    .m_axis_tdata(fo_d), .m_axis_tlast(fo_l), .m_axis_tuser(fo_u), .m_axis_tvalid(fo_v), .m_axis_tready(fo_r));
`elsif VP_INSERT
  assign fo_d = vo_d;
  assign fo_l = vo_l;
  assign fo_u = vo_u;
  assign fo_v = vo_v;
  assign vo_r = fo_r;
`endif

  // ================================================================ target tracking and symbol overlay
  // object_tracker watches the filtered video (before any symbol is drawn); symbol_overlay draws the
  // CPU's symbols over it, last in the insert loop.
`ifdef VP_TRACK
  // one detector per object class (0 pedestrian, 1 face, 2 automobile, 3 other vehicle), each in its
  // own window (video_processor_map_pkg: TRK_OFFSET + c * TRK_STRIDE); all watch the same frames, so
  // the enabled ones' done_o pulse together: any of them marks the tracker event
  logic [NTRK-1:0] trk_done;
  assign ev_trk = |trk_done;
  // edge and motion features of every pixel, computed once for all the detectors (passive tap on the
  // same stream; the bits belong to the beat they come with)
  logic [1:0] feat;
  feature_detect_top #(
    .MAXW(MAX_W),
    .MAXH(FEAT_MAX_H),
    .CELL_LOG2(FEAT_CELL_LOG2)
  ) u_feat (
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .s_axis_tdata(fo_d),
    .s_axis_tlast(fo_l),
    .s_axis_tuser(fo_u),
    .s_axis_tvalid(fo_v),
    .s_axis_tready(fo_r),
    .feat_o(feat),
    .done_o(),
    .s_axil_awaddr(b_awaddr[7:0]),
    .s_axil_awvalid(b_awvalid[S_FEAT]),
    .s_axil_awready(b_awready[S_FEAT]),
    .s_axil_wdata(b_wdata),
    .s_axil_wstrb(b_wstrb),
    .s_axil_wvalid(b_wvalid[S_FEAT]),
    .s_axil_wready(b_wready[S_FEAT]),
    .s_axil_bresp(b_bresp[S_FEAT*2 +: 2]),
    .s_axil_bvalid(b_bvalid[S_FEAT]),
    .s_axil_bready(b_bready[S_FEAT]),
    .s_axil_araddr(b_araddr[7:0]),
    .s_axil_arvalid(b_arvalid[S_FEAT]),
    .s_axil_arready(b_arready[S_FEAT]),
    .s_axil_rdata(b_rdata[S_FEAT*32 +: 32]),
    .s_axil_rresp(b_rresp[S_FEAT*2 +: 2]),
    .s_axil_rvalid(b_rvalid[S_FEAT]),
    .s_axil_rready(b_rready[S_FEAT])
  );
  for (genvar c = 0; c < NTRK; c++) begin : g_trk
    object_tracker_top u_track (
      .clk(pix_clk),
      .rst_n(pix_rst_n),
      .feat_i(feat),
      .s_axis_tdata(fo_d),
      .s_axis_tlast(fo_l),
      .s_axis_tuser(fo_u),
      .s_axis_tvalid(fo_v),
      .s_axis_tready(fo_r),
      .done_o(trk_done[c]),
      .s_axil_awaddr(b_awaddr[8:0]),
      .s_axil_awvalid(b_awvalid[S_TRK + c]),
      .s_axil_awready(b_awready[S_TRK + c]),
      .s_axil_wdata(b_wdata),
      .s_axil_wstrb(b_wstrb),
      .s_axil_wvalid(b_wvalid[S_TRK + c]),
      .s_axil_wready(b_wready[S_TRK + c]),
      .s_axil_bresp(b_bresp[(S_TRK + c)*2 +: 2]),
      .s_axil_bvalid(b_bvalid[S_TRK + c]),
      .s_axil_bready(b_bready[S_TRK + c]),
      .s_axil_araddr(b_araddr[8:0]),
      .s_axil_arvalid(b_arvalid[S_TRK + c]),
      .s_axil_arready(b_arready[S_TRK + c]),
      .s_axil_rdata(b_rdata[(S_TRK + c)*32 +: 32]),
      .s_axil_rresp(b_rresp[(S_TRK + c)*2 +: 2]),
      .s_axil_rvalid(b_rvalid[S_TRK + c]),
      .s_axil_rready(b_rready[S_TRK + c])
    );
  end
  symbol_overlay_top #(
    .NOBJ(12),                                       // 3 target boxes per class (object 3c + k)
    .NTXT(4)
  ) u_overlay (
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .s_axis_tdata(fo_d),
    .s_axis_tlast(fo_l),
    .s_axis_tuser(fo_u),
    .s_axis_tvalid(fo_v),
    .s_axis_tready(fo_r),
    .m_axis_tdata(ir_d),
    .m_axis_tlast(ir_l),
    .m_axis_tuser(ir_u),
    .m_axis_tvalid(ir_v),
    .m_axis_tready(ir_r),
    .s_axil_awaddr(b_awaddr[9:0]),
    .s_axil_awvalid(b_awvalid[S_OVL]),
    .s_axil_awready(b_awready[S_OVL]),
    .s_axil_wdata(b_wdata),
    .s_axil_wstrb(b_wstrb),
    .s_axil_wvalid(b_wvalid[S_OVL]),
    .s_axil_wready(b_wready[S_OVL]),
    .s_axil_bresp(b_bresp[S_OVL*2 +: 2]),
    .s_axil_bvalid(b_bvalid[S_OVL]),
    .s_axil_bready(b_bready[S_OVL]),
    .s_axil_araddr(b_araddr[9:0]),
    .s_axil_arvalid(b_arvalid[S_OVL]),
    .s_axil_arready(b_arready[S_OVL]),
    .s_axil_rdata(b_rdata[S_OVL*32 +: 32]),
    .s_axil_rresp(b_rresp[S_OVL*2 +: 2]),
    .s_axil_rvalid(b_rvalid[S_OVL]),
    .s_axil_rready(b_rready[S_OVL])
  );
`elsif VP_INSERT
  assign ev_trk = 1'b0;
  assign ir_d = fo_d;
  assign ir_l = fo_l;
  assign ir_u = fo_u;
  assign ir_v = fo_v;
  assign fo_r = ir_r;
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
    .pix_clk,
    .pix_rst_n,
    .words_i({lvds_clk_word, lvds_b}),
    .stb_i(lvds_stb),
    .ser_clk(lvds_ser_clk),
    .ser_rst_n(lvds_ser_rst_n),
    .serial_o(lvds_b_serial_o)
  );
`endif
endmodule
