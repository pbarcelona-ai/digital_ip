// ***************
// Filename: video_processor_tb.sv
// Author: FPGA Cores 4 U
// Description: System testbench of video_processor. Nothing is programmed
//   by the testbench: py_soc boots the firmware (sw/video_proc.py with the
//   CPU initialisation sw/video_init.py, compiled by pyc.py) from a SPI flash model
//   and the firmware brings the system up over its external AXI4-Lite
//   window, reporting every step on UART 0. Reset: arst_n (external) resets
//   the CPU system; the core logic (video) stays in reset until the CPU has
//   booted, passed its self-test and written SYSCTL CORE_RESET
//   (core_rst_n_o, checked by test_core_reset). Board models:
//     - spi_flash_bfm holding the firmware image and string table (pyc.py);
//     - camera module: sensor CCI register model (i2c_bfm, address
//       0x36 on I2C 0) and a CSI-2 RAW10 source (csi2_bfm) that
//       streams 32x24 frames only after the firmware releases its reset
//       (GPIO0[0]) and writes "stream on" (register 0x01 = 1); its line
//       blanking grows with the width (a line lasts 11.5 ns per pixel or
//       more, so the 100 MHz core keeps up; a CSI-2 receiver overflow is
//       reported as an error);
//     - I2C EEPROM (i2c_bfm, 0x50 on I2C 1); UART, SPI and GPIO
//       looped back (txd -> rxd, MOSI -> MISO, gpio_o -> gpio_i) for the
//       firmware's peripheral self-test; GPIO0[31] = +quick strap (the
//       firmware then skips the register dumps); GPIO0[28] = +direct strap
//       (direct transcript: the firmware writes only the tracking sections,
//       one character per GPIO1 write, [31:24] = 0xDB, [8] toggling, [7:0]
//       the character, which the testbench writes straight to the
//       transcript: no UART time); GPIO0[30] = image
//       format pin (1 monochrome, 0 colour; the firmware reprograms the ISP
//       on each change and shows the result on GPIO0[2]); GPIO0[29] = image
//       sequence running;
//     - UART 0 receiver (or the GPIO1 transcript port with +direct):
//       decodes the report at UART_BAUD, writes it line by line as it
//       arrives to +TRANSCRIPT=<file> (default sim_transcript_<GIF
//       name>.txt; with several GIFs also each GIF's section 8 to
//       sim_transcript_<GIF name>.txt next to it) and echoes each line as
//       "UART0| ...";
//     - HDMI: tmds_serializer lanes deserialised on the TMDS clock lane and
//       decoded by hdmi_bfm; LVDS link A deserialised on the clock
//       lane and decoded as single-link VESA 24 bpp. Their serial clocks and
//       the camera stop after the video checks (the report runs on);
//     - image test: 4 colour and 4 monochrome images (frame_c_<n>_input.ppm,
//       frame_m_<n>_input.ppm in input_images/, generated when missing) are
//       sent by the camera (colour as a Bayer RGGB mosaic) one frame each.
//       The camera paces the sequence so every image flows through the
//       whole pipeline: the next image starts once vision_system has taken
//       the previous one and can take another (vs_stream_adapter would
//       otherwise drop it), and never sooner than the camera's frame gap
//       (CCI registers 0x20-0x21, ns from the end of one frame to the start
//       of the next, power-on value 1280, programmed by the firmware); the
//       format pin for the next image changes as soon as the previous
//       frame's last line is sent. The firmware clears both frame counters
//       once the pipeline is idle, so the sequence is counted from 0 (one
//       frame sent: count 1, all 8 images: 8 at both stages); it reports
//       every end of frame on UART 0 (counts 1, 2, 3, ... at each stage).
//       The frame of each image at the output of every
//       module (csi2_raw_unpack .. isp_csc, vision_system, blur_sharpen, HDMI,
//       LVDS) is saved as output_images/<module>_<c|m>_<n>_output.ppm (P6).
//       Frames are labelled on their way through the pipeline.
//       Plusargs: +IMG_IN_DIR=<dir>, +IMG_OUT_DIR=<dir>.
//     - pedestrian tracking: an animated GIF (gif_io reader; default
//       tb/images/pedestrian_walk.gif, 128 x 96 black-and-white street
//       video of a pedestrian, 50 frames = 5 s, made by
//       tb/scripts/make_pedestrian_gif.py) sets the tracking frame size: the
//       GIF's own (width a multiple of 4, height even, scaled down to fit
//       320 x 240), loaded at start-up into the camera's control registers
//       0x30-0x33 (width, height, high byte first), which the firmware reads
//       over I2C 0 to reprogram every block (stage 170), and its base name
//       into registers 0x40-0x4F (the overlay's upper-left text). The camera then sends
//       one RAW10 frame per GIF frame; GPIO0[29] is high while it lasts.
//       The frames out of the overlay and on HDMI are captured (HDMI must
//       equal the overlay output) and, with +PYSIM_RGB, compared pixel for
//       pixel with the system model's (pysim) output for the same input -
//       the differences listed per frame with their bounding box (the
//       overlay's clock text shows the run's own time); the HDMI frames are
//       written as an animated GIF with the input's frame times (gif_io
//       writer; gif-output/<input name>_tracked.gif) and read back. LVDS
//       is checked before this and its serial clock is stopped for it.
//       Several GIFs (+GIF_IN=<a.gif>,<b.gif>,...) are sent one after the
//       other in one run: the camera's register 0x56 holds their count,
//       0x57 the number of the GIF whose size, name and options are loaded;
//       the firmware sets every block up again for each (section 8 per
//       GIF) and each GIF is checked and written on its own.
//       Plusargs: +GIF_IN=<file>[,<file>...] (any animated GIFs),
//       +GIF_BW (convert a colour GIF to black and white; otherwise it is
//       sent in colour as an RGGB mosaic), +GIF_DIR=<dir> (GIF outputs,
//       default gif-output), +GIF_IN_DIR=<dir> (the input sequence as sent,
//       default gif-input), +GIF_OUT=<file>, +GIF_FRAMES=<n>
//       (send only the first n frames, a shorter run), +GIF_FIRST=<n>
//       (start at frame n: a long GIF run in parts),
//       +DETECT=<classes> (pedestrian, face, automobile / car, vehicle /
//       bus, aircraft / plane, comma separated, or all; default all),
//       +BOX=<style> or +BOX=<class>:<style>,... (dashed-box, solid-box,
//       dashed-circle, solid-circle, dashed-oval, solid-oval, solid-centre,
//       corner-box, tick-box, triangle; default corner-box for pedestrians
//       and faces, tick-box for automobiles and vehicles, triangle for
//       aircraft: make pysim's), +TARGETS=<n> (most targets tracked at a
//       time, 1-32, camera register 0x58; default 32), +PYSIM_RGB=<file>
//       (make pysim --raw output for the same input: the output frames
//       compared pixel for pixel), +TRANSCRIPT=<file>, +direct.
//     - object detection: without +NPU_HEX the firmware's feature detectors
//       (sw/tracker.py: object_tracker x 5 on feature_detect's features, up
//       to 32 overlay objects); the DDR holds no NPU program (ddr_mem reads
//       0: no "NPU8" header), as make pysim --no-npu. With +NPU_HEX=<file>
//       (pysim --raw with an NPU program: <name>_npu_ddr.hex; the system test
//       uses the small network of ip/ai/npu/scripts/make_tiny_model.py at
//       128 x 128) the program and its header are preloaded in the DDR and
//       the firmware runs the NPU on every frame (AUTO) with its ByteTrack
//       tracking; +PYSIM_DETS=<file> (<name>_pysim_dets.txt) compares every
//       run's detection list in the DDR with pysim's, word for word. Each
//       frame is sent only after the firmware committed the previous one's
//       result (trk_frames), as pysim: no frame arrives during an NPU run.
//       The NPU is built with an 8 x 8 MAC array here (NPU_PE: simulation
//       speed; its results do not depend on it). A ground truth file <GIF name>.truth.txt next to the
//       GIF is read and listed (the tracking itself is judged by the
//       comparison with pysim).
//   The test tasks are in tests/video_processor_tests.sv (`included).
//   With `VP_DDR the board's DDR is ddr_mem on the DFI-style pins; the run
//   fails if it reports a timing violation. Prints TEST PASSED on success.
// Date: 2026-10-26
`timescale 1ns/1ps
module video_processor_tb;
  `include "video_proc_syms.svh"
`ifndef VP_FONT_DIR
  `define VP_FONT_DIR ""                             // symbol_overlay's smooth-font ROMs (run_sim.sh sets it)
`endif
  localparam int W = 32, H = 24;
  // the tracking frames' largest size (GMAXW x GMAXH: the DUT's MAX_W / FEAT_MAX_H / VS_RET_FIFO and the HDMI sink
  // are sized for it) and the frames kept; `VP_TB_FULL (run_sim.sh --full-size): native 1920 x 1080, one frame
`ifdef VP_TB_FULL
  localparam int GMAXW = 1920, GMAXH = 1080, GMAXF = 2;
`else
  localparam int GMAXW = 320, GMAXH = 240, GMAXF = 128;
`endif
  // Board: 33.333 MHz reference oscillator and the camera's D-PHY byte clock. Every other clock
  // is generated by the DUT (py_soc clock generator): CPU 200 MHz, core 100 MHz, TMDS 1 GHz,
  // LVDS 700 MHz, MIPI TX byte 125 MHz; the firmware turns the display serial clocks on at its
  // video set-up (stage 4). The testbench uses the generated clocks for its models and checks.
  logic ref_clk = 0, byte_clk = 0, arst_n = 0;
  always #15  ref_clk = ~ref_clk;                    // 33.333 MHz
  always #4   byte_clk = ~byte_clk;                  // 125 MHz camera D-PHY byte clock (1 Gbit/s per lane)
  wire cpu_clk = dut.cpu_clk, pix_clk = dut.pix_clk;
  wire tmds_ser_clk = dut.tmds_ser_clk, lvds_ser_clk = dut.lvds_ser_clk;
  bit cam_run = 1;                                   // the camera stops after the video checks
  localparam int UART_BAUD = 6_250_000;              // report speed: the UART allows baud * 16 <= f_clk / 2
  localparam int MIN_PASS = 31;                      // [PASS] lines the firmware report must contain
  localparam logic [3:0] CLK_EN_IDLE = 4'b1001;      // core and MIPI byte clocks only
  localparam logic [3:0] CLK_EN_TRACK = 4'b1011;     // tracking test: LVDS serial clock stopped (simulation speed)
  int errors = 0;
  initial begin
    #300ms;
    $display("ERROR: simulation timeout (firmware stage %0d)", g(G_stage));
    $display("TEST FAILED");
    $finish;
  end

  // ---------------- DUT ----------------
  logic fl_sclk, fl_cs_n, fl_mosi, fl_miso;
  int fl_wip;
  logic [1:0] uart_txd, scl_o, scl_t, sda_o, sda_t, spi_sclk, spi_mosi;
  logic [3:0] spi_cs_n;
  logic [95:0] gpio_o, gpio_t;
  logic boot_done, boot_err, trap, wdt_reset, sdone, core_rst_n;
  logic [15:0] cam_d;
  logic [1:0] cam_v;
  logic [3:0] tmds_ser;
  logic [4:0] lvds_a_ser, lvds_b_ser;
  logic [15:0] dsi_d, ctx_d;
  logic [1:0] dsi_v, ctx_v;
  logic dsi_req, ctx_req;
  wire  [63:0] sdram_dq;
  wire sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n;
  wire [12:0] sd_a;
  wire [1:0] sd_ba;
  wire [7:0] sd_dqm;
  // DDR memory behind the controller's DFI-style pins (`VP_DDR): 8 banks x 512 rows x 256 words of 256
  // bits, 32 MB; vision_system's frame buffers moved into it (0x0180_0000, 0x01C0_0000: 4 MB each)
  localparam int DDR_BANK_W = 3, DDR_ROW_W = 9, DDR_COL_W = 8, DDR_T_REFI = 780;
  logic         dfi_clk, dfi_rst_n, dfi_rv, ddr_err;
  logic [2:0]   dfi_cmd;
  logic [DDR_BANK_W-1:0] dfi_bank;
  logic [DDR_ROW_W-1:0]  dfi_row;
  logic [DDR_COL_W-1:0]  dfi_col;
  logic [255:0] dfi_wrdata, dfi_rddata;
  logic [31:0]  dfi_wrstrb;
  logic [3:0]   ddr_err_code;
  logic [15:0]  ddr_err_cnt;
  tri1 sda0, scl0, sda1, scl1;
  wire quick_strap = $test$plusargs("quick");
  wire direct_strap = $test$plusargs("direct");      // direct transcript (GPIO0[28])
  bit  mono_sel = 1;                                 // image format pin (GPIO0[30]): 1 monochrome, 0 colour
  bit  seq_active = 0;                               // image sequence pending (GPIO0[29])

  video_processor #(
    .NLANES(2),
    .MAX_W(GMAXW > 320 ? 2048 : 320),                // tracking test frames up to GMAXW x GMAXH
    .FEAT_MAX_H(GMAXH > 240 ? 1088 : 240),
    .FEAT_CELL_LOG2(2),                              // feature_detect: 4 x 4 background cells
    .VS_RET_FIFO(GMAXW > 320 ? 2097152 : 131072),    // a whole frame
    .VS_ADDR_W(GMAXW > 320 ? 21 : barrel_pkg::ADDR_W),   // vision_system's store: a whole frame
    .CSI_FIFO(256),
    .OUT_FIFO(512),
    .UART0_BAUD(UART_BAUD),
    .UART1_BAUD(UART_BAUD),
    .I2C0_HZ(2_000_000),
    .I2C1_HZ(2_000_000),
    .SPI0_HZ(10_000_000),
    .SPI1_HZ(10_000_000), // fast rates: short simulation
    .FLASH_CLKDIV(3),
    .PLL_MISMATCH_PPM(20_000),
    .NPU_PE(8),                                      // an 8 x 8 MAC array: simulation speed (results equal)
    .VS_DDR_FB0(32'h0180_0000),
    .VS_DDR_FB1(32'h01C0_0000),
    .DDR_BANK_W(DDR_BANK_W),
    .DDR_ROW_W(DDR_ROW_W),
    .DDR_COL_W(DDR_COL_W),
    .DDR_T_REFI(DDR_T_REFI),
    .OVL_FONT_DIR(`VP_FONT_DIR)
  ) dut (
    .arst_n,
    .ref_clk,
    .flash_sclk_o(fl_sclk),
    .flash_cs_n_o(fl_cs_n),
    .flash_mosi_o(fl_mosi),
    .flash_miso_i(fl_miso),
    .uart_txd_o(uart_txd),
    .uart_rxd_i(uart_txd),
    .i2c_scl_i({scl1, scl0}),
    .i2c_scl_o(scl_o),
    .i2c_scl_t(scl_t),
    .i2c_sda_i({sda1, sda0}),
    .i2c_sda_o(sda_o),
    .i2c_sda_t(sda_t),
    .spi_sclk_o(spi_sclk),
    .spi_mosi_o(spi_mosi),
    .spi_miso_i(spi_mosi),
    .spi_cs_n_o(spi_cs_n),
    .gpio_i({gpio_o[95:32], quick_strap, mono_sel, seq_active, direct_strap, gpio_o[27:0]}),
    .gpio_o,
    .gpio_t,
    .ext_irq_i(1'b0),
    .boot_done_o(boot_done),
    .boot_err_o(boot_err),
    .cpu_trap_o(trap),
    .wdt_reset_o(wdt_reset),
    .core_rst_n_o(core_rst_n),
`ifdef VP_CSI2_RX
    .byte_clk,
    .cam_lane_data_i(cam_d),
    .cam_lane_valid_i(cam_v),
`endif
`ifdef VP_HDMI
    .tmds_serial_o(tmds_ser),
`endif
`ifdef VP_LVDS
    .lvds_a_serial_o(lvds_a_ser),
    .lvds_b_serial_o(lvds_b_ser),
`endif
`ifdef VP_DSI
    .dsi_lane_data_o(dsi_d),
    .dsi_lane_valid_o(dsi_v),
    .dsi_hs_req_o(dsi_req),
    .dsi_tx_ready_i(1'b0),
`endif
`ifdef VP_CSI2_TX
    .csitx_lane_data_o(ctx_d),
    .csitx_lane_valid_o(ctx_v),
    .csitx_hs_req_o(ctx_req),
    .csitx_tx_ready_i(1'b0),
`endif
`ifdef VP_VISION
    .sdram_clk(sd_clk),
    .sdram_cke(sd_cke),
    .sdram_cs_n(sd_cs_n),
    .sdram_ras_n(sd_ras_n),
    .sdram_cas_n(sd_cas_n),
    .sdram_we_n(sd_we_n),
    .sdram_a(sd_a),
    .sdram_ba(sd_ba),
    .sdram_dqm(sd_dqm),
    .sdram_dq(sdram_dq),
`endif
`ifdef VP_DDR
    .dfi_clk_o(dfi_clk),
    .dfi_rst_n_o(dfi_rst_n),
    .dfi_cmd_o(dfi_cmd),
    .dfi_bank_o(dfi_bank),
    .dfi_row_o(dfi_row),
    .dfi_col_o(dfi_col),
    .dfi_wrdata_o(dfi_wrdata),
    .dfi_wrstrb_o(dfi_wrstrb),
    .dfi_rddata_valid_i(dfi_rv),
    .dfi_rddata_i(dfi_rddata),
`endif
    .stats_done_o(sdone));
`ifdef VP_DDR
  ddr_mem #(
    .DATA_W(256),
    .BANK_W(DDR_BANK_W),
    .ROW_W(DDR_ROW_W),
    .COL_W(DDR_COL_W),
    .MEM_WORDS(1 << (DDR_BANK_W + DDR_ROW_W + DDR_COL_W)),
    .T_RCD(4),
    .T_RP(4),
    .T_RAS(10),
    .T_CL(5),
    .T_WR(4),
    .T_RTP(2),
    .T_WTR(2),
    .T_RRD(2),
    .T_RFC(30),
    .REF_MAX(9 * DDR_T_REFI)
  ) ddr (
    .clk(dfi_clk),
    .rst_n(dfi_rst_n),
    .cmd_i(dfi_cmd),
    .bank_i(dfi_bank),
    .row_i(dfi_row),
    .col_i(dfi_col),
    .wrdata_i(dfi_wrdata),
    .wrstrb_i(dfi_wrstrb),
    .rddata_valid_o(dfi_rv),
    .rddata_o(dfi_rddata),
    .err_o(ddr_err),
    .err_code_o(ddr_err_code),
    .err_cnt_o(ddr_err_cnt)
  );
`endif
`ifndef VP_HDMI
  assign tmds_ser = '0;
`endif
`ifndef VP_LVDS
  assign lvds_a_ser = '0;
  assign lvds_b_ser = '0;
`endif

  // ---------------- board: flash, I2C, camera ----------------
  spi_flash_bfm #(.MEM_BYTES(1 << 17)) flash (   // 128 KB: boot image + 1024-slot string table
    .sclk(fl_sclk),
    .cs_n(fl_cs_n),
    .mosi(fl_mosi),
    .miso(fl_miso),
    .wip_cycles(fl_wip)
  );
  assign sda0 = sda_t[0] ? 1'bz : sda_o[0];
  assign scl0 = scl_t[0] ? 1'bz : scl_o[0];
  assign sda1 = sda_t[1] ? 1'bz : sda_o[1];
  assign scl1 = scl_t[1] ? 1'bz : scl_o[1];
  i2c_bfm #(.ADDR(7'h36)) sensor_cci (
    .sda(sda0),
    .scl(scl0)
  );
  i2c_bfm #(.ADDR(7'h50)) eeprom (
    .sda(sda1),
    .scl(scl1)
  );
  csi2_bfm #(.NL(2)) cam (
    .clk(byte_clk),
    .lane_data(cam_d),
    .lane_valid(cam_v)
  );

  int raw [H][W];
  initial for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) raw[y][x] = 64 + ((37 * x + 91 * y + 13 * x * y) % 900);
  // Expected output: ISP bypassed (raw value on R, G and B, 10 -> 8 bit), vision_system identity.
  // vision_system's Q16.16 coordinate arithmetic may round a sample by 1 LSB (its own regression
  // accepts max error 1): its output is checked within 1 of this.
  function automatic logic [23:0] ex(input int x, input int y);
    logic [7:0] v;
    v = 8'(raw[y][x] >> 2);
    return {v, v, v};
  endfunction

  // ---------------- image test: inputs, frame labels, module output taps ----------------
  // Label of a frame: 0-3 colour image n, 4-7 monochrome image n, -1 the synthetic raw[][] image.
  localparam int NIMG = 8, NT = 11;
  localparam int T_UNPACK = 0, T_BLC = 1, T_DPC = 2, T_DEMOSAIC = 3, T_CCM = 4, T_GAMMA = 5, T_CSC = 6,
                 T_VISION = 7, T_FILTER = 8, T_HDMI = 9, T_LVDS = 10;
  logic [23:0] in_img [NIMG][H][W];                  // input images {B, G, R}
  logic [23:0] io_img [H][W];                        // PPM read / write buffer
  logic [23:0] tap_img [NT][H][W];                   // frame being captured at each tap
  logic [23:0] out_img [NT][NIMG][H][W];             // first complete frame of each image at each tap
  bit   tap_saved [NT][NIMG];
  int   tap_x [NT], tap_y [NT], tap_lab [NT], tap_done_lab [NT];
  int   lq [NT][16]; // label FIFO towards each tap
  int lq_w [NT], lq_r [NT];
  bit   img_mode = 0;                                // camera: 0 live raw[][] frames, 1 the image sequence
  bit   img_go = 0;                                  // image sequence: start sending (pipeline empty)
  int   img_next = 0;                                // next image of the sequence
  int   vs_f0 = 0;                                   // vs_stream_adapter frames_o when the sequence starts
  int   vs_out_frames = 0, vs_out_lines = 0;         // corrected frames fully out of vision_system; lines of the current one
  int   vso0 = 0;                                    // vs_out_frames when the sequence starts
  longint trk_f0 = 0;                                // firmware trk_frames when the tracking sequence starts
  string img_in_dir = "input_images", img_out_dir = "output_images";

  // ---------------- tracking test: GIF in, captures, GIF out ----------------
  // Frame size: the GIF's own (width rounded down to a multiple of 4 for RAW10 packing, height to
  // an even number for the Bayer pattern), scaled down keeping the aspect ratio when larger than
  // GMAXW x GMAXH (declared above), at least 16 x 16.
  localparam int NOBJ = 32, NTR = 3;                 // overlay objects (the firmware's NPU tracks); true boxes per class
  localparam int LAB_GIF = 1000;                     // camera label of GIF frame 0
  int   gw = 128, gh = 96;                           // tracking frame size (camera registers 0x30-0x33)
  gif_io #(
    .MAXW(GMAXW),
    .MAXH(GMAXH),
    .MAXF(GMAXF)
  ) gin ();    // input sequence
  gif_io #(
    .MAXW(GMAXW),
    .MAXH(GMAXH),
    .MAXF(GMAXF)
  ) gout ();   // HDMI frames written as the output GIF
  gif_io #(
    .MAXW(GMAXW),
    .MAXH(GMAXH),
    .MAXF(GMAXF)
  ) gchk ();   // the output GIF read back
  gif_io #(
    .MAXW(GMAXW),
    .MAXH(GMAXH),
    .MAXF(GMAXF)
  ) ovl_out ();// frames out of the overlay
  gif_io #(
    .MAXW(GMAXW),
    .MAXH(GMAXH),
    .MAXF(GMAXF)
  ) gref ();   // the system model's output frames (make pysim GIF=<in> FIT=320x240 RAW=1)
  string gif_in = "input_images/pedestrian_walk.gif", gif_dir = "gif-output", gif_in_dir = "gif-input", gif_out = "";
  string pysim_rgb = "";                             // +PYSIM_RGB=<path>: the pysim output frames to compare with
  int   gif_n = 0, gif_next = 0;                     // frames to send, next one
  int   gif_first = 0;                               // +GIF_FIRST=<n>: the first GIF frame sent
  bit   gif_go = 0, gif_on = 0;                      // sending; capturing
  bit   gif_bw = 0, gif_colour = 0;                  // +GIF_BW: convert a colour GIF to black and white
  // detection options (+DETECT, +BOX, +TARGETS), as make pysim: classes 0 pedestrian, 1 face, 2 automobile,
  // 3 vehicle, 4 aircraft, loaded into the camera's control registers 0x50 (bit c), 0x51-0x55 (style of
  // class c: 0 dashed box, 1 solid box, 2 dashed circle, 3 solid circle, 4 dashed oval, 5 solid oval,
  // 6 solid box in the middle, 7 dashed box with solid corners, 8 dashed box with ticks, 9 dashed
  // triangle with solid vertices) and 0x58 (most targets)
  localparam int NCLS = 5;
  logic [NCLS-1:0] det_mask = '1;                    // all classes (pysim --detect all)
  int   det_style [NCLS] = '{7, 7, 8, 8, 9};         // pysim DEFAULT_STYLES
  int   max_targets = NOBJ;
  string det_name [NCLS] = '{"pedestrian", "face", "automobile", "vehicle", "aircraft"};
  string style_name [10] = '{"dashed box", "solid box", "dashed circle", "solid circle", "dashed oval", "solid oval",
                             "solid box in the middle", "corner box", "tick box", "triangle"};
  string gif_list [$];                               // +GIF_IN=<a>,<b>,...: the GIFs, sent one after the other
  int   gif_idx = 0;                                 // the one being sent
  // ground truth (<GIF name>.truth.txt next to the GIF, when there is one): box of class c in frame k
  int   truth_box [GMAXF][4][NTR][4];                // up to NTR true boxes per class and frame
  int   truth_n [GMAXF][4];
  bit   truth_ok [GMAXF][4];
  bit   truth_file = 0;
  bit   trk_done [GMAXF], hdmi_saved [GMAXF];
`ifdef VP_NPU
  // +NPU_HEX=<file> (make pysim RAW=1 with an NPU program: <name>_npu_ddr.hex): the NPU program and its header
  // preloaded in the DDR, as a boot loader would (without it the DDR reads 0: no "NPU8" header, the feature
  // detectors). +PYSIM_DETS=<file> (<name>_pysim_dets.txt): every NPU run of the tracking sequence compared
  // with pysim's, its detection list in the DDR word for word (read 2000 pix_clk after the run's end: its
  // writes are done, the next frame's run has not started).
  localparam int NPU_MAXR = 256, NPU_MAXW = 64 * 4 * NPU_MAXR;
  string npu_hex = "", pysim_dets = "";
  int    npu_runs = 0, npu_bad = 0, npu_exp_runs = -1;
  int    npu_exp_n [NPU_MAXR], npu_exp_off [NPU_MAXR];
  logic [31:0] npu_exp_w [NPU_MAXW];
  initial begin
    if ($value$plusargs("NPU_HEX=%s", npu_hex)) begin
      #1;                                              // after ddr_mem's own clearing at time 0
      $readmemh(npu_hex, ddr.mem);
      $display("  DDR: NPU program and header preloaded from %s", npu_hex);
    end
    if ($value$plusargs("PYSIM_DETS=%s", pysim_dets)) begin
      int fd, n, off;
      fd = $fopen(pysim_dets, "r");
      if (fd == 0 || $fscanf(fd, "%d", npu_exp_runs) != 1) npu_exp_runs = -1;
      off = 0;
      for (int r = 0; r < npu_exp_runs && r < NPU_MAXR; r++) begin
        if ($fscanf(fd, "%d", n) != 1) n = -1;
        npu_exp_n[r] = n;
        npu_exp_off[r] = off;
        for (int i = 0; i < 4 * n && off < NPU_MAXW; i++) begin
          if ($fscanf(fd, "%h", npu_exp_w[off]) != 1) npu_exp_n[r] = -1;
          off++;
        end
      end
      if (fd != 0) $fclose(fd);
      $display("  NPU: %0d runs expected (%s)", npu_exp_runs, pysim_dets);
    end
  end
  function automatic logic [31:0] ddr_word32(input logic [31:0] a);   // byte address a (4-aligned)
    ddr_word32 = ddr.mem[a[31:5]][32*a[4:2] +: 32];
  endfunction
  task automatic npu_check_run();                     // the run's index taken at its start (forked per run)
    int r, n, b;
    logic [31:0] a;
    r = npu_runs;
    npu_runs++;
    repeat (2000) @(posedge pix_clk);
    n = int'(dut.u_npu.u_core.det_count);
    a = dut.u_npu.u_core.det_addr;
    b = 0;
    if (r >= npu_exp_runs || r >= NPU_MAXR || npu_exp_n[r] != n) b = 1;
    else for (int i = 0; i < 4 * n; i++) if (ddr_word32(a + 32'(4 * i)) !== npu_exp_w[npu_exp_off[r] + i]) b++;
    if (b > 0) begin
      if (npu_bad < 8)
        $display("  NPU run %0d: %0d detections (pysim %0d), %0d words differ from pysim", r + 1, n,
                 (r < npu_exp_runs && r < NPU_MAXR) ? npu_exp_n[r] : -1, b);
      npu_bad++;
    end
  endtask
  // the sequence's timing with the NPU (its runs end, the firmware commits each frame): where the time goes
  // (trk_frames read every 256 cpu_clk, 1.28 us: a firmware global read on every clock slows the run)
  longint npu_commits = 0;
  bit     npu_mode = 0;                              // +NPU_HEX given (set once, cheaper than a string compare)
  logic [7:0] npu_div = '0;
  initial npu_mode = $test$plusargs("NPU_HEX=");
  always @(posedge cpu_clk) if (npu_mode && gif_on) begin
    npu_div <= npu_div + 8'd1;
    if (npu_div == '0 && g(G_trk_frames) - trk_f0 != npu_commits) begin
      npu_commits = g(G_trk_frames) - trk_f0;
      $display("[%t] NPU sequence: firmware committed frame %0d (trk_frames)", $realtime, npu_commits);
    end
  end
  always @(posedge pix_clk) if (npu_mode && dut.ev_vs_out && gif_on)
    $display("[%t] NPU sequence: corrected frame starts out of vision_system (frame writer)", $realtime);
  always @(posedge pix_clk) if (npu_mode && dut.u_npu.run_done_o && gif_on)
    $display("[%t] NPU sequence: run done, %0d detections", $realtime, dut.u_npu.u_core.det_count);
  always @(posedge pix_clk) if (dut.u_npu.run_done_o && gif_on) begin
    if (npu_exp_runs >= 0) begin
      fork
        npu_check_run();
      join_none
    end else begin
      npu_runs++;
    end
  end
`endif
  int   fo_k = -1, fo_x = 0, fo_y = 0, ir_k = -1, ir_x = 0, ir_y = 0, ir_done = -1, hdmi_frames = 0;
  int   fc_snap0 = -1, fc_snap1 = -1;                // frame counts when the tracking section starts
  // SYSCTL CLK_EN overridden by the testbench (simulation speed only): clocks(en) from the first call on
  logic [3:0] clk_en_tb;
  bit clk_en_ovr = 0;
  initial begin
    wait (clk_en_ovr);
    force dut.u_cpu.clk_en = clk_en_tb;
  end
  task automatic clocks(input logic [3:0] en);
    clk_en_tb = en;
    clk_en_ovr = 1;
  endtask
  // Firmware set-up report (stages 4-5: every register write reported, every register printed; the
  // camera is not streaming): the display serial clocks (HDMI TMDS, LVDS) are held low until the
  // video start (stage 6). Simulation speed only: the clock generator, its lock and the SYSCTL CLK_EN
  // register are untouched (the serial clock nets are forced, not the enables), and no video reaches
  // the displays before stage 6.
  initial begin
    while (g(G_stage) < 4) @(posedge cpu_clk);
    force dut.tmds_ser_clk = 1'b0;
    force dut.lvds_ser_clk = 1'b0;
    $display("[%t] set-up report: display serial clocks held until the video start (simulation speed)", $realtime);
    while (g(G_stage) < 6 && g(G_stage) != 200) @(posedge cpu_clk);
    release dut.tmds_ser_clk;
    release dut.lvds_ser_clk;
  end
  initial for (int t = 0; t < NT; t++) begin
    tap_x[t] = 0;
    tap_y[t] = 2 * H;
    tap_lab[t] = -1;
    tap_done_lab[t] = -1;
    lq_w[t] = 0;
    lq_r[t] = 0;
    for (int i = 0; i < NIMG; i++) tap_saved[t][i] = 0;
  end

  // Camera control registers 0x20-0x21: frame gap in ns (end of one frame to the start of the next),
  // power-on value 1280; applied after every frame end packet, in byte clocks (8 ns)
  initial begin
    #1;
    sensor_cci.mem[8'h20] = 8'h05;
    sensor_cci.mem[8'h21] = 8'h00;
  end
  function automatic int frame_gap_ns();
    return {sensor_cci.mem[8'h20], sensor_cci.mem[8'h21]};
  endfunction

  int cam_frames = 0;
  wire cam_on = gpio_o[0] && !gpio_t[0] && sensor_cci.mem[8'h01] == 8'h01;
  initial begin
    wait (cam_on);
    $display("[%t] camera released from reset and streaming (I2C 0x36 reg 0x01 = 1)", $realtime);
    while (cam_run) begin
      int lab, fw, fh;
      if (gif_go && gif_next < gif_n) begin            // tracking sequence: the next GIF frame
`ifdef VP_VISION
        if (gif_next > 0) begin                        // paced like the image sequence
          wait (dut.u_vs_adapt.frames_o >= vs_f0 + gif_next);
          wait (vs_out_frames >= vso0 + gif_next);        // and its corrected frame is all out
          wait (dut.va.tready && dut.u_vs_adapt.ret_empty);
          @(posedge byte_clk);
        end
`endif
        // the GIF's frame period is compressed: send the next frame once the firmware has handled the
        // previous tracker event (box moved and committed, tracking.py trk_frames), as at the real rate
        if (gif_next > 0) while (g(G_trk_frames) - trk_f0 < gif_next) @(posedge byte_clk);
        lab = LAB_GIF + gif_next;
        gif_next++;
      end
      else if (!img_mode) lab = -1;                    // live: the synthetic raw[][] image
      else if (img_go && img_next < NIMG) begin
`ifdef VP_VISION
        // pace the sequence: the next image once vision_system has taken the previous one, returned
        // all of its corrected frame and can take another (ready, return FIFO empty), so
        // vs_stream_adapter drops none of them (a frame arriving while the previous corrected frame
        // is still coming back would be dropped)
        if (img_next > 0) begin
          wait (dut.u_vs_adapt.frames_o >= vs_f0 + img_next);
          wait (vs_out_frames >= vso0 + img_next);        // and its corrected frame is all out
          wait (dut.va.tready && dut.u_vs_adapt.ret_empty);
          @(posedge byte_clk);
        end
`endif
        lab = img_next;
        img_next++;
      end
      else lab = -2;                                   // waiting for the start, or sequence sent: idle
      if (lab == -2) @(posedge byte_clk);
      else begin
        fw = (lab >= LAB_GIF) ? gw : W;
        fh = (lab >= LAB_GIF) ? gh : H;
        lq_push(T_UNPACK, (lab >= LAB_GIF) ? -3 : lab); // label of this frame, in camera order
        cam.gap = 4;
        cam.csi_pay.delete();
        cam.csi_packet(2'd0, 6'h00, 16'(cam_frames + 1));
        cam.send_pkt();
        for (int y = 0; y < fh; y++) begin
          cam.csi_px.delete();
          for (int x = 0; x < fw; x++)
            cam.csi_px.push_back(lab >= LAB_GIF ? gif_px(lab - LAB_GIF, x, y) : lab < 0 ? 10'(raw[y][x]) : sensor_px(lab, x, y));
          cam.csi_pack_raw10();
          cam.csi_packet(2'd0, 6'h2B, 16'(cam.csi_pay.size()));
          // line blanking: a line lasts at least 11.5 ns per pixel (byte clock 8 ns, 2 lanes), so the
          // core (csi2_raw_unpack, 1 pixel per 10 ns clock) keeps up with wide frames and the CSI-2
          // FIFO never overflows (a 320-pixel RAW10 line is 400 bytes: 1.6 us on the lanes, 3.2 us
          // to unpack); 110 byte clocks at least (frames up to 128 wide: the original timing)
          cam.gap = (fw * 23 / 16 - int'(cam.csi_pay.size()) / 2 > 110) ? fw * 23 / 16 - int'(cam.csi_pay.size()) / 2 : 110;
          cam.send_pkt();
        end
        // last line sent: the next image's format goes to the pin now, the firmware reprograms the
        // ISP during the frame gap; after the last image the sequence ends
        if (img_mode && img_next < NIMG) mono_sel = (img_next >= 4);
        if (img_mode && lab == NIMG - 1) seq_active = 0;
        if (lab == LAB_GIF + gif_n - 1) seq_active = 0;  // tracking sequence sent
        if (lab >= LAB_GIF) begin
          $display("[%t] camera: GIF frame %0d of %0d sent", $realtime, lab - LAB_GIF + 1, gif_n);
          $fflush();
        end
        cam.csi_pay.delete();
        cam.csi_packet(2'd0, 6'h01, 16'(cam_frames + 1));
        cam.gap = (frame_gap_ns() + 7) / 8;
        cam.send_pkt();
        cam_frames++;
      end
    end
  end

`ifdef VP_CSI2_RX
  // CSI-2 payload lost (the receiver's FIFO to the core full): the camera sends faster than the core
  // unpacks; lines lose their ends and the frame never completes, so say so at once
  int csi_ovf = 0;
  always @(posedge dut.u_pipe.u_csi.clk) if (dut.u_pipe.u_csi.overflow_o) begin
    if (csi_ovf == 0) $display("ERROR @%0t: CSI-2 receiver overflow (camera frame %0d): payload lost, the camera's line rate is above the core's", $time, cam_frames + 1);
    if (csi_ovf == 0) errors++;
    csi_ovf++;
  end
`endif

  // ---------------- HDMI: TMDS lanes -> tmds_bfm (deserialise, LSB first) -> hdmi_bfm (decode) ----------------
  logic [9:0] tw0, tw1, tw2;
  logic trclk, tlocked;
  tmds_bfm tmds (
    .ser_clk(tmds_ser_clk),
    .lanes(tmds_ser),
    .ch0(tw0),
    .ch1(tw1),
    .ch2(tw2),
    .sym_clk(trclk),
    .locked(tlocked)
  );
`ifdef VP_HDMI
  wire sink_en = tlocked;
`else
  wire sink_en = 1'b0;
`endif
  hdmi_bfm #(
    .MAXW(GMAXW),
    .MAXH(GMAXH)
  ) sink (
    .clk(trclk),
    .en(sink_en),
    .ch0(tw0),
    .ch1(tw1),
    .ch2(tw2)
  );

  // ---------------- LVDS link A: lvds_bfm (deserialise bit 6 first, decode VESA 24 bpp) ----------------
  lvds_bfm #(
    .NDATA(4),
    .MAXW(W),
    .MAXH(H)
  ) lvds (
    .ser_clk(lvds_ser_clk),
    .lanes(lvds_a_ser)
  );
  always @(lvds.frame_done) display_done(T_LVDS);

  // ---------------- firmware globals and traps ----------------
  function automatic longint g(input int idx);
    logic [33:0] v;
    v = dut.u_cpu.u_core.globals[idx];
    return v[0] ? longint'($signed(v) >>> 1) : -999;
  endfunction
  longint last_stage = -1;
  always @(posedge cpu_clk) if (arst_n) begin
    if (g(G_stage) != last_stage) begin
      last_stage = g(G_stage);
      $display("[%t] firmware stage %0d", $realtime, last_stage);
    end
    if (trap) begin
      $display("ERROR @%0t: core trap, cause %0d at pc 0x%0h (1 illegal, 2 type, 3 overflow, 4 stack / call depth, 5 bus, 6 index; see build/fw/video_proc.lst)",
               $time, dut.u_cpu.u_core.trap_cause_o, dut.u_cpu.u_core.trap_pc_o);
      $display("TEST FAILED");
      $finish;
    end
  end

  // ---------------- vision_system output capture (all frames must be identical: static scene) ----------------
  logic [23:0] vs_frame [H][W];
  logic [23:0] exp_img [H][W];
  int vs_x = 0, vs_y = 0, vs_frames = 0, vs_changes = 0;
  bit vs_diff = 0;
`ifdef VP_VISION
  always @(posedge pix_clk) if (dut.vr.tvalid && dut.vr.tready) begin
    if (dut.vr.tuser) begin
      vs_x = 0;
      vs_y = 0;
      vs_diff = 0;
    end
    if (vs_y < H && vs_x < W) begin
      if (vs_frames > 0 && vs_frame[vs_y][vs_x] !== dut.vr.tdata) vs_diff = 1;
      vs_frame[vs_y][vs_x] = dut.vr.tdata;
    end
    if (dut.vr.tlast) begin
      vs_x = 0;
      vs_y++;
      if (vs_y == H) begin
        if (vs_diff && vs_frames > 0) vs_changes++;
        vs_frames++;
      end
    end else vs_x++;
  end
`endif
  conv2d_ref #(
    .N(5),
    .C(3),
    .CW(8),
    .MAXW(W),
    .MAXH(H)
  ) mdl ();

  // Module output taps (image test). One block, upstream first, so a label is passed on before it is
  // needed downstream. 10-bit components are shown as 8 bits; a raw (Bayer) value as grey.
  always @(posedge pix_clk) begin
    if (dut.u_pipe.u.tvalid && dut.u_pipe.u.tready) tap_pixel(T_UNPACK, raw8(dut.u_pipe.u.tdata), dut.u_pipe.u.tlast, dut.u_pipe.u.tuser);
    if (dut.u_pipe.g.tvalid && dut.u_pipe.g.tready) tap_pixel(T_BLC, raw8(dut.u_pipe.g.tdata), dut.u_pipe.g.tlast, dut.u_pipe.g.tuser);
    if (dut.u_pipe.p.tvalid && dut.u_pipe.p.tready) tap_pixel(T_DPC, raw8(dut.u_pipe.p.tdata), dut.u_pipe.p.tlast, dut.u_pipe.p.tuser);
    if (dut.u_pipe.d.tvalid && dut.u_pipe.d.tready) tap_pixel(T_DEMOSAIC, rgb8(dut.u_pipe.d.tdata), dut.u_pipe.d.tlast, dut.u_pipe.d.tuser);
    if (dut.u_pipe.m.tvalid && dut.u_pipe.m.tready) tap_pixel(T_CCM, rgb8(dut.u_pipe.m.tdata), dut.u_pipe.m.tlast, dut.u_pipe.m.tuser);
    if (dut.u_pipe.gm.tvalid && dut.u_pipe.gm.tready) tap_pixel(T_GAMMA, dut.u_pipe.gm.tdata, dut.u_pipe.gm.tlast, dut.u_pipe.gm.tuser);
    if (dut.u_pipe.cq_v && dut.u_pipe.cq_r) tap_pixel(T_CSC, dut.u_pipe.cq_d, dut.u_pipe.cq_l, dut.u_pipe.cq_u);
`ifdef VP_VISION
    // vs_stream_adapter forwards a frame to vision_system (or drops it): the forwarded frame is the one
    // that last started at the insert point (isp_csc output)
    if (dut.va.tvalid && dut.va.tready && dut.va.tuser) lq_push(T_VISION, tap_lab[T_CSC]);
    if (dut.vr.tvalid && dut.vr.tready) tap_pixel(T_VISION, dut.vr.tdata, dut.vr.tlast, dut.vr.tuser);
    if (dut.vr.tvalid && dut.vr.tready && dut.vr.tuser) vs_out_lines = 0;
    if (dut.vr.tvalid && dut.vr.tready && dut.vr.tlast) begin
      vs_out_lines++;
      if (vs_out_lines == (gif_on ? gh : H)) vs_out_frames++;
    end
`endif
`ifdef VP_FILTER
    if (dut.fo.tvalid && dut.fo.tready) tap_pixel(T_FILTER, dut.fo.tdata, dut.fo.tlast, dut.fo.tuser);
`endif
  end
  // HDMI: the sink counts a frame at the next frame's vsync edge
  always @(sink.frames) display_done(T_HDMI);

  // Tracking test captures. Before the sequence the pipeline is empty, so the k-th frame at a point
  // after the sequence started is GIF frame k. At the tracker input: the frame, the overlay objects
  // and tracker window taken at its start, the tracker results at its end (done_o); at the overlay
  // output: the frame with the symbols.
`ifdef VP_TRACK
  always @(posedge pix_clk) if (gif_on) begin
    if (dut.fo.tvalid && dut.fo.tready) begin
      if (dut.fo.tuser) begin
        fo_k++;
        fo_x = 0;
        fo_y = 0;
      end
      if (dut.fo.tlast) begin
        fo_x = 0;
        fo_y++;
      end else fo_x++;
    end
    if (dut.ev_trk && fo_k >= 0 && fo_k < GMAXF) begin      // the detectors (or the NPU run) of the frame done
      trk_done[fo_k] = 1;
    end
    if (dut.ir.tvalid && dut.ir.tready) begin
      if (dut.ir.tuser) begin
        ir_k++;
        ir_x = 0;
        ir_y = 0;
      end
      if (ir_k >= 0 && ir_k < GMAXF && ir_y < gh && ir_x < gw) ovl_out.set_px(ir_k, ir_x, ir_y, dut.ir.tdata);
      if (dut.ir.tlast) begin
        ir_x = 0;
        ir_y++;
        if (ir_y == gh) ir_done = ir_k;
      end else ir_x++;
    end
  end
`endif
  // HDMI frame complete: the frame the overlay delivered last (genlock, see display_done)
  always @(sink.frames) if (gif_on && ir_done >= 0 && ir_done < GMAXF && !hdmi_saved[ir_done]) begin
    for (int y = 0; y < gh; y++) for (int x = 0; x < gw; x++) gout.set_px(ir_done, x, y, sink.frame[y][x]);
    gout.delay_cs[ir_done] = gin.delay_cs[ir_done];
    hdmi_saved[ir_done] = 1;
    hdmi_frames++;
  end

  // ---------------- UART 0 receiver: the firmware report -> sim_transcript_<GIF name>.txt ----------------
  localparam real UART_BIT = 1.0e9 / UART_BAUD;      // ns
  int uart_fd, uart_lines = 0, uart_pass = 0, uart_fail = 0;
  bit uart_end = 0;
  string uart_line = "";
  // Frame event transcript: "  [<time> us] <event>" lines (firmware events.py), checked against the
  // markers frame_counter logged, in the order the testbench saw them (hw_ev queue, below)
  localparam int NEV = 5, EVMAX = 256;
  string ev_txt [NEV] = '{"IRQ 13: COUNT0 = ", "IRQ 14: COUNT1 = ", "vision_system takes frame ",
                          "vision_system outputs frame ", "tracker frame "};
  int rep_sec = 7;                                   // report section: 7 image sequence, 8 tracking
  int rep_lines = 0, rep_bad = 0, rep_t = 0;         // event lines; mismatches; last time reported
  int rep_n [2][NEV];                                // last count reported per section and channel
  int rep_time [NEV][EVMAX];                         // time reported for channel / count (this section)
  int hw_ev [$];                                     // logged markers {channel, count}, in marker order
  int hw_ts [$];                                     // and their timestamps
  initial for (int s = 0; s < 2; s++) for (int c = 0; c < NEV; c++) rep_n[s][c] = 0;
  always @(posedge pix_clk) if (dut.pix_rst_n) begin
    if (dut.u_frame_cnt.u_regs.ev_en_wr_o) begin   // log restarted (emptied by the CPU)
      hw_ev.delete();
      hw_ts.delete();
    end
    for (int c = 0; c < NEV; c++)
      if (dut.u_frame_cnt.u_core.eof_i[c] && dut.u_frame_cnt.u_core.ev_en[c]) begin
        hw_ev.push_back((c << 24) | (dut.u_frame_cnt.u_core.n_count[c] & 24'hFFFFFF));
        hw_ts.push_back(dut.u_frame_cnt.u_core.ts);
      end
  end

  // one transcript line: the next logged marker, in order, with its time; counts 1, 2, 3, ... per
  // channel; times never go back; a frame's events in pipeline order
  task automatic report_event(input string line);
    int p, t, c, n;
    string rest, e;                                    // e: ev_txt[k] copied (iverilog: ev_txt[k].len() is the array size)
    p = 0;
    while (p < line.len() && line[p] != "]") p++;
    rest = line.substr(3, p - 4);                      // "  [<t> us] "
    t = rest.atoi();
    rest = line.substr(p + 2, line.len() - 1);
    c = -1;
    for (int k = 0; k < NEV; k++) begin
      e = ev_txt[k];
      if (c < 0 && rest.len() > e.len() && rest.substr(0, e.len() - 1) == e) c = k;
    end
    if (c < 0) return;                                 // not an event line
    e = ev_txt[c];
    rest = rest.substr(e.len(), rest.len() - 1);
    n = rest.atoi();
    rep_lines++;
    if (hw_ev.size() == 0 || hw_ev[0] != ((c << 24) | n) || hw_ts[0] != t) begin
      rep_bad++;
      if (rep_bad < 6) $display("ERROR @%0t: transcript \"%s\": next logged marker is channel %0d count %0d at %0d us", $time,
                                line, hw_ev.size() ? hw_ev[0] >> 24 : -1, hw_ev.size() ? hw_ev[0] & 24'hFFFFFF : -1,
                                hw_ts.size() ? hw_ts[0] : -1);
    end
    if (hw_ev.size() > 0) begin
      void'(hw_ev.pop_front());
      void'(hw_ts.pop_front());
    end
    if (t < rep_t || n != rep_n[rep_sec - 7][c] + 1) begin
      rep_bad++;
      if (rep_bad < 6) $display("ERROR @%0t: transcript \"%s\": time or count out of sequence", $time, line);
    end
    rep_t = t;
    rep_n[rep_sec - 7][c] = n;
    if (n < EVMAX) rep_time[c][n] = t;
    // the frame's earlier events (first stage; into, out of vision_system; tracker) before the last stage
    if (c == 1 && n < EVMAX) for (int k = 0; k < NEV; k++)
      if (k != 1 && rep_n[rep_sec - 7][k] >= n && rep_time[k][n] > t) begin
        rep_bad++;
        if (rep_bad < 6) $display("ERROR @%0t: frame %0d: %s at %0d us after its last-stage end at %0d us", $time, n,
                                  ev_txt[k], rep_time[k][n], t);
      end
  endtask
  uart_bfm #(.BIT_NS(UART_BIT)) uart0 (                // receiver on UART 0 (its rxd is the loopback)
    .txd(),
    .rxd(uart_txd[0])
  );
  string transcript = "";                             // UART 0 report file (+TRANSCRIPT=<file>)
  int   gif_fd = 0;                                   // several GIFs: this GIF's own transcript (section 8)
  initial begin
    string gi;
    uart0.rx_en = 0;
    if (!$value$plusargs("TRANSCRIPT=%s", transcript)) begin   // default: sim_transcript_<GIF name>.txt
      gi = "pedestrian_walk.gif";
      void'($value$plusargs("GIF_IN=%s", gi));
      transcript = {"sim_transcript_", base_name(gi), ".txt"};
    end
    uart_fd = $fopen(transcript, "w");
    if (uart_fd == 0) $display("ERROR: cannot write the UART 0 transcript %s", transcript);
    else $display("%s transcript (written as the simulation runs): %s", direct_strap ? "direct" : "UART 0", transcript);
    wait (boot_done);                                  // the line is idle (high) from here
    uart0.rx_en = !direct_strap;
  end
  always @(uart0.line_done) report_line(uart0.last_line);
  // direct transcript port (+direct): GPIO1 [31:24] = 0xDB, [8] toggles with every character, [7:0] it
  bit tport_tog = 0;
  string tport_line = "";
  always @(posedge cpu_clk) if (direct_strap && gpio_o[63:56] == 8'hDB && gpio_o[40] != tport_tog) begin
    tport_tog = gpio_o[40];
    if (gpio_o[39:32] == 8'd10) begin
      report_line(tport_line);
      tport_line = "";
    end else if (gpio_o[39:32] != 8'd13) tport_line = $sformatf("%s%c", tport_line, gpio_o[39:32]);
  end
  task automatic report_line(input string line);
    uart_line = line;
    $fwrite(uart_fd, "%s\n", uart_line);
    $fflush(uart_fd);
    if (gif_fd != 0) begin
      $fwrite(gif_fd, "%s\n", uart_line);
      $fflush(gif_fd);
    end
    $display("UART0| %s", uart_line);
    uart_lines++;
    if (uart_line.len() >= 8 && uart_line.substr(0, 7) == "  [PASS]") uart_pass++;
    if (uart_line.len() >= 8 && uart_line.substr(0, 7) == "  [FAIL]") uart_fail++;
    if (uart_line == "END OF REPORT") uart_end = 1;
    if (uart_line.len() > 2 && uart_line.substr(0, 1) == "8.") begin   // section 8 (per GIF): counts from 0 again
      rep_sec = 8;
      rep_t = 0;
      for (int c = 0; c < NEV; c++) rep_n[1][c] = 0;
    end
    if (uart_line.len() > 12 && uart_line.substr(0, 2) == "  [") report_event(uart_line);
  endtask

  // ---------------- tests ----------------
  logic [23:0] px, pe;
  bit pok;
  int pd;
  `include "video_processor_tests.sv"

  initial begin
    $timeformat(-6, 1, " us", 10);
    void'($value$plusargs("IMG_IN_DIR=%s", img_in_dir));
    void'($value$plusargs("IMG_OUT_DIR=%s", img_out_dir));
    void'($value$plusargs("GIF_IN=%s", gif_in));
    void'($value$plusargs("GIF_DIR=%s", gif_dir));
    void'($value$plusargs("GIF_IN_DIR=%s", gif_in_dir));
    void'($value$plusargs("PYSIM_RGB=%s", pysim_rgb));
    void'($value$plusargs("GIF_OUT=%s", gif_out));
    gif_bw = $test$plusargs("GIF_BW");
    split_list(gif_in);                                // +GIF_IN=<a.gif>,<b.gif>,...: sent one after the other
    for (int i = 0; i < opt_items.size(); i++) gif_list.push_back(opt_items[i]);
    if (gif_list.size() == 0) gif_list.push_back(gif_in);
    gif_in = gif_list[0];
    sensor_cci.mem[8'h56] = 8'(gif_list.size());       // tracking sequences the camera will send
    load_images();                                     // input_images/: read, or generate when missing
    $readmemh(`FW_HEX, flash.mem);
    repeat (5) @(posedge cpu_clk);
    gif_setup();                                       // tracking GIF: frame size -> camera registers
    #3 arst_n = 1;
    sink.hdmi = 1;
    sink.vs_active = 1;
    test_boot();
    test_core_reset();
    test_firmware();
    test_vision_output();
    expected_image();
    test_hdmi();
    test_lvds();
    test_adapter();
    test_images();                                     // 4 colour + 4 monochrome images, every module output saved
    for (gif_idx = 0; gif_idx < gif_list.size(); gif_idx++) begin   // every GIF: search, track, boxes; GIF out
      if (gif_idx > 0) begin                           // the next GIF: its size, name and options loaded
        gif_go = 0;
        gif_in = gif_list[gif_idx];
        gif_out = "";
        gif_setup();
      end
      if (gif_list.size() > 1) begin                   // its own transcript of section 8 too
        if (gif_fd != 0) $fclose(gif_fd);
        gif_fd = $fopen({gif_tr_dir(), "sim_transcript_", base_name(gif_in), ".txt"}, "w");
      end
      test_tracking();
    end
    if (gif_fd != 0) $fclose(gif_fd);
    // video checked: stop the display serial clocks (SYSCTL CLK_EN forced, simulation speed only)
    // and the camera, then wait for the rest of the firmware report
    clocks(CLK_EN_IDLE);
    cam_run = 0;
    $display("[%t] video checks done; serial clocks and camera stopped, waiting for the report", $realtime);
    test_uart_report();
    $fclose(uart_fd);
`ifdef VP_DDR
    if (ddr_err_cnt != 0) begin                       // every DDR timing rule kept by the controller
      $display("ERROR: the DDR memory reported %0d timing violations (code %0d)", ddr_err_cnt, ddr_err_code);
      errors++;
    end
`endif
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end

  // ---------------- waveform dump ----------------
  // +vcd writes video_processor_tb.vcd (scripts/run_sim.sh --vcd / --wave, make wave). A whole run is
  // long: +vcd_start_us=<n> / +vcd_stop_us=<n> limit the dump to a window of simulated time.
  initial if ($test$plusargs("vcd")) begin
    int t_on, t_off;
    t_on = 0;
    t_off = 0;
    void'($value$plusargs("vcd_start_us=%d", t_on));
    void'($value$plusargs("vcd_stop_us=%d", t_off));
    $dumpfile("video_processor_tb.vcd");
    if (t_on > 0) begin
      $dumpvars(0, video_processor_tb);
      $dumpoff;
      #(t_on * 1us);
      $dumpon;
    end
    else $dumpvars(0, video_processor_tb);
    if (t_off > t_on) begin
      #((t_off - t_on) * 1us);
      $dumpoff;
      $dumpflush;
    end
  end
endmodule
