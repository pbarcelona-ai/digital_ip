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
  axil_if #(.ADDR_W(16), .DATA_W(32)) c ();
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
    .m_ext_axil(c)
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
      if (c.bvalid && c.bready) begin
        got_aw <= 1'b0;
        got_w <= 1'b0;
      end
      if (c.rvalid && c.rready) got_ar <= 1'b0;
      if (c.awvalid && c.awready) got_aw <= 1'b1;
      if (c.wvalid && c.wready) got_w <= 1'b1;
      if (c.arvalid && c.arready) got_ar <= 1'b1;
      // open only while holding (no CPU handshake can happen in that cycle); close as soon as
      // CORE_RESET clears, before pix_rst_n is even synchronised back
      if (!core_up || !core_rel) ext_pass <= 1'b0;
      else if (!got_aw && !got_w && !got_ar) ext_pass <= 1'b1;
    end
  end
  assign ext_hold  = !ext_pass && core_rel && !got_aw && !got_w && !got_ar;
  assign g_awvalid = c.awvalid && ext_pass;
  assign g_wvalid  = c.wvalid && ext_pass;
  assign g_bready  = c.bready && ext_pass;
  assign g_arvalid = c.arvalid && ext_pass;
  assign g_rready  = c.rready && ext_pass;
  assign c.awready = ext_pass ? g_awready : !ext_hold && !got_aw;
  assign c.wready  = ext_pass ? g_wready : !ext_hold && !got_w;
  assign c.bvalid  = ext_pass ? g_bvalid : got_aw && got_w;
  assign c.bresp   = ext_pass ? g_bresp : 2'b10;     // SLVERR
  assign c.arready = ext_pass ? g_arready : !ext_hold && !got_ar;
  assign c.rvalid  = ext_pass ? g_rvalid : got_ar;
  assign c.rdata   = ext_pass ? g_rdata : 32'd0;
  assign c.rresp   = ext_pass ? g_rresp : 2'b10;     // SLVERR

  // ================================================================ control interconnect (pix_clk)
  axil_if #(.ADDR_W(16), .DATA_W(32)) v ();
  axil_if #(.ADDR_W(16)) u_axil_cdc_s_axil ();
  assign u_axil_cdc_s_axil.awaddr = c.awaddr;
  assign u_axil_cdc_s_axil.awvalid = g_awvalid;
  assign g_awready = u_axil_cdc_s_axil.awready;
  assign u_axil_cdc_s_axil.wdata = c.wdata;
  assign u_axil_cdc_s_axil.wstrb = c.wstrb;
  assign u_axil_cdc_s_axil.wvalid = g_wvalid;
  assign g_wready = u_axil_cdc_s_axil.wready;
  assign g_bresp = u_axil_cdc_s_axil.bresp;
  assign g_bvalid = u_axil_cdc_s_axil.bvalid;
  assign u_axil_cdc_s_axil.bready = g_bready;
  assign u_axil_cdc_s_axil.araddr = c.araddr;
  assign u_axil_cdc_s_axil.arvalid = g_arvalid;
  assign g_arready = u_axil_cdc_s_axil.arready;
  assign g_rdata = u_axil_cdc_s_axil.rdata;
  assign g_rresp = u_axil_cdc_s_axil.rresp;
  assign g_rvalid = u_axil_cdc_s_axil.rvalid;
  assign u_axil_cdc_s_axil.rready = g_rready;
  axi4_lite_cdc #(.ADDR_W(16)) u_axil_cdc (
    .s_clk(cpu_clk),
    .s_rst_n(cpu_rst_n && ext_pass),
    .s_axil(u_axil_cdc_s_axil),
    .m_clk(pix_clk),
    .m_rst_n(pix_rst_n),
    .m_axil(v)
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
  axil_if #(.ADDR_W(32), .DATA_W(32)) b ();
  axil_if #(.ADDR_W(32)) u_vbus_s_axil ();
  assign u_vbus_s_axil.awaddr = {16'd0, v.awaddr};
  assign u_vbus_s_axil.awvalid = v.awvalid;
  assign v.awready = u_vbus_s_axil.awready;
  assign u_vbus_s_axil.wdata = v.wdata;
  assign u_vbus_s_axil.wstrb = v.wstrb;
  assign u_vbus_s_axil.wvalid = v.wvalid;
  assign v.wready = u_vbus_s_axil.wready;
  assign v.bresp = u_vbus_s_axil.bresp;
  assign v.bvalid = u_vbus_s_axil.bvalid;
  assign u_vbus_s_axil.bready = v.bready;
  assign u_vbus_s_axil.araddr = {16'd0, v.araddr};
  assign u_vbus_s_axil.arvalid = v.arvalid;
  assign v.arready = u_vbus_s_axil.arready;
  assign v.rdata = u_vbus_s_axil.rdata;
  assign v.rresp = u_vbus_s_axil.rresp;
  assign v.rvalid = u_vbus_s_axil.rvalid;
  assign u_vbus_s_axil.rready = v.rready;
  py_axil_xbar #(
    .NSLAVE(NS),
    .BASE(VBASE),
    .MASK(VMASK)
  ) u_vbus (
    .aclk(pix_clk),
    .aresetn(pix_rst_n),
    .s_axil(u_vbus_s_axil),
    .m_axil(b)
  );

  // ================================================================ video pipeline
`ifdef VP_HDMI
  tmds_if tmds ();
`endif
`ifdef VP_LVDS
  logic [27:0] lvds_a, lvds_b;
  logic [6:0] lvds_clk_word;
  logic lvds_stb;
`endif
`ifdef VP_INSERT
  axis_if #(.DATA_W(24), .USER_W(1)) ir ();
  logic [23:0] im_d;
  axis_if #(.DATA_W(24), .USER_W(1)) im ();
`endif
  logic eof_first, eof_last;                         // end-of-frame markers of the first / last stage
  axil_if #(.ADDR_W(15)) u_pipe_s_axil ();
  assign u_pipe_s_axil.awaddr = b.awaddr[14:0];
  assign u_pipe_s_axil.awvalid = b.awvalid[0];
  assign b.awready[0] = u_pipe_s_axil.awready;
  assign u_pipe_s_axil.wdata = b.wdata;
  assign u_pipe_s_axil.wstrb = b.wstrb;
  assign u_pipe_s_axil.wvalid = b.wvalid[0];
  assign b.wready[0] = u_pipe_s_axil.wready;
  assign b.bresp[1:0] = u_pipe_s_axil.bresp;
  assign b.bvalid[0] = u_pipe_s_axil.bvalid;
  assign u_pipe_s_axil.bready = b.bready[0];
  assign u_pipe_s_axil.araddr = b.araddr[14:0];
  assign u_pipe_s_axil.arvalid = b.arvalid[0];
  assign b.arready[0] = u_pipe_s_axil.arready;
  assign b.rdata[31:0] = u_pipe_s_axil.rdata;
  assign b.rresp[1:0] = u_pipe_s_axil.rresp;
  assign b.rvalid[0] = u_pipe_s_axil.rvalid;
  assign u_pipe_s_axil.rready = b.rready[0];
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
    .s_axil(u_pipe_s_axil),
    `ifdef VP_HDMI
    .tmds0_o(tmds.ch0),
    .tmds1_o(tmds.ch1),
    .tmds2_o(tmds.ch2),
    .tmds_clk_o(tmds.clk),
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
    .ins_m_axis(im),
    .ins_s_axis(ir),
    `endif
    .eof_in_o(eof_first),
    .eof_out_o(eof_last),
    .stats_done_o
    );

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
  axil_if #(.ADDR_W(8)) u_frame_cnt_s_axil ();
  assign u_frame_cnt_s_axil.awaddr = b.awaddr[7:0];
  assign u_frame_cnt_s_axil.awvalid = b.awvalid[S_FC];
  assign b.awready[S_FC] = u_frame_cnt_s_axil.awready;
  assign u_frame_cnt_s_axil.wdata = b.wdata;
  assign u_frame_cnt_s_axil.wstrb = b.wstrb;
  assign u_frame_cnt_s_axil.wvalid = b.wvalid[S_FC];
  assign b.wready[S_FC] = u_frame_cnt_s_axil.wready;
  assign b.bresp[S_FC*2 +: 2] = u_frame_cnt_s_axil.bresp;
  assign b.bvalid[S_FC] = u_frame_cnt_s_axil.bvalid;
  assign u_frame_cnt_s_axil.bready = b.bready[S_FC];
  assign u_frame_cnt_s_axil.araddr = b.araddr[7:0];
  assign u_frame_cnt_s_axil.arvalid = b.arvalid[S_FC];
  assign b.arready[S_FC] = u_frame_cnt_s_axil.arready;
  assign b.rdata[S_FC*32 +: 32] = u_frame_cnt_s_axil.rdata;
  assign b.rresp[S_FC*2 +: 2] = u_frame_cnt_s_axil.rresp;
  assign b.rvalid[S_FC] = u_frame_cnt_s_axil.rvalid;
  assign u_frame_cnt_s_axil.rready = b.rready[S_FC];
  frame_counter_top #(
    .NCH(5),
    .EVQ(128),
    .TS_DIV(TS_DIV < 1 ? 1 : TS_DIV)
  ) u_frame_cnt (
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .eof_i({ev_trk, ev_vs_out, ev_vs_in, eof_last, eof_first}),
    .irq_o(irq_frame_pix),
    .s_axil(u_frame_cnt_s_axil)
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
  axis_if #(.DATA_W(24), .USER_W(1)) vo ();
`endif
`ifdef VP_VISION
  axis_if #(.DATA_W(24), .USER_W(1)) vr ();
  axis_if #(.DATA_W(24), .USER_W(1)) va ();
  axis_if #(.DATA_W(24)) u_vs_adapt_s_axis ();
  assign u_vs_adapt_s_axis.tdata = im_d;
  assign u_vs_adapt_s_axis.tlast = im.tlast;
  assign u_vs_adapt_s_axis.tuser = im.tuser;
  assign u_vs_adapt_s_axis.tvalid = im.tvalid;
  assign im.tready = u_vs_adapt_s_axis.tready;
  vs_stream_adapter #(
    .GAP(barrel_pkg::LINE_GAP_CYCLES + 3),
    .RET_FIFO(VS_RET_FIFO)
  ) u_vs_adapt (
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .s_axis(u_vs_adapt_s_axis),
    .m_axis(va),
    .r_s_axis(vr),
    .r_m_axis(vo),
    .frames_o(),
    .drops_o(),
    .ret_drops_o()
  );
  assign ev_vs_in = va.tvalid && va.tready && va.tuser;           // frame admitted into vision_system
  assign ev_vs_out = vr.tvalid && vr.tready && vr.tuser;          // corrected frame starts coming out
  axil_if #(.ADDR_W(8)) u_vision_s_axil ();
  assign u_vision_s_axil.awaddr = b.awaddr[7:0];
  assign u_vision_s_axil.awvalid = b.awvalid[S_VS];
  assign b.awready[S_VS] = u_vision_s_axil.awready;
  assign u_vision_s_axil.wdata = b.wdata;
  assign u_vision_s_axil.wstrb = b.wstrb;
  assign u_vision_s_axil.wvalid = b.wvalid[S_VS];
  assign b.wready[S_VS] = u_vision_s_axil.wready;
  assign b.bresp[S_VS*2 +: 2] = u_vision_s_axil.bresp;
  assign b.bvalid[S_VS] = u_vision_s_axil.bvalid;
  assign u_vision_s_axil.bready = b.bready[S_VS];
  assign u_vision_s_axil.araddr = b.araddr[7:0];
  assign u_vision_s_axil.arvalid = b.arvalid[S_VS];
  assign b.arready[S_VS] = u_vision_s_axil.arready;
  assign b.rdata[S_VS*32 +: 32] = u_vision_s_axil.rdata;
  assign b.rresp[S_VS*2 +: 2] = u_vision_s_axil.rresp;
  assign b.rvalid[S_VS] = u_vision_s_axil.rvalid;
  assign u_vision_s_axil.rready = b.rready[S_VS];
  vision_system #(
    .ADDR_W(VS_ADDR_W),
    .USE_EXT_FB(VS_USE_EXT_FB)
  ) u_vision (
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .s_axis(va),
    .m_axis(vr),
    .s_axil(u_vision_s_axil),
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
  assign vo.tdata = im_d;
  assign vo.tlast = im.tlast;
  assign vo.tuser = im.tuser;
  assign vo.tvalid = im.tvalid;
  assign im.tready = vo.tready;
`endif

  // ================================================================ blur_sharpen after vision_system
`ifdef VP_INSERT
  axis_if #(.DATA_W(24), .USER_W(1)) fo ();
`endif
`ifdef VP_FILTER
  axil_if #(.ADDR_W(9)) u_filter_s_axil ();
  assign u_filter_s_axil.awaddr = b.awaddr[8:0];
  assign u_filter_s_axil.awvalid = b.awvalid[S_FLT];
  assign b.awready[S_FLT] = u_filter_s_axil.awready;
  assign u_filter_s_axil.wdata = b.wdata;
  assign u_filter_s_axil.wstrb = b.wstrb;
  assign u_filter_s_axil.wvalid = b.wvalid[S_FLT];
  assign b.wready[S_FLT] = u_filter_s_axil.wready;
  assign b.bresp[S_FLT*2 +: 2] = u_filter_s_axil.bresp;
  assign b.bvalid[S_FLT] = u_filter_s_axil.bvalid;
  assign u_filter_s_axil.bready = b.bready[S_FLT];
  assign u_filter_s_axil.araddr = b.araddr[8:0];
  assign u_filter_s_axil.arvalid = b.arvalid[S_FLT];
  assign b.arready[S_FLT] = u_filter_s_axil.arready;
  assign b.rdata[S_FLT*32 +: 32] = u_filter_s_axil.rdata;
  assign b.rresp[S_FLT*2 +: 2] = u_filter_s_axil.rresp;
  assign b.rvalid[S_FLT] = u_filter_s_axil.rvalid;
  assign u_filter_s_axil.rready = b.rready[S_FLT];
  blur_sharpen_top #(.N(FILT_N), .C(3), .CW(8), .MAX_W(MAX_W)) u_filter (
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .s_axil(u_filter_s_axil),
    .s_axis(vo),
    .m_axis(fo)
    );
`elsif VP_INSERT
  assign fo.tdata = vo.tdata;
  assign fo.tlast = vo.tlast;
  assign fo.tuser = vo.tuser;
  assign fo.tvalid = vo.tvalid;
  assign vo.tready = fo.tready;
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
  axil_if #(.ADDR_W(8)) u_feat_s_axil ();
  assign u_feat_s_axil.awaddr = b.awaddr[7:0];
  assign u_feat_s_axil.awvalid = b.awvalid[S_FEAT];
  assign b.awready[S_FEAT] = u_feat_s_axil.awready;
  assign u_feat_s_axil.wdata = b.wdata;
  assign u_feat_s_axil.wstrb = b.wstrb;
  assign u_feat_s_axil.wvalid = b.wvalid[S_FEAT];
  assign b.wready[S_FEAT] = u_feat_s_axil.wready;
  assign b.bresp[S_FEAT*2 +: 2] = u_feat_s_axil.bresp;
  assign b.bvalid[S_FEAT] = u_feat_s_axil.bvalid;
  assign u_feat_s_axil.bready = b.bready[S_FEAT];
  assign u_feat_s_axil.araddr = b.araddr[7:0];
  assign u_feat_s_axil.arvalid = b.arvalid[S_FEAT];
  assign b.arready[S_FEAT] = u_feat_s_axil.arready;
  assign b.rdata[S_FEAT*32 +: 32] = u_feat_s_axil.rdata;
  assign b.rresp[S_FEAT*2 +: 2] = u_feat_s_axil.rresp;
  assign b.rvalid[S_FEAT] = u_feat_s_axil.rvalid;
  assign u_feat_s_axil.rready = b.rready[S_FEAT];
  feature_detect_top #(
    .MAXW(MAX_W),
    .MAXH(FEAT_MAX_H),
    .CELL_LOG2(FEAT_CELL_LOG2)
  ) u_feat (
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .s_axis(fo),
    .feat_o(feat),
    .done_o(),
    .s_axil(u_feat_s_axil)
  );
  for (genvar c = 0; c < NTRK; c++) begin : g_trk
    axil_if #(.ADDR_W(9)) u_track_s_axil ();
    assign u_track_s_axil.awaddr = b.awaddr[8:0];
    assign u_track_s_axil.awvalid = b.awvalid[S_TRK + c];
    assign b.awready[S_TRK + c] = u_track_s_axil.awready;
    assign u_track_s_axil.wdata = b.wdata;
    assign u_track_s_axil.wstrb = b.wstrb;
    assign u_track_s_axil.wvalid = b.wvalid[S_TRK + c];
    assign b.wready[S_TRK + c] = u_track_s_axil.wready;
    assign b.bresp[(S_TRK + c)*2 +: 2] = u_track_s_axil.bresp;
    assign b.bvalid[S_TRK + c] = u_track_s_axil.bvalid;
    assign u_track_s_axil.bready = b.bready[S_TRK + c];
    assign u_track_s_axil.araddr = b.araddr[8:0];
    assign u_track_s_axil.arvalid = b.arvalid[S_TRK + c];
    assign b.arready[S_TRK + c] = u_track_s_axil.arready;
    assign b.rdata[(S_TRK + c)*32 +: 32] = u_track_s_axil.rdata;
    assign b.rresp[(S_TRK + c)*2 +: 2] = u_track_s_axil.rresp;
    assign b.rvalid[S_TRK + c] = u_track_s_axil.rvalid;
    assign u_track_s_axil.rready = b.rready[S_TRK + c];
    object_tracker_top u_track (
      .clk(pix_clk),
      .rst_n(pix_rst_n),
      .feat_i(feat),
      .s_axis(fo),
      .done_o(trk_done[c]),
      .s_axil(u_track_s_axil)
    );
  end
  symbol_overlay_top #(
    .NOBJ(12),                                       // 3 target boxes per class (object 3c + k)
    .NTXT(4)
  ) u_overlay (
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .s_axis_tdata(fo.tdata),
    .s_axis_tlast(fo.tlast),
    .s_axis_tuser(fo.tuser),
    .s_axis_tvalid(fo.tvalid),
    .s_axis_tready(fo.tready),
    .m_axis_tdata(ir.tdata),
    .m_axis_tlast(ir.tlast),
    .m_axis_tuser(ir.tuser),
    .m_axis_tvalid(ir.tvalid),
    .m_axis_tready(ir.tready),
    .s_axil_awaddr(b.awaddr[9:0]),
    .s_axil_awvalid(b.awvalid[S_OVL]),
    .s_axil_awready(b.awready[S_OVL]),
    .s_axil_wdata(b.wdata),
    .s_axil_wstrb(b.wstrb),
    .s_axil_wvalid(b.wvalid[S_OVL]),
    .s_axil_wready(b.wready[S_OVL]),
    .s_axil_bresp(b.bresp[S_OVL*2 +: 2]),
    .s_axil_bvalid(b.bvalid[S_OVL]),
    .s_axil_bready(b.bready[S_OVL]),
    .s_axil_araddr(b.araddr[9:0]),
    .s_axil_arvalid(b.arvalid[S_OVL]),
    .s_axil_arready(b.arready[S_OVL]),
    .s_axil_rdata(b.rdata[S_OVL*32 +: 32]),
    .s_axil_rresp(b.rresp[S_OVL*2 +: 2]),
    .s_axil_rvalid(b.rvalid[S_OVL]),
    .s_axil_rready(b.rready[S_OVL])
  );
`elsif VP_INSERT
  assign ev_trk = 1'b0;
  assign ir.tdata = fo.tdata;
  assign ir.tlast = fo.tlast;
  assign ir.tuser = fo.tuser;
  assign ir.tvalid = fo.tvalid;
  assign fo.tready = ir.tready;
`endif

  // ================================================================ serializers
`ifdef VP_HDMI
  tmds_serializer u_tmds_ser (
    .pix_clk,
    .pix_rst_n,
    .tmds(tmds),
    .ser_clk(tmds_ser_clk),
    .ser_rst_n(tmds_ser_rst_n),
    .serial_o(tmds_serial_o)
    );
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
