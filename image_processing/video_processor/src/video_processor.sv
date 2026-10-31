// ***************
// Filename: video_processor.sv
// Author: FPGA Cores 4 U
// Description: Top level of the video processing system (see
//   docs/system_block_diagram.svg). Version 2.1.0. Technology independent:
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
//                                   cpu_clk, for the window gates
//     u_ext_gate   axil_core_gate   passes the CPU's video register window
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
//                                   video_pipeline insert point (CTRL[7]);
//                                   its frames double-buffered in the DDR
//                                   (VS_USE_DDR_FB, `VP_DDR)
//     (fork)       inline           vision_system's output to the display
//                                   and the analysis paths (each copy held
//                                   until taken)
//     u_filter_d   blur_sharpen     display path: blur / sharpen before the
//                                   overlay (MODE 0-3, 4 = pass-through)
//     u_filter     blur_sharpen     analysis path: blur / sharpen before
//                                   feature_detect
//     u_feat       feature_detect_top per-pixel edge and motion features of
//                                   the analysis path, passed on with each
//                                   beat (fm) to the detectors
//     g_trk[c].u_track object_tracker x NTRK (5) detectors (pedestrian,
//                                   face, automobile, vehicle, aircraft):
//                                   blobs of the object pixels in a search
//                                   window, per frame, for the CPU's
//                                   tracking loop (passive taps on fm)
//     u_npu        npu_top          INT8 CNN detector (`VP_NPU): its frame
//                                   writer taps vision_system's output into
//                                   the DDR, descriptor programs from the
//                                   DDR (CMD, or AUTO after every frame)
//     u_overlay    symbol_overlay   boxes, labels and texts drawn over the
//                                   display path, last in the insert loop
//     u_ddrc       ddr_ctrl_top     DDR controller (`VP_DDR, pix_clk): AXI4
//                                   ports 0 vision_system, 1 the NPU
//                                   (`VP_NPU), last the CPU's DDR window;
//                                   the DFI-style memory pins (ddr_*)
//     u_ddr_gate   axil_core_gate   the CPU's DDR window (py_soc m_ddr_axil,
//                                   0x1000_0000, 64 MB), gated as the EXT
//                                   window (`VP_DDR)
//     u_ddr_cdc    axi4_lite_cdc    its cpu_clk -> pix_clk crossing
//     u_ddr_bridge ddr_cpu_bridge   each 32-bit access as one single-beat
//                                   256-bit AXI4 transfer on its port
//     u_frame_cnt  frame_counter    frames out of the first pipeline stage
//                                   (csi2_raw_unpack) and into the last one
//                                   (axis_to_video): end-of-frame interrupts
//                                   13 / 14 (bit_sync to cpu_clk) and their
//                                   counts; plus frames into and out of
//                                   vision_system and measured by
//                                   object_tracker (or, with AUTO, NPU runs
//                                   finished: channel 4); every marker time
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
//     0x1_8200-0x1_83FF  blur_sharpen, analysis path          `VP_FILTER
//     0x1_8400-0x1_84FF  frame_counter
//     0x1_8500-0x1_85FF  feature_detect: edge / motion features `VP_TRACK
//     0x1_8600-0x1_87FF  blur_sharpen, display path           `VP_FILTER
//     0x1_8C00-0x1_8FFF  symbol_overlay                         `VP_TRACK
//     0x1_9000-0x1_99FF  object_tracker x NTRK (5): detectors   `VP_TRACK
//                        0x1_9000 pedestrian, 0x1_9200 face, 0x1_9400
//                        automobile, 0x1_9600 other vehicle, 0x1_9800
//                        aircraft
//     0x1_A000-0x1_A0FF  npu                                    `VP_NPU
//     0x1000_0000-0x13FF_FFFF  the first 64 MB of the DDR (byte address =
//                        the offset: the NPU header, frame, detections,
//                        program); vision_system's frame buffers
//                        (DDR_VS_FB0 / FB1, at 240 MB) are above it, not
//                        reachable by the CPU                   `VP_DDR
//   While the core logic is in reset (CORE_RESET = 0) every access to
//   0x1_0000-0x1_FFFF (and to the DDR window) completes with SLVERR (read
//   data 0); just after the release an access waits until the core logic
//   is out of reset.
//   Interrupts: intc source 12 = isp_stats frame done (configure it as an
//   edge source), 13 = end of frame at the first pipeline stage, 14 = end of
//   frame at the last stage (frame_counter STATUS, level: write 1 to clear),
//   15 = frame_counter channels 2-4 (vision_system in / out, tracker or NPU
//   done; registered OR, then bit_sync) or the board's spare (ext_irq_i).
//
//   Configuration (src/configuration.sv): `VP_CSI2_RX, `VP_HDMI, `VP_LVDS,
//   `VP_DSI, `VP_CSI2_TX select the external video interfaces, `VP_VISION
//   adds vision_system, `VP_FILTER the two blur_sharpen and `VP_TRACK
//   feature_detect, object_tracker and symbol_overlay, all in the
//   video_pipeline insert loop (`VP_INSERT, enabled by CTRL[7]); `VP_DDR
//   the DDR controller and the CPU's DDR window, `VP_NPU (needs `VP_DDR)
//   the NPU:
//     insert point -> [vs_stream_adapter -> vision_system] -> fork:
//       display:  [blur_sharpen] -> [symbol_overlay] -> back
//       analysis: [blur_sharpen] -> [feature_detect -> object_tracker x 5]
//       [npu frame writer] taps vision_system's output
//   With vision_system in the path, keep CTRL.LOCK (genlock) set: there is
//   no frame buffer to repeat a frame, so each display frame waits in
//   vertical blanking for the next corrected frame (the display follows
//   vision_system's output rate, up to LOCK_MAX extra lines). vision_system
//   frames are at most 720 x 720 on chip (barrel_pkg), up to MAX_W wide in
//   the DDR.
//
//   Clocks (defaults; see docs/clock_diagram.svg): ref_clk, the board
//   oscillator, 33.333 MHz (REF_KHZ). py_soc's clock generator makes
//     cpu_clk      = ref x CPU_M / (CPU_D x CPU_O) = x24 / 4 = 200 MHz
//                    (CPU PLL oscillator 800 MHz), CPU and peripherals
//   and, from cpu_clk (video PLL oscillator cpu_clk x VID_M / VID_D = x35
//   = 7 GHz, phase-aligned outputs):
//     pix_clk      = / PIX_O  (70) = 100 MHz, core logic: video pipeline,
//                    registers, vision_system, blur_sharpen, NPU, DDR
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
//   blur_sharpen, trackers, NPU, DDR controller, frame_counter,
//   serializers) is held in reset: their only
//   reset is the CPU system's reset output core_rst_n_o, synchronised per
//   clock domain (reset_sync). arst_n reaches them through the CPU: it
//   resets py_soc, which clears CORE_RESET (one cpu_clk edge later).
//   core_rst_n_o shows the released state to the board. The watchdog resets
//   the CPU (wdt_reset_o shows it), which clears CORE_RESET and so puts the
//   core logic back into reset until the firmware has booted again.
// Date: 2026-10-26
module video_processor #(
  // video
  parameter int NLANES      = 2,                 // camera D-PHY lanes (1, 2, 4)
  parameter int MAX_W       = 2048,              // longest camera / output line
  parameter int FEAT_MAX_H  = 1152,              // feature_detect: most lines (background cells)
  parameter int FEAT_CELL_LOG2 = 2,              // feature_detect: background cells of 2^n pixels square (the model's 4 x 4)
  parameter int CSI_FIFO    = 2048,              // byte-clock to pixel-clock FIFO, words
  parameter int OUT_FIFO    = 2048,              // output pixel FIFO
  parameter bit SCALER      = 1,                 // include scaler_bilinear
  parameter int DSI_LANES   = 2,                 // MIPI DSI output lanes (1, 2, 4)
  parameter int CSITX_LANES = 2,                 // MIPI CSI-2 output lanes (1, 2, 4)
  // vision_system
  parameter bit VS_USE_EXT_FB = 1'b0,            // frame in external SDRAM (else on chip)
  parameter bit VS_USE_DDR_FB = 1'b1,            // frames in the DDR (`VP_DDR; else on chip / SDRAM)
  parameter int VS_ADDR_W   = barrel_pkg::ADDR_W, // frame store pixel address width
  parameter int VS_RET_FIFO = 1024,              // vision_system return FIFO, words
  parameter logic [31:0] VS_DDR_FB0 = video_processor_map_pkg::DDR_VS_FB0,   // its DDR frame buffers
  parameter logic [31:0] VS_DDR_FB1 = video_processor_map_pkg::DDR_VS_FB1,
  // NPU (`VP_NPU)
  parameter int NPU_PE      = 64,                // MAC array PE x PE (the results do not depend on it)
  // DDR controller (`VP_DDR): the memory's geometry and timings in pix_clk clocks
  parameter int DDR_BANK_W  = 3,                 // 8 banks
  parameter int DDR_ROW_W   = 14,                // 16k rows
  parameter int DDR_COL_W   = 8,                 // 256 words of 256 bits per row (1 GB in all)
  parameter int DDR_T_RCD   = 4,
  parameter int DDR_T_RP    = 4,
  parameter int DDR_T_RAS   = 10,
  parameter int DDR_T_CL    = 5,
  parameter int DDR_T_WR    = 4,
  parameter int DDR_T_RTP   = 2,
  parameter int DDR_T_WTR   = 2,
  parameter int DDR_T_RRD   = 2,
  parameter int DDR_T_RFC   = 30,
  parameter int DDR_T_REFI  = 780,               // 7.8 us at 100 MHz
  // blur_sharpen
  parameter int FILT_N      = 5,                 // kernel size (3 or 5)
  // symbol_overlay: directory of its smooth-font ROMs (ip/video/symbol_overlay/src/include/, with the trailing
  // /; "" leaves them empty: CTRL.FONT text blank)
  parameter     OVL_FONT_DIR = "",
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
  parameter int CPU_CODE_AW   = 15,              // CPU code memory 2**CPU_CODE_AW bytes (32 KB, as pysim: pyc --code-aw 15)
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
`ifdef VP_DDR
  // ---------------- DDR memory: DFI-style command interface of ddr_ctrl (pix_clk) ----------------
  output logic                dfi_clk_o,         // the interface clock (pix_clk)
  /* verilator lint_off SYNCASYNCNET */
  output logic                dfi_rst_n_o,       // the controller's reset (pix_rst_n, see the note at its assign)
  /* verilator lint_on SYNCASYNCNET */
  output logic [2:0]          dfi_cmd_o,         // 0 NOP 1 ACT 2 RD 3 WR 4 PRE 5 PREA 6 REF
  output logic [DDR_BANK_W-1:0] dfi_bank_o,      // bank of ACT / RD / WR / PRE
  output logic [DDR_ROW_W-1:0]  dfi_row_o,       // row of ACT
  output logic [DDR_COL_W-1:0]  dfi_col_o,       // 256-bit word in the row of RD / WR
  output logic [255:0]        dfi_wrdata_o,      // write data with WR
  output logic [31:0]         dfi_wrstrb_o,      // its byte strobes
  input  logic                dfi_rddata_valid_i, // the memory's read word, DDR_T_CL after RD
  input  logic [255:0]        dfi_rddata_i,      // the read word
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
  localparam longint CPU_HZ_ERR = CPU_HZ_PLL > longint'(CPU_HZ) ? CPU_HZ_PLL - longint'(CPU_HZ)
                                                                 : longint'(CPU_HZ) - CPU_HZ_PLL;
  if (CPU_HZ_ERR > longint'(CPU_HZ) / 1000) begin : g_bad_cpu_hz
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
  // py_soc's DDR window (64 MB at 0x1000_0000, `VP_DDR): gate, axi4_lite_cdc to pix_clk, ddr_cpu_bridge onto
  // the DDR controller's last port (below)
  axil_if #(.ADDR_W(26)) cpu_ddr ();
`ifdef VP_DDR
  localparam bit DDR_WIN = 1'b1;
`else
  localparam bit DDR_WIN = 1'b0;
  assign cpu_ddr.awready = 1'b0;
  assign cpu_ddr.wready = 1'b0;
  assign cpu_ddr.bresp = 2'b00;
  assign cpu_ddr.bvalid = 1'b0;
  assign cpu_ddr.arready = 1'b0;
  assign cpu_ddr.rdata = '0;
  assign cpu_ddr.rresp = 2'b00;
  assign cpu_ddr.rvalid = 1'b0;
  wire unused_cpu_ddr = &{1'b0, cpu_ddr.awaddr, cpu_ddr.awvalid, cpu_ddr.wdata, cpu_ddr.wstrb, cpu_ddr.wvalid,
                          cpu_ddr.bready, cpu_ddr.araddr, cpu_ddr.arvalid, cpu_ddr.rready, 1'b0};
`endif
  logic irq_stats;
  logic [1:0] irq_frame;
  logic       irq_frame_hi;                     // frame_counter channels 2-4 (cpu_clk), ext_irq_i[15]
  // py_soc outputs not used here: the run / result / trap detail ports (debug; the board sees trap_o and
  // boot_err_o)
  logic        cpu_done_nc;
  logic [33:0] cpu_result_nc;
  logic [3:0]  cpu_trap_cause_nc;
  logic [CPU_CODE_AW-1:0] cpu_trap_pc_nc;
  logic [2:0]  cpu_boot_err_code_nc;
  wire unused_cpu = &{1'b0, cpu_done_nc, cpu_result_nc, cpu_trap_cause_nc, cpu_trap_pc_nc, cpu_boot_err_code_nc,
                      1'b0};
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
    .N_FRAMES(32),                                 // as the pysim core (py_core v2: 32 frames, 32 locals, 256 globals)
    .FLASH_CLKDIV(FLASH_CLKDIV),
    .EXT_EN(1'b1),
    .DDR_EN(DDR_WIN),
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
    .done_o(cpu_done_nc),
    .result_o(cpu_result_nc),
    .trap_o(cpu_trap_o),
    .trap_cause_o(cpu_trap_cause_nc),
    .trap_pc_o(cpu_trap_pc_nc),
    .boot_done_o,
    .boot_err_o,
    .boot_err_code_o(cpu_boot_err_code_nc),
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
    .ext_irq_i({ext_irq_i | irq_frame_hi, irq_frame, irq_stats}),   // 15: the board's spare or channels 2-4
    .m_ext_axil(c),
    .m_ddr_axil(cpu_ddr)
  );

  // isp_stats frame done (pix_clk pulse) -> intc source 12 (its busy / drop flags not used: one pulse per frame)
  logic stats_sync_busy_nc, stats_sync_drop_nc;
  wire  unused_stats_sync = &{1'b0, stats_sync_busy_nc, stats_sync_drop_nc, 1'b0};
  pulse_sync u_irq_stats (
    .src_clk(pix_clk),
    .src_rst_n(pix_rst_n),
    .pulse_i(stats_done_o),
    .busy_o(stats_sync_busy_nc),
    .drop_o(stats_sync_drop_nc),
    .dst_clk(cpu_clk),
    .dst_rst_n(cpu_rst_n),
    .pulse_o(irq_stats)
  );

  // ================================================================ window gates (cpu_clk)
  // The EXT and DDR windows reach the core logic through axi4_lite_cdc bridges whose pix_clk side is reset
  // with the core logic: each gate (axil_core_gate) passes its window only while the core logic is out of
  // reset and answers SLVERR otherwise (see axil_core_gate.sv).
  logic core_up;                                     // core logic out of reset, in cpu_clk
  logic ext_pass, ddr_pass;                          // gates open
  bit_sync u_core_up (
    .clk(cpu_clk),
    .rst_n(cpu_rst_n),
    .d_i(pix_rst_n),
    .q_o(core_up)
  );
  axil_if #(.ADDR_W(16)) u_axil_cdc_s_axil ();
  axil_core_gate u_ext_gate (
    .clk(cpu_clk),
    .rst_n(cpu_rst_n),
    .core_up_i(core_up),
    .core_rel_i(core_rel),
    .pass_o(ext_pass),
    .s_axil(c),
    .m_axil(u_axil_cdc_s_axil)
  );
`ifdef VP_DDR
  axil_if #(.ADDR_W(26)) u_ddr_cdc_s_axil ();
  axil_core_gate u_ddr_gate (
    .clk(cpu_clk),
    .rst_n(cpu_rst_n),
    .core_up_i(core_up),
    .core_rel_i(core_rel),
    .pass_o(ddr_pass),
    .s_axil(cpu_ddr),
    .m_axil(u_ddr_cdc_s_axil)
  );
  axil_if #(.ADDR_W(26)) ddr_win ();             // the window in pix_clk
  axi4_lite_cdc #(.ADDR_W(26)) u_ddr_cdc (
    .s_clk(cpu_clk),
    .s_rst_n(cpu_rst_n && ddr_pass),
    .s_axil(u_ddr_cdc_s_axil),
    .m_clk(pix_clk),
    .m_rst_n(pix_rst_n),
    .m_axil(ddr_win)
  );
`else
  assign ddr_pass = 1'b0;
`endif

  // ================================================================ control interconnect (pix_clk)
  axil_if #(.ADDR_W(16), .DATA_W(32)) v ();
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
  localparam int NF = 2;                         // blur_sharpen: analysis (0x8200) and display (0x8600)
`else
  localparam int NF = 0;
`endif
`ifdef VP_TRACK
  localparam int NT = 1;
`else
  localparam int NT = 0;
`endif
`ifdef VP_NPU
  localparam int NN = 1;
`else
  localparam int NN = 0;
`endif
  localparam int NTRK = video_processor_map_pkg::NTRK;   // object_tracker detectors (one per object class)
  localparam int NS = 2 + NV + NF + (NTRK + 2) * NT + NN, S_NPU = 2 + NV + NF + (NTRK + 2) * NT;
  localparam int S_VS = 1, S_FLT = 1 + NV, S_FC = 1 + NV + NF, S_TRK = 2 + NV + NF, S_OVL = 2 + NV + NF + NTRK,
                 S_FEAT = 3 + NV + NF + NTRK, S_FLTD = 2 + NV;
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
    m[S_FLTD*32 +: 32] = mask ? video_processor_map_pkg::FLTD_MASK : video_processor_map_pkg::FLTD_OFFSET;
`endif
    m[S_FC*32 +: 32] = mask ? video_processor_map_pkg::FC_MASK : video_processor_map_pkg::FC_OFFSET;
`ifdef VP_TRACK
    for (int t = 0; t < NTRK; t++)
      m[(S_TRK + t)*32 +: 32] = mask ? video_processor_map_pkg::TRK_MASK
                                     : video_processor_map_pkg::TRK_OFFSET + 32'(t) * video_processor_map_pkg::TRK_STRIDE;
    m[S_OVL*32 +: 32] = mask ? video_processor_map_pkg::OVL_MASK : video_processor_map_pkg::OVL_OFFSET;
    m[S_FEAT*32 +: 32] = mask ? video_processor_map_pkg::FEAT_MASK : video_processor_map_pkg::FEAT_OFFSET;
`endif
`ifdef VP_NPU
    m[S_NPU*32 +: 32] = mask ? video_processor_map_pkg::NPU_MASK : video_processor_map_pkg::NPU_OFFSET;
`endif
    return m;
  endfunction
  localparam logic [NS*32-1:0] VBASE = bus_map(1'b0);
  localparam logic [NS*32-1:0] VMASK = bus_map(1'b1);
  // the decoder's slave side, one bit / field per slave (py_axil_xbar m_axil_*)
  logic [31:0]    b_awaddr, b_wdata, b_araddr;
  logic [3:0]     b_wstrb;
  logic [NS-1:0]  b_awvalid, b_awready, b_wvalid, b_wready, b_bvalid, b_bready, b_arvalid, b_arready;
  logic [NS-1:0]  b_rvalid, b_rready;
  logic [NS*2-1:0] b_bresp, b_rresp;
  logic [NS*32-1:0] b_rdata;
  // the slaves decode at most 15 address bits; the decoder has matched the rest
  wire unused_b_addr = &{1'b0, b_awaddr[31:15], b_araddr[31:15], 1'b0};
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
  tmds_if tmds ();
`endif
`ifdef VP_LVDS
  logic [27:0] lvds_a, lvds_b;
  logic [6:0] lvds_clk_word;
  logic lvds_stb;
`endif
`ifdef VP_INSERT
  axis_if #(.DATA_W(24), .USER_W(1)) ir ();
  axis_if #(.DATA_W(24), .USER_W(1)) im ();
`endif
  logic eof_first, eof_last;                         // end-of-frame markers of the first / last stage
  axil_if #(.ADDR_W(15)) u_pipe_s_axil ();
  assign u_pipe_s_axil.awaddr = b_awaddr[14:0];
  assign u_pipe_s_axil.awvalid = b_awvalid[0];
  assign b_awready[0] = u_pipe_s_axil.awready;
  assign u_pipe_s_axil.wdata = b_wdata;
  assign u_pipe_s_axil.wstrb = b_wstrb;
  assign u_pipe_s_axil.wvalid = b_wvalid[0];
  assign b_wready[0] = u_pipe_s_axil.wready;
  assign b_bresp[1:0] = u_pipe_s_axil.bresp;
  assign b_bvalid[0] = u_pipe_s_axil.bvalid;
  assign u_pipe_s_axil.bready = b_bready[0];
  assign u_pipe_s_axil.araddr = b_araddr[14:0];
  assign u_pipe_s_axil.arvalid = b_arvalid[0];
  assign b_arready[0] = u_pipe_s_axil.arready;
  assign b_rdata[31:0] = u_pipe_s_axil.rdata;
  assign b_rresp[1:0] = u_pipe_s_axil.rresp;
  assign b_rvalid[0] = u_pipe_s_axil.rvalid;
  assign u_pipe_s_axil.rready = b_rready[0];
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
  localparam int TS_DIV = int'((PIX_HZ + 500_000) / 1_000_000);             // pix_clk ticks per microsecond
  logic [4:0] irq_frame_pix;
  logic ev_vs_in, ev_vs_out, ev_trk;                 // driven below (0 when the block is not built)
`ifndef VP_INSERT
  assign ev_vs_in = 1'b0;
  assign ev_vs_out = 1'b0;
  assign ev_trk = 1'b0;
`endif
  axil_if #(.ADDR_W(8)) u_frame_cnt_s_axil ();
  assign u_frame_cnt_s_axil.awaddr = b_awaddr[7:0];
  assign u_frame_cnt_s_axil.awvalid = b_awvalid[S_FC];
  assign b_awready[S_FC] = u_frame_cnt_s_axil.awready;
  assign u_frame_cnt_s_axil.wdata = b_wdata;
  assign u_frame_cnt_s_axil.wstrb = b_wstrb;
  assign u_frame_cnt_s_axil.wvalid = b_wvalid[S_FC];
  assign b_wready[S_FC] = u_frame_cnt_s_axil.wready;
  assign b_bresp[S_FC*2 +: 2] = u_frame_cnt_s_axil.bresp;
  assign b_bvalid[S_FC] = u_frame_cnt_s_axil.bvalid;
  assign u_frame_cnt_s_axil.bready = b_bready[S_FC];
  assign u_frame_cnt_s_axil.araddr = b_araddr[7:0];
  assign u_frame_cnt_s_axil.arvalid = b_arvalid[S_FC];
  assign b_arready[S_FC] = u_frame_cnt_s_axil.arready;
  assign b_rdata[S_FC*32 +: 32] = u_frame_cnt_s_axil.rdata;
  assign b_rresp[S_FC*2 +: 2] = u_frame_cnt_s_axil.rresp;
  assign b_rvalid[S_FC] = u_frame_cnt_s_axil.rvalid;
  assign u_frame_cnt_s_axil.rready = b_rready[S_FC];
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
  // channels 2-4 together on source 15 (as the system model), ORed and registered in pix_clk before the
  // synchroniser (no combinational glitch crosses)
  logic irq_frame_hi_pix;
  always_ff @(posedge pix_clk) begin
    if (!pix_rst_n) irq_frame_hi_pix <= 1'b0;
    else irq_frame_hi_pix <= |irq_frame_pix[4:2];
  end
  bit_sync u_irq_frame_hi (
    .clk(cpu_clk),
    .rst_n(cpu_rst_n),
    .d_i(irq_frame_hi_pix),
    .q_o(irq_frame_hi)
  );

  // ================================================================ DDR controller (`VP_DDR)
  // ddr_ctrl on pix_clk (vision_system's clock: its port needs no crossing); port 0 vision_system's
  // DDR frame store (VS_USE_DDR_FB); the memory is outside (the DFI-style pins, ddr_mem in the testbench)
  localparam int DDR_ID_W = 4;
`ifdef VP_DDR
  localparam bit VS_DDR_FB = VS_USE_DDR_FB;
`else
  localparam bit VS_DDR_FB = 1'b0;
`endif
  if (VS_DDR_FB && (VS_USE_EXT_FB || 64'(1) << (VS_ADDR_W + 2) > 64'(video_processor_map_pkg::DDR_VS_FB_SIZE)))
  begin : g_bad_vs_ddr
    $error("video_processor: VS_USE_DDR_FB excludes VS_USE_EXT_FB; a frame buffer is at most DDR_VS_FB_SIZE");
  end
  // vision_system's AXI4 master port (idle unless VS_DDR_FB)
  logic [DDR_ID_W-1:0] vs_awid, vs_arid, vs_bid, vs_rid;
  logic [31:0]         vs_awaddr, vs_araddr;
  logic [7:0]          vs_awlen, vs_arlen;
  logic [2:0]          vs_awsize, vs_arsize;
  logic [1:0]          vs_awburst, vs_arburst, vs_bresp, vs_rresp;
  logic                vs_awvalid, vs_awready, vs_wlast, vs_wvalid, vs_wready, vs_bvalid, vs_bready;
  logic                vs_arvalid, vs_arready, vs_rlast, vs_rvalid, vs_rready;
  logic [255:0]        vs_wdata, vs_rdata;
  logic [31:0]         vs_wstrb;
`ifndef VP_VISION
  assign vs_awid = '0;
  assign vs_awaddr = '0;
  assign vs_awlen = '0;
  assign vs_awsize = '0;
  assign vs_awburst = '0;
  assign vs_awvalid = 1'b0;
  assign vs_wdata = '0;
  assign vs_wstrb = '0;
  assign vs_wlast = 1'b0;
  assign vs_wvalid = 1'b0;
  assign vs_bready = 1'b0;
  assign vs_arid = '0;
  assign vs_araddr = '0;
  assign vs_arlen = '0;
  assign vs_arsize = '0;
  assign vs_arburst = '0;
  assign vs_arvalid = 1'b0;
  assign vs_rready = 1'b0;
`endif
`ifdef VP_DDR
  // the controller's statistics registers are not in the CPU's map (the system model has none; 0x1_A000
  // is the NPU's): its AXI4-Lite port idle
  axil_if #(.ADDR_W(8)) u_ddrc_s_axil ();
  assign u_ddrc_s_axil.awaddr = '0;
  assign u_ddrc_s_axil.awvalid = 1'b0;
  assign u_ddrc_s_axil.wdata = '0;
  assign u_ddrc_s_axil.wstrb = '0;
  assign u_ddrc_s_axil.wvalid = 1'b0;
  assign u_ddrc_s_axil.bready = 1'b1;
  assign u_ddrc_s_axil.araddr = '0;
  assign u_ddrc_s_axil.arvalid = 1'b0;
  assign u_ddrc_s_axil.rready = 1'b1;
  wire unused_ddrc_axil = &{1'b0, u_ddrc_s_axil.awready, u_ddrc_s_axil.wready, u_ddrc_s_axil.bresp,
                            u_ddrc_s_axil.bvalid, u_ddrc_s_axil.arready, u_ddrc_s_axil.rdata, u_ddrc_s_axil.rresp,
                            u_ddrc_s_axil.rvalid, 1'b0};
  assign dfi_clk_o = pix_clk;
  // pix_rst_n itself (reset_sync: asserted asynchronously, released on pix_clk): the CDC bridges use it as
  // an asynchronous reset, every other block synchronously - both intended (SYNCASYNCNET waived at the port)
  assign dfi_rst_n_o = pix_rst_n;
  // the controller's ports, packed by port: 0 vision_system, then the NPU (`VP_NPU), last the CPU's window
`ifdef VP_NPU
  localparam int NDP = 3;
`else
  localparam int NDP = 2;
`endif
  logic [NDP*DDR_ID_W-1:0] dp_awid;
  logic [NDP*32-1:0] dp_awaddr;
  logic [NDP*8-1:0] dp_awlen;
  logic [NDP*3-1:0] dp_awsize;
  logic [NDP*2-1:0] dp_awburst;
  logic [NDP*1-1:0] dp_awvalid;
  logic [NDP*256-1:0] dp_wdata;
  logic [NDP*32-1:0] dp_wstrb;
  logic [NDP*1-1:0] dp_wlast;
  logic [NDP*1-1:0] dp_wvalid;
  logic [NDP*1-1:0] dp_bready;
  logic [NDP*DDR_ID_W-1:0] dp_arid;
  logic [NDP*32-1:0] dp_araddr;
  logic [NDP*8-1:0] dp_arlen;
  logic [NDP*3-1:0] dp_arsize;
  logic [NDP*2-1:0] dp_arburst;
  logic [NDP*1-1:0] dp_arvalid;
  logic [NDP*1-1:0] dp_rready;
  logic [NDP*1-1:0] dp_awready;
  logic [NDP*1-1:0] dp_wready;
  logic [NDP*DDR_ID_W-1:0] dp_bid;
  logic [NDP*2-1:0] dp_bresp;
  logic [NDP*1-1:0] dp_bvalid;
  logic [NDP*1-1:0] dp_arready;
  logic [NDP*DDR_ID_W-1:0] dp_rid;
  logic [NDP*256-1:0] dp_rdata;
  logic [NDP*2-1:0] dp_rresp;
  logic [NDP*1-1:0] dp_rlast;
  logic [NDP*1-1:0] dp_rvalid;
  logic [DDR_ID_W-1:0] cp_awid;
  logic [31:0] cp_awaddr;
  logic [7:0] cp_awlen;
  logic [2:0] cp_awsize;
  logic [1:0] cp_awburst;
  logic cp_awvalid;
  logic [255:0] cp_wdata;
  logic [31:0] cp_wstrb;
  logic cp_wlast;
  logic cp_wvalid;
  logic cp_bready;
  logic [DDR_ID_W-1:0] cp_arid;
  logic [31:0] cp_araddr;
  logic [7:0] cp_arlen;
  logic [2:0] cp_arsize;
  logic [1:0] cp_arburst;
  logic cp_arvalid;
  logic cp_rready;
  logic cp_awready;
  logic cp_wready;
  logic [DDR_ID_W-1:0] cp_bid;
  logic [1:0] cp_bresp;
  logic cp_bvalid;
  logic cp_arready;
  logic [DDR_ID_W-1:0] cp_rid;
  logic [255:0] cp_rdata;
  logic [1:0] cp_rresp;
  logic cp_rlast;
  logic cp_rvalid;
`ifdef VP_NPU
  logic [DDR_ID_W-1:0] np_awid;
  logic [31:0] np_awaddr;
  logic [7:0] np_awlen;
  logic [2:0] np_awsize;
  logic [1:0] np_awburst;
  logic np_awvalid;
  logic [255:0] np_wdata;
  logic [31:0] np_wstrb;
  logic np_wlast;
  logic np_wvalid;
  logic np_bready;
  logic [DDR_ID_W-1:0] np_arid;
  logic [31:0] np_araddr;
  logic [7:0] np_arlen;
  logic [2:0] np_arsize;
  logic [1:0] np_arburst;
  logic np_arvalid;
  logic np_rready;
  logic np_awready;
  logic np_wready;
  logic [DDR_ID_W-1:0] np_bid;
  logic [1:0] np_bresp;
  logic np_bvalid;
  logic np_arready;
  logic [DDR_ID_W-1:0] np_rid;
  logic [255:0] np_rdata;
  logic [1:0] np_rresp;
  logic np_rlast;
  logic np_rvalid;
  assign dp_awid = {cp_awid, np_awid, vs_awid};
  assign dp_awaddr = {cp_awaddr, np_awaddr, vs_awaddr};
  assign dp_awlen = {cp_awlen, np_awlen, vs_awlen};
  assign dp_awsize = {cp_awsize, np_awsize, vs_awsize};
  assign dp_awburst = {cp_awburst, np_awburst, vs_awburst};
  assign dp_awvalid = {cp_awvalid, np_awvalid, vs_awvalid};
  assign dp_wdata = {cp_wdata, np_wdata, vs_wdata};
  assign dp_wstrb = {cp_wstrb, np_wstrb, vs_wstrb};
  assign dp_wlast = {cp_wlast, np_wlast, vs_wlast};
  assign dp_wvalid = {cp_wvalid, np_wvalid, vs_wvalid};
  assign dp_bready = {cp_bready, np_bready, vs_bready};
  assign dp_arid = {cp_arid, np_arid, vs_arid};
  assign dp_araddr = {cp_araddr, np_araddr, vs_araddr};
  assign dp_arlen = {cp_arlen, np_arlen, vs_arlen};
  assign dp_arsize = {cp_arsize, np_arsize, vs_arsize};
  assign dp_arburst = {cp_arburst, np_arburst, vs_arburst};
  assign dp_arvalid = {cp_arvalid, np_arvalid, vs_arvalid};
  assign dp_rready = {cp_rready, np_rready, vs_rready};
  assign {cp_awready, np_awready, vs_awready} = dp_awready;
  assign {cp_wready, np_wready, vs_wready} = dp_wready;
  assign {cp_bid, np_bid, vs_bid} = dp_bid;
  assign {cp_bresp, np_bresp, vs_bresp} = dp_bresp;
  assign {cp_bvalid, np_bvalid, vs_bvalid} = dp_bvalid;
  assign {cp_arready, np_arready, vs_arready} = dp_arready;
  assign {cp_rid, np_rid, vs_rid} = dp_rid;
  assign {cp_rdata, np_rdata, vs_rdata} = dp_rdata;
  assign {cp_rresp, np_rresp, vs_rresp} = dp_rresp;
  assign {cp_rlast, np_rlast, vs_rlast} = dp_rlast;
  assign {cp_rvalid, np_rvalid, vs_rvalid} = dp_rvalid;
`else
  assign dp_awid = {cp_awid, vs_awid};
  assign dp_awaddr = {cp_awaddr, vs_awaddr};
  assign dp_awlen = {cp_awlen, vs_awlen};
  assign dp_awsize = {cp_awsize, vs_awsize};
  assign dp_awburst = {cp_awburst, vs_awburst};
  assign dp_awvalid = {cp_awvalid, vs_awvalid};
  assign dp_wdata = {cp_wdata, vs_wdata};
  assign dp_wstrb = {cp_wstrb, vs_wstrb};
  assign dp_wlast = {cp_wlast, vs_wlast};
  assign dp_wvalid = {cp_wvalid, vs_wvalid};
  assign dp_bready = {cp_bready, vs_bready};
  assign dp_arid = {cp_arid, vs_arid};
  assign dp_araddr = {cp_araddr, vs_araddr};
  assign dp_arlen = {cp_arlen, vs_arlen};
  assign dp_arsize = {cp_arsize, vs_arsize};
  assign dp_arburst = {cp_arburst, vs_arburst};
  assign dp_arvalid = {cp_arvalid, vs_arvalid};
  assign dp_rready = {cp_rready, vs_rready};
  assign {cp_awready, vs_awready} = dp_awready;
  assign {cp_wready, vs_wready} = dp_wready;
  assign {cp_bid, vs_bid} = dp_bid;
  assign {cp_bresp, vs_bresp} = dp_bresp;
  assign {cp_bvalid, vs_bvalid} = dp_bvalid;
  assign {cp_arready, vs_arready} = dp_arready;
  assign {cp_rid, vs_rid} = dp_rid;
  assign {cp_rdata, vs_rdata} = dp_rdata;
  assign {cp_rresp, vs_rresp} = dp_rresp;
  assign {cp_rlast, vs_rlast} = dp_rlast;
  assign {cp_rvalid, vs_rvalid} = dp_rvalid;
`endif
  ddr_cpu_bridge #(
    .ADDR_W(26),
    .ID_W(DDR_ID_W),
    .ID(2)
  ) u_ddr_bridge (
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .s_axil(ddr_win),
    .m_axi_awid(cp_awid),
    .m_axi_awaddr(cp_awaddr),
    .m_axi_awlen(cp_awlen),
    .m_axi_awsize(cp_awsize),
    .m_axi_awburst(cp_awburst),
    .m_axi_awvalid(cp_awvalid),
    .m_axi_wdata(cp_wdata),
    .m_axi_wstrb(cp_wstrb),
    .m_axi_wlast(cp_wlast),
    .m_axi_wvalid(cp_wvalid),
    .m_axi_bready(cp_bready),
    .m_axi_arid(cp_arid),
    .m_axi_araddr(cp_araddr),
    .m_axi_arlen(cp_arlen),
    .m_axi_arsize(cp_arsize),
    .m_axi_arburst(cp_arburst),
    .m_axi_arvalid(cp_arvalid),
    .m_axi_rready(cp_rready),
    .m_axi_awready(cp_awready),
    .m_axi_wready(cp_wready),
    .m_axi_bid(cp_bid),
    .m_axi_bresp(cp_bresp),
    .m_axi_bvalid(cp_bvalid),
    .m_axi_arready(cp_arready),
    .m_axi_rid(cp_rid),
    .m_axi_rdata(cp_rdata),
    .m_axi_rresp(cp_rresp),
    .m_axi_rlast(cp_rlast),
    .m_axi_rvalid(cp_rvalid)
  );
  ddr_ctrl_top #(
    .NPORTS(NDP),
    .DATA_W(256),
    .ADDR_W(32),
    .ID_W(DDR_ID_W),
    .BANK_W(DDR_BANK_W),
    .ROW_W(DDR_ROW_W),
    .COL_W(DDR_COL_W),
    .T_RCD(DDR_T_RCD),
    .T_RP(DDR_T_RP),
    .T_RAS(DDR_T_RAS),
    .T_CL(DDR_T_CL),
    .T_WR(DDR_T_WR),
    .T_RTP(DDR_T_RTP),
    .T_WTR(DDR_T_WTR),
    .T_RRD(DDR_T_RRD),
    .T_RFC(DDR_T_RFC),
    .T_REFI(DDR_T_REFI),
    .PRIORITY(0),
    .RQ_DEPTH(16),
    .BQ_DEPTH(2)
  ) u_ddrc (
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .s_axil(u_ddrc_s_axil),
    .s_axi_awid(dp_awid),
    .s_axi_awaddr(dp_awaddr),
    .s_axi_awlen(dp_awlen),
    .s_axi_awsize(dp_awsize),
    .s_axi_awburst(dp_awburst),
    .s_axi_awvalid(dp_awvalid),
    .s_axi_awready(dp_awready),
    .s_axi_wdata(dp_wdata),
    .s_axi_wstrb(dp_wstrb),
    .s_axi_wlast(dp_wlast),
    .s_axi_wvalid(dp_wvalid),
    .s_axi_wready(dp_wready),
    .s_axi_bid(dp_bid),
    .s_axi_bresp(dp_bresp),
    .s_axi_bvalid(dp_bvalid),
    .s_axi_bready(dp_bready),
    .s_axi_arid(dp_arid),
    .s_axi_araddr(dp_araddr),
    .s_axi_arlen(dp_arlen),
    .s_axi_arsize(dp_arsize),
    .s_axi_arburst(dp_arburst),
    .s_axi_arvalid(dp_arvalid),
    .s_axi_arready(dp_arready),
    .s_axi_rid(dp_rid),
    .s_axi_rdata(dp_rdata),
    .s_axi_rresp(dp_rresp),
    .s_axi_rlast(dp_rlast),
    .s_axi_rvalid(dp_rvalid),
    .s_axi_rready(dp_rready),
    .dfi_cmd_o,
    .dfi_bank_o,
    .dfi_row_o,
    .dfi_col_o,
    .dfi_wrdata_o,
    .dfi_wrstrb_o,
    .dfi_rddata_valid_i,
    .dfi_rddata_i
  );
`else
  assign vs_awready = 1'b0;                      // no controller: vision_system's port idle
  assign vs_wready = 1'b0;
  assign vs_bid = '0;
  assign vs_bresp = '0;
  assign vs_bvalid = 1'b0;
  assign vs_arready = 1'b0;
  assign vs_rid = '0;
  assign vs_rdata = '0;
  assign vs_rresp = '0;
  assign vs_rlast = 1'b0;
  assign vs_rvalid = 1'b0;
  wire unused_vs_axi = &{1'b0, vs_awid, vs_awaddr, vs_awlen, vs_awsize, vs_awburst, vs_awvalid, vs_wdata, vs_wstrb,
                         vs_wlast, vs_wvalid, vs_bready, vs_arid, vs_araddr, vs_arlen, vs_arsize, vs_arburst,
                         vs_arvalid, vs_rready, 1'b0};
`endif

  // ================================================================ vision_system at the insert point
`ifdef VP_INSERT
  axis_if #(.DATA_W(24), .USER_W(1)) vo ();
`endif
`ifdef VP_VISION
  axis_if #(.DATA_W(24), .USER_W(1)) vr ();
  axis_if #(.DATA_W(24), .USER_W(1)) va ();
  axis_if #(.DATA_W(24)) u_vs_adapt_s_axis ();
  assign u_vs_adapt_s_axis.tdata = im.tdata;
  assign u_vs_adapt_s_axis.tlast = im.tlast;
  assign u_vs_adapt_s_axis.tuser = im.tuser;
  assign u_vs_adapt_s_axis.tvalid = im.tvalid;
  assign im.tready = u_vs_adapt_s_axis.tready;
  logic [31:0] vs_frames_nc, vs_drops_nc, vs_ret_drops_nc;   // the adapter's counters (not in the map)
  wire unused_vs_adapt = &{1'b0, vs_frames_nc, vs_drops_nc, vs_ret_drops_nc, 1'b0};
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
    .frames_o(vs_frames_nc),
    .drops_o(vs_drops_nc),
    .ret_drops_o(vs_ret_drops_nc)
  );
  assign ev_vs_in = va.tvalid && va.tready && va.tuser;           // frame admitted into vision_system
  assign ev_vs_out = vr.tvalid && vr.tready && vr.tuser;          // corrected frame starts coming out
  axil_if #(.ADDR_W(8)) u_vision_s_axil ();
  assign u_vision_s_axil.awaddr = b_awaddr[7:0];
  assign u_vision_s_axil.awvalid = b_awvalid[S_VS];
  assign b_awready[S_VS] = u_vision_s_axil.awready;
  assign u_vision_s_axil.wdata = b_wdata;
  assign u_vision_s_axil.wstrb = b_wstrb;
  assign u_vision_s_axil.wvalid = b_wvalid[S_VS];
  assign b_wready[S_VS] = u_vision_s_axil.wready;
  assign b_bresp[S_VS*2 +: 2] = u_vision_s_axil.bresp;
  assign b_bvalid[S_VS] = u_vision_s_axil.bvalid;
  assign u_vision_s_axil.bready = b_bready[S_VS];
  assign u_vision_s_axil.araddr = b_araddr[7:0];
  assign u_vision_s_axil.arvalid = b_arvalid[S_VS];
  assign b_arready[S_VS] = u_vision_s_axil.arready;
  assign b_rdata[S_VS*32 +: 32] = u_vision_s_axil.rdata;
  assign b_rresp[S_VS*2 +: 2] = u_vision_s_axil.rresp;
  assign b_rvalid[S_VS] = u_vision_s_axil.rvalid;
  assign u_vision_s_axil.rready = b_rready[S_VS];
  vision_system #(
    .ADDR_W(VS_ADDR_W),
    .USE_EXT_FB(VS_USE_EXT_FB),
    .USE_DDR_FB(VS_DDR_FB),
    .DDR_DATA_W(256),
    .DDR_ADDR_W(32),
    .DDR_ID_W(DDR_ID_W),
    .DDR_BASE0(VS_DDR_FB0),
    .DDR_BASE1(VS_DDR_FB1)
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
    .sdram_dq,
    .m_axi_awid(vs_awid),
    .m_axi_awaddr(vs_awaddr),
    .m_axi_awlen(vs_awlen),
    .m_axi_awsize(vs_awsize),
    .m_axi_awburst(vs_awburst),
    .m_axi_awvalid(vs_awvalid),
    .m_axi_awready(vs_awready),
    .m_axi_wdata(vs_wdata),
    .m_axi_wstrb(vs_wstrb),
    .m_axi_wlast(vs_wlast),
    .m_axi_wvalid(vs_wvalid),
    .m_axi_wready(vs_wready),
    .m_axi_bid(vs_bid),
    .m_axi_bresp(vs_bresp),
    .m_axi_bvalid(vs_bvalid),
    .m_axi_bready(vs_bready),
    .m_axi_arid(vs_arid),
    .m_axi_araddr(vs_araddr),
    .m_axi_arlen(vs_arlen),
    .m_axi_arsize(vs_arsize),
    .m_axi_arburst(vs_arburst),
    .m_axi_arvalid(vs_arvalid),
    .m_axi_arready(vs_arready),
    .m_axi_rid(vs_rid),
    .m_axi_rdata(vs_rdata),
    .m_axi_rresp(vs_rresp),
    .m_axi_rlast(vs_rlast),
    .m_axi_rvalid(vs_rvalid),
    .m_axi_rready(vs_rready)
  );
`elsif VP_INSERT
  assign ev_vs_in = 1'b0;
  assign ev_vs_out = 1'b0;
  assign vo.tdata = im.tdata;
  assign vo.tlast = im.tlast;
  assign vo.tuser = im.tuser;
  assign vo.tvalid = im.tvalid;
  assign im.tready = vo.tready;
`endif

  // ================================================================ blur_sharpen after vision_system
  // Two paths (as the system model): vision_system's output goes to both filters at once (a beat moves
  // when both take it). Display: blur_sharpen at 0x8600 -> symbol_overlay. Analysis: blur_sharpen at
  // 0x8200 -> feature_detect -> object_tracker x NTRK (passive: its output is always taken).
`ifdef VP_INSERT
  axis_if #(.DATA_W(24), .USER_W(1)) fo ();      // display path into symbol_overlay
  axis_if #(.DATA_W(24), .USER_W(1)) fa ();      // analysis path into feature_detect (always taken)
`endif
`ifdef VP_FILTER
  axis_if #(.DATA_W(24), .USER_W(1)) vd ();      // vision_system's output, display copy
  axis_if #(.DATA_W(24), .USER_W(1)) vn ();      // analysis copy
  assign vd.tdata = vo.tdata;
  assign vd.tlast = vo.tlast;
  assign vd.tuser = vo.tuser;
  assign vd.tkeep = '1;
  assign vn.tdata = vo.tdata;
  assign vn.tlast = vo.tlast;
  assign vn.tuser = vo.tuser;
  assign vn.tkeep = '1;
  // fork: each copy is presented until it has been taken (d_got / n_got), the beat leaves vo once both
  // have it; a copy's tvalid never depends on the other copy's tready (no combinational loop)
  logic d_got, n_got;
  assign vd.tvalid = vo.tvalid && !d_got;
  assign vn.tvalid = vo.tvalid && !n_got;
  wire  d_take = d_got || vd.tready;
  wire  n_take = n_got || vn.tready;
  assign vo.tready = d_take && n_take;
  always_ff @(posedge pix_clk) begin
    if (!pix_rst_n) begin
      d_got <= 1'b0;
      n_got <= 1'b0;
    end else if (vo.tvalid) begin
      d_got <= !(d_take && n_take) && d_take;    // taken, the other not yet: wait
      n_got <= !(d_take && n_take) && n_take;
    end
  end
  axil_if #(.ADDR_W(9)) u_filter_s_axil ();
  assign u_filter_s_axil.awaddr = b_awaddr[8:0];
  assign u_filter_s_axil.awvalid = b_awvalid[S_FLT];
  assign b_awready[S_FLT] = u_filter_s_axil.awready;
  assign u_filter_s_axil.wdata = b_wdata;
  assign u_filter_s_axil.wstrb = b_wstrb;
  assign u_filter_s_axil.wvalid = b_wvalid[S_FLT];
  assign b_wready[S_FLT] = u_filter_s_axil.wready;
  assign b_bresp[S_FLT*2 +: 2] = u_filter_s_axil.bresp;
  assign b_bvalid[S_FLT] = u_filter_s_axil.bvalid;
  assign u_filter_s_axil.bready = b_bready[S_FLT];
  assign u_filter_s_axil.araddr = b_araddr[8:0];
  assign u_filter_s_axil.arvalid = b_arvalid[S_FLT];
  assign b_arready[S_FLT] = u_filter_s_axil.arready;
  assign b_rdata[S_FLT*32 +: 32] = u_filter_s_axil.rdata;
  assign b_rresp[S_FLT*2 +: 2] = u_filter_s_axil.rresp;
  assign b_rvalid[S_FLT] = u_filter_s_axil.rvalid;
  assign u_filter_s_axil.rready = b_rready[S_FLT];
  blur_sharpen_top #(.N(FILT_N), .C(3), .CW(8), .MAX_W(MAX_W)) u_filter (   // analysis
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .s_axil(u_filter_s_axil),
    .s_axis(vn),
    .m_axis(fa)
  );
  assign fa.tready = 1'b1;
  axil_if #(.ADDR_W(9)) u_filter_d_s_axil ();
  assign u_filter_d_s_axil.awaddr = b_awaddr[8:0];
  assign u_filter_d_s_axil.awvalid = b_awvalid[S_FLTD];
  assign b_awready[S_FLTD] = u_filter_d_s_axil.awready;
  assign u_filter_d_s_axil.wdata = b_wdata;
  assign u_filter_d_s_axil.wstrb = b_wstrb;
  assign u_filter_d_s_axil.wvalid = b_wvalid[S_FLTD];
  assign b_wready[S_FLTD] = u_filter_d_s_axil.wready;
  assign b_bresp[S_FLTD*2 +: 2] = u_filter_d_s_axil.bresp;
  assign b_bvalid[S_FLTD] = u_filter_d_s_axil.bvalid;
  assign u_filter_d_s_axil.bready = b_bready[S_FLTD];
  assign u_filter_d_s_axil.araddr = b_araddr[8:0];
  assign u_filter_d_s_axil.arvalid = b_arvalid[S_FLTD];
  assign b_arready[S_FLTD] = u_filter_d_s_axil.arready;
  assign b_rdata[S_FLTD*32 +: 32] = u_filter_d_s_axil.rdata;
  assign b_rresp[S_FLTD*2 +: 2] = u_filter_d_s_axil.rresp;
  assign b_rvalid[S_FLTD] = u_filter_d_s_axil.rvalid;
  assign u_filter_d_s_axil.rready = b_rready[S_FLTD];
  blur_sharpen_top #(.N(FILT_N), .C(3), .CW(8), .MAX_W(MAX_W)) u_filter_d (   // display
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .s_axil(u_filter_d_s_axil),
    .s_axis(vd),
    .m_axis(fo)
  );
`elsif VP_INSERT
  assign fo.tdata = vo.tdata;
  assign fo.tlast = vo.tlast;
  assign fo.tuser = vo.tuser;
  assign fo.tkeep = '1;
  assign fo.tvalid = vo.tvalid;
  assign vo.tready = fo.tready;
  assign fa.tdata = vo.tdata;                    // the analysis path watches the same beats
  assign fa.tlast = vo.tlast;
  assign fa.tuser = vo.tuser;
  assign fa.tkeep = '1;
  assign fa.tvalid = vo.tvalid && vo.tready;
  assign fa.tready = 1'b1;
`endif

  // ================================================================ NPU (`VP_NPU)
  // The detector: its frame writer taps vision_system's output (as the model's npu.frame(vis)), its AXI4
  // master is port 1 of the DDR controller, its registers at 0x1_A000; channel 4 of frame_counter marks a
  // finished run when it runs on every frame (AUTO), else the trackers' measurement (as pysim's event 4).
  logic npu_run_done, npu_auto;
`ifdef VP_NPU
  axil_if #(.ADDR_W(8)) u_npu_s_axil ();
  assign u_npu_s_axil.awaddr = b_awaddr[7:0];
  assign u_npu_s_axil.awvalid = b_awvalid[S_NPU];
  assign b_awready[S_NPU] = u_npu_s_axil.awready;
  assign u_npu_s_axil.wdata = b_wdata;
  assign u_npu_s_axil.wstrb = b_wstrb;
  assign u_npu_s_axil.wvalid = b_wvalid[S_NPU];
  assign b_wready[S_NPU] = u_npu_s_axil.wready;
  assign b_bresp[S_NPU*2 +: 2] = u_npu_s_axil.bresp;
  assign b_bvalid[S_NPU] = u_npu_s_axil.bvalid;
  assign u_npu_s_axil.bready = b_bready[S_NPU];
  assign u_npu_s_axil.araddr = b_araddr[7:0];
  assign u_npu_s_axil.arvalid = b_arvalid[S_NPU];
  assign b_arready[S_NPU] = u_npu_s_axil.arready;
  assign b_rdata[S_NPU*32 +: 32] = u_npu_s_axil.rdata;
  assign b_rresp[S_NPU*2 +: 2] = u_npu_s_axil.rresp;
  assign b_rvalid[S_NPU] = u_npu_s_axil.rvalid;
  assign u_npu_s_axil.rready = b_rready[S_NPU];
  logic npu_irq;                                 // (the system model has no NPU interrupt: channel 4 instead)
  npu_top #(
    .ADDR_W(32),
    .ID_W(DDR_ID_W),
    .PE_P(NPU_PE),
    .PE_O(NPU_PE)
  ) u_npu (
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .s_axil(u_npu_s_axil),
    .irq_o(npu_irq),
    .run_done_o(npu_run_done),
    .auto_o(npu_auto),
    .s_axis(vo),
    .m_axi_awid(np_awid),
    .m_axi_awaddr(np_awaddr),
    .m_axi_awlen(np_awlen),
    .m_axi_awsize(np_awsize),
    .m_axi_awburst(np_awburst),
    .m_axi_awvalid(np_awvalid),
    .m_axi_awready(np_awready),
    .m_axi_wdata(np_wdata),
    .m_axi_wstrb(np_wstrb),
    .m_axi_wlast(np_wlast),
    .m_axi_wvalid(np_wvalid),
    .m_axi_wready(np_wready),
    .m_axi_bid(np_bid),
    .m_axi_bresp(np_bresp),
    .m_axi_bvalid(np_bvalid),
    .m_axi_bready(np_bready),
    .m_axi_arid(np_arid),
    .m_axi_araddr(np_araddr),
    .m_axi_arlen(np_arlen),
    .m_axi_arsize(np_arsize),
    .m_axi_arburst(np_arburst),
    .m_axi_arvalid(np_arvalid),
    .m_axi_arready(np_arready),
    .m_axi_rid(np_rid),
    .m_axi_rdata(np_rdata),
    .m_axi_rresp(np_rresp),
    .m_axi_rlast(np_rlast),
    .m_axi_rvalid(np_rvalid),
    .m_axi_rready(np_rready)
  );
  wire unused_npu = &{1'b0, npu_irq, 1'b0};
`else
  assign npu_run_done = 1'b0;
  assign npu_auto = 1'b0;
`endif

  // ================================================================ target tracking and symbol overlay
  // object_tracker watches the analysis path (feature_detect's beats with their features); symbol_overlay
  // draws the CPU's symbols over the display path, last in the insert loop.
`ifdef VP_TRACK
  // one detector per object class (0 pedestrian, 1 face, 2 automobile, 3 other vehicle, 4 aircraft), each in its
  // own window (video_processor_map_pkg: TRK_OFFSET + c * TRK_STRIDE); all watch the same frames, so
  // the enabled ones' done_o pulse together: any of them marks the tracker event
  logic [NTRK-1:0] trk_done;
  assign ev_trk = npu_auto ? npu_run_done : |trk_done;
  // edge and motion features of every pixel, computed once for all the detectors (passive tap on the
  // same stream; the bits belong to the beat they come with)
  logic [1:0] feat;
  logic       feat_done_nc;                      // feature_detect's frame done: the trackers mark the event
  wire        unused_feat = &{1'b0, feat_done_nc, 1'b0};
  axis_if #(.DATA_W(24), .USER_W(1)) fm ();      // feature_detect's output: the beats two clocks later
  axil_if #(.ADDR_W(8)) u_feat_s_axil ();
  assign u_feat_s_axil.awaddr = b_awaddr[7:0];
  assign u_feat_s_axil.awvalid = b_awvalid[S_FEAT];
  assign b_awready[S_FEAT] = u_feat_s_axil.awready;
  assign u_feat_s_axil.wdata = b_wdata;
  assign u_feat_s_axil.wstrb = b_wstrb;
  assign u_feat_s_axil.wvalid = b_wvalid[S_FEAT];
  assign b_wready[S_FEAT] = u_feat_s_axil.wready;
  assign b_bresp[S_FEAT*2 +: 2] = u_feat_s_axil.bresp;
  assign b_bvalid[S_FEAT] = u_feat_s_axil.bvalid;
  assign u_feat_s_axil.bready = b_bready[S_FEAT];
  assign u_feat_s_axil.araddr = b_araddr[7:0];
  assign u_feat_s_axil.arvalid = b_arvalid[S_FEAT];
  assign b_arready[S_FEAT] = u_feat_s_axil.arready;
  assign b_rdata[S_FEAT*32 +: 32] = u_feat_s_axil.rdata;
  assign b_rresp[S_FEAT*2 +: 2] = u_feat_s_axil.rresp;
  assign b_rvalid[S_FEAT] = u_feat_s_axil.rvalid;
  assign u_feat_s_axil.rready = b_rready[S_FEAT];
  feature_detect_top #(
    .MAXW(MAX_W),
    .MAXH(FEAT_MAX_H),
    .CELL_LOG2(FEAT_CELL_LOG2)
  ) u_feat (
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .s_axis(fa),
    .m_axis(fm),
    .feat_o(feat),
    .done_o(feat_done_nc),
    .s_axil(u_feat_s_axil)
  );
  assign fm.tready = 1'b1;                       // feature_detect does not use it
  for (genvar t = 0; t < NTRK; t++) begin : g_trk
    // feature_detect's stream, a copy per detector (Icarus binds an interface port only to an interface
    // instance of the same scope)
    axis_if #(.DATA_W(24), .USER_W(1)) u_track_s_axis ();
    assign u_track_s_axis.tdata = fm.tdata;
    assign u_track_s_axis.tlast = fm.tlast;
    assign u_track_s_axis.tuser = fm.tuser;
    assign u_track_s_axis.tkeep = '1;
    assign u_track_s_axis.tvalid = fm.tvalid;
    assign u_track_s_axis.tready = fm.tready;
    axil_if #(.ADDR_W(9)) u_track_s_axil ();
    assign u_track_s_axil.awaddr = b_awaddr[8:0];
    assign u_track_s_axil.awvalid = b_awvalid[S_TRK + t];
    assign b_awready[S_TRK + t] = u_track_s_axil.awready;
    assign u_track_s_axil.wdata = b_wdata;
    assign u_track_s_axil.wstrb = b_wstrb;
    assign u_track_s_axil.wvalid = b_wvalid[S_TRK + t];
    assign b_wready[S_TRK + t] = u_track_s_axil.wready;
    assign b_bresp[(S_TRK + t)*2 +: 2] = u_track_s_axil.bresp;
    assign b_bvalid[S_TRK + t] = u_track_s_axil.bvalid;
    assign u_track_s_axil.bready = b_bready[S_TRK + t];
    assign u_track_s_axil.araddr = b_araddr[8:0];
    assign u_track_s_axil.arvalid = b_arvalid[S_TRK + t];
    assign b_arready[S_TRK + t] = u_track_s_axil.arready;
    assign b_rdata[(S_TRK + t)*32 +: 32] = u_track_s_axil.rdata;
    assign b_rresp[(S_TRK + t)*2 +: 2] = u_track_s_axil.rresp;
    assign b_rvalid[S_TRK + t] = u_track_s_axil.rvalid;
    assign u_track_s_axil.rready = b_rready[S_TRK + t];
    object_tracker_top u_track (
      .clk(pix_clk),
      .rst_n(pix_rst_n),
      .feat_i(feat),
      .s_axis(u_track_s_axis),                   // the beats with their features
      .done_o(trk_done[t]),
      .s_axil(u_track_s_axil)
    );
  end
  axil_if #(.ADDR_W(10)) u_overlay_s_axil ();
  assign u_overlay_s_axil.awaddr = b_awaddr[9:0];
  assign u_overlay_s_axil.awvalid = b_awvalid[S_OVL];
  assign b_awready[S_OVL] = u_overlay_s_axil.awready;
  assign u_overlay_s_axil.wdata = b_wdata;
  assign u_overlay_s_axil.wstrb = b_wstrb;
  assign u_overlay_s_axil.wvalid = b_wvalid[S_OVL];
  assign b_wready[S_OVL] = u_overlay_s_axil.wready;
  assign b_bresp[S_OVL*2 +: 2] = u_overlay_s_axil.bresp;
  assign b_bvalid[S_OVL] = u_overlay_s_axil.bvalid;
  assign u_overlay_s_axil.bready = b_bready[S_OVL];
  assign u_overlay_s_axil.araddr = b_araddr[9:0];
  assign u_overlay_s_axil.arvalid = b_arvalid[S_OVL];
  assign b_arready[S_OVL] = u_overlay_s_axil.arready;
  assign b_rdata[S_OVL*32 +: 32] = u_overlay_s_axil.rdata;
  assign b_rresp[S_OVL*2 +: 2] = u_overlay_s_axil.rresp;
  assign b_rvalid[S_OVL] = u_overlay_s_axil.rvalid;
  assign u_overlay_s_axil.rready = b_rready[S_OVL];
  symbol_overlay_top #(
    .NOBJ(32),                                       // two banks of 16 (the firmware's tracks; as the model)
    .NTXT(4),
    .FONT_DIR(OVL_FONT_DIR)
  ) u_overlay (
    .clk(pix_clk),
    .rst_n(pix_rst_n),
    .s_axis(fo),
    .m_axis(ir),
    .s_axil(u_overlay_s_axil)
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
