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
//       (GPIO0[0]) and writes "stream on" (register 0x01 = 1);
//     - I2C EEPROM (i2c_bfm, 0x50 on I2C 1); UART, SPI and GPIO
//       looped back (txd -> rxd, MOSI -> MISO, gpio_o -> gpio_i) for the
//       firmware's peripheral self-test; GPIO0[31] = +quick strap (the
//       firmware then skips the register dumps); GPIO0[30] = image
//       format pin (1 monochrome, 0 colour; the firmware reprograms the ISP
//       on each change and shows the result on GPIO0[2]); GPIO0[29] = image
//       sequence running;
//     - UART 0 receiver: decodes the report at UART_BAUD, writes it to
//       cpu_bootup.txt and echoes each line as "UART0| ...";
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
//       The frames at the tracker input (after blur_sharpen), at the
//       overlay output and on HDMI are captured, with each frame's overlay
//       settings, tracker window and results; the HDMI frames are written
//       as an animated GIF with the input's frame times (gif_io writer;
//       gif-output/<input name>_tracked.gif) and read back. LVDS
//       is checked before this and its serial clock is stopped for it.
//       Plusargs: +GIF_IN=<file> (any animated GIF),
//       +GIF_BW (convert a colour GIF to black and white; otherwise it is
//       sent in colour as an RGGB mosaic), +GIF_DIR=<dir> (GIF outputs,
//       default gif-output), +GIF_IN_DIR=<dir> (the input sequence as sent,
//       default gif-input), +GIF_OUT=<file>, +GIF_FRAMES=<n>
//       (send only the first n frames, a shorter run).
//   The test tasks are in tests/video_processor_tests.sv (`included).
//   Prints TEST PASSED on success.
// Date: 2026-10-11
`timescale 1ns/1ps
module video_processor_tb;
  `include "video_proc_syms.svh"
  localparam int W = 32, H = 24;
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
  tri1 sda0, scl0, sda1, scl1;
  wire quick_strap = $test$plusargs("quick");
  bit  mono_sel = 1;                                 // image format pin (GPIO0[30]): 1 monochrome, 0 colour
  bit  seq_active = 0;                               // image sequence pending (GPIO0[29])

  video_processor #(
    .NLANES(2),
    .MAX_W(320),                                     // tracking test frames up to 320 x 240
    .VS_RET_FIFO(131072),                            // a whole 320 x 240 frame
    .CSI_FIFO(256),
    .OUT_FIFO(512),
    .UART0_BAUD(UART_BAUD),
    .UART1_BAUD(UART_BAUD),
    .I2C0_HZ(2_000_000),
    .I2C1_HZ(2_000_000),
    .SPI0_HZ(10_000_000),
    .SPI1_HZ(10_000_000), // fast rates: short simulation
    .FLASH_CLKDIV(3),
    .PLL_MISMATCH_PPM(20_000)
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
    .gpio_i({gpio_o[95:32], quick_strap, mono_sel, seq_active, gpio_o[28:0]}),
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
    .stats_done_o(sdone));
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
  string img_in_dir = "input_images", img_out_dir = "output_images";

  // ---------------- tracking test: GIF in, captures, GIF out ----------------
  // Frame size: the GIF's own (width rounded down to a multiple of 4 for RAW10 packing, height to
  // an even number for the Bayer pattern), scaled down keeping the aspect ratio when larger than
  // GMAXW x GMAXH (the DUT's MAX_W / VS_RET_FIFO and the HDMI sink are sized for it), at least 16 x 16.
  localparam int GMAXW = 320, GMAXH = 240, GMAXF = 64;
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
  ) trk_in (); // frames at the tracker input (blur_sharpen out)
  gif_io #(
    .MAXW(GMAXW),
    .MAXH(GMAXH),
    .MAXF(GMAXF)
  ) ovl_out ();// frames out of the overlay
  track_ref #(
    .MAXW(GMAXW),
    .MAXH(GMAXH),
    .NOBJ(4)
  ) trm ();     // object_tracker / symbol_overlay models
  string gif_in = "input_images/pedestrian_walk.gif", gif_dir = "gif-output", gif_in_dir = "gif-input", gif_out = "";
  int   gif_n = 0, gif_next = 0;                     // frames to send, next one
  bit   gif_go = 0, gif_on = 0;                      // sending; capturing
  bit   gif_bw = 0, gif_colour = 0;                  // +GIF_BW: convert a colour GIF to black and white
  logic [511:0] ovl_act [GMAXF];                     // overlay objects applied to each frame
  logic [383:0] ovl_txt [GMAXF];                     // and its 4 texts {COLOR, POS, CTRL}
  logic [511:0] ovl_chr [GMAXF];                     // their characters
  logic [19:0] ovl_fnum [GMAXF];                     // its frame number (BCD)
  bit   ovl_en [GMAXF];
  int   trk_win [GMAXF][4];                          // tracker window of each frame (x0, y0, x1, y1)
  logic [31:0] trk_ctrl [GMAXF], trk_thr [GMAXF];
  int   trk_n [GMAXF], trk_bx [GMAXF], trk_by [GMAXF];
  bit   trk_done [GMAXF], hdmi_saved [GMAXF];
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
          wait (dut.u_vs_adapt.m_axis_tready && dut.u_vs_adapt.ret_empty);
          @(posedge byte_clk);
        end
`endif
        lab = LAB_GIF + gif_next;
        gif_next++;
      end
      else if (!img_mode) lab = -1;                    // live: the synthetic raw[][] image
      else if (img_go && img_next < NIMG) begin
`ifdef VP_VISION
        // pace the sequence: the next image once vision_system has taken the previous one and can
        // take another (ready, return FIFO empty), so vs_stream_adapter drops none of them
        if (img_next > 0) begin
          wait (dut.u_vs_adapt.frames_o >= vs_f0 + img_next);
          wait (dut.u_vs_adapt.m_axis_tready && dut.u_vs_adapt.ret_empty);
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
          cam.gap = 110;
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
    .MAXW(320),
    .MAXH(240)
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
      $display("ERROR @%0t: core trap (see build/fw/video_proc.lst)", $time);
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
  always @(posedge pix_clk) if (dut.vr_v && dut.vr_r) begin
    if (dut.vr_u) begin
      vs_x = 0;
      vs_y = 0;
      vs_diff = 0;
    end
    if (vs_y < H && vs_x < W) begin
      if (vs_frames > 0 && vs_frame[vs_y][vs_x] !== dut.vr_d) vs_diff = 1;
      vs_frame[vs_y][vs_x] = dut.vr_d;
    end
    if (dut.vr_l) begin
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
    if (dut.u_pipe.u_v && dut.u_pipe.u_r) tap_pixel(T_UNPACK, raw8(dut.u_pipe.u_d), dut.u_pipe.u_l, dut.u_pipe.u_u);
    if (dut.u_pipe.g_v && dut.u_pipe.g_r) tap_pixel(T_BLC, raw8(dut.u_pipe.g_d), dut.u_pipe.g_l, dut.u_pipe.g_u);
    if (dut.u_pipe.p_v && dut.u_pipe.p_r) tap_pixel(T_DPC, raw8(dut.u_pipe.p_d), dut.u_pipe.p_l, dut.u_pipe.p_u);
    if (dut.u_pipe.d_v && dut.u_pipe.d_r) tap_pixel(T_DEMOSAIC, rgb8(dut.u_pipe.d_d), dut.u_pipe.d_l, dut.u_pipe.d_u);
    if (dut.u_pipe.m_v && dut.u_pipe.m_r) tap_pixel(T_CCM, rgb8(dut.u_pipe.m_d), dut.u_pipe.m_l, dut.u_pipe.m_u);
    if (dut.u_pipe.gm_v && dut.u_pipe.gm_r) tap_pixel(T_GAMMA, dut.u_pipe.gm_d, dut.u_pipe.gm_l, dut.u_pipe.gm_u);
    if (dut.u_pipe.cq_v && dut.u_pipe.cq_r) tap_pixel(T_CSC, dut.u_pipe.cq_d, dut.u_pipe.cq_l, dut.u_pipe.cq_u);
`ifdef VP_VISION
    // vs_stream_adapter forwards a frame to vision_system (or drops it): the forwarded frame is the one
    // that last started at the insert point (isp_csc output)
    if (dut.va_v && dut.va_r && dut.va_u) lq_push(T_VISION, tap_lab[T_CSC]);
    if (dut.vr_v && dut.vr_r) tap_pixel(T_VISION, dut.vr_d, dut.vr_l, dut.vr_u);
`endif
`ifdef VP_FILTER
    if (dut.fo_v && dut.fo_r) tap_pixel(T_FILTER, dut.fo_d, dut.fo_l, dut.fo_u);
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
    if (dut.fo_v && dut.fo_r) begin
      if (dut.fo_u) begin
        fo_k++;
        fo_x = 0;
        fo_y = 0;
        if (fo_k < GMAXF) begin
          ovl_act[fo_k] = dut.u_overlay.u_core.cur;
          ovl_en[fo_k] = dut.u_overlay.u_core.cur_en;
          ovl_txt[fo_k] = dut.u_overlay.u_core.tcur;
          ovl_chr[fo_k] = dut.u_overlay.u_core.ccur;
          ovl_fnum[fo_k] = dut.u_overlay.u_core.fcur;
          trk_win[fo_k][0] = dut.u_track.u_core.cwx0;
          trk_win[fo_k][1] = dut.u_track.u_core.cwy0;
          trk_win[fo_k][2] = dut.u_track.u_core.cwx1;
          trk_win[fo_k][3] = dut.u_track.u_core.cwy1;
          trk_ctrl[fo_k] = dut.u_track.u_core.ctrl;
          trk_thr[fo_k] = 32'(dut.u_track.u_core.thresh_r);
        end
      end
      if (fo_k >= 0 && fo_k < GMAXF && fo_y < gh && fo_x < gw) trk_in.set_px(fo_k, fo_x, fo_y, dut.fo_d);
      if (dut.fo_l) begin
        fo_x = 0;
        fo_y++;
      end else fo_x++;
    end
    if (dut.u_track.u_core.done_o && fo_k >= 0 && fo_k < GMAXF) begin
      trk_n[fo_k] = dut.u_track.u_core.res_n;
      trk_bx[fo_k] = {16'(dut.u_track.u_core.res_x1), 16'(dut.u_track.u_core.res_x0)};
      trk_by[fo_k] = {16'(dut.u_track.u_core.res_y1), 16'(dut.u_track.u_core.res_y0)};
      trk_done[fo_k] = 1;
    end
    if (dut.ir_v && dut.ir_r) begin
      if (dut.ir_u) begin
        ir_k++;
        ir_x = 0;
        ir_y = 0;
      end
      if (ir_k >= 0 && ir_k < GMAXF && ir_y < gh && ir_x < gw) ovl_out.set_px(ir_k, ir_x, ir_y, dut.ir_d);
      if (dut.ir_l) begin
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

  // ---------------- UART 0 receiver: the firmware report -> cpu_bootup.txt ----------------
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
    string rest;
    p = 0;
    while (p < line.len() && line[p] != "]") p++;
    rest = line.substr(3, p - 4);                      // "  [<t> us] "
    t = rest.atoi();
    rest = line.substr(p + 2, line.len() - 1);
    c = -1;
    for (int k = 0; k < NEV; k++)
      if (c < 0 && rest.len() > ev_txt[k].len() && rest.substr(0, ev_txt[k].len() - 1) == ev_txt[k]) c = k;
    if (c < 0) return;                                 // not an event line
    rest = rest.substr(ev_txt[c].len(), rest.len() - 1);
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
  initial begin
    uart0.rx_en = 0;
    uart_fd = $fopen("cpu_bootup.txt", "w");
    wait (boot_done);                                  // the line is idle (high) from here
    uart0.rx_en = 1;
  end
  always @(uart0.line_done) begin
    uart_line = uart0.last_line;
    $fwrite(uart_fd, "%s\n", uart_line);
    $fflush(uart_fd);
    $display("UART0| %s", uart_line);
    uart_lines++;
    if (uart_line.len() >= 8 && uart_line.substr(0, 7) == "  [PASS]") uart_pass++;
    if (uart_line.len() >= 8 && uart_line.substr(0, 7) == "  [FAIL]") uart_fail++;
    if (uart_line == "END OF REPORT") uart_end = 1;
    if (uart_line.len() > 2 && uart_line.substr(0, 1) == "8.") begin   // section 8: counts from 0 again
      rep_sec = 8;
      rep_t = 0;
    end
    if (uart_line.len() > 12 && uart_line.substr(0, 2) == "  [") report_event(uart_line);
  end

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
    void'($value$plusargs("GIF_OUT=%s", gif_out));
    gif_bw = $test$plusargs("GIF_BW");
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
    test_tracking();                                   // pedestrian GIF: search, track, dashed box; GIF out
    // video checked: stop the display serial clocks (SYSCTL CLK_EN forced, simulation speed only)
    // and the camera, then wait for the rest of the firmware report
    clocks(CLK_EN_IDLE);
    cam_run = 0;
    $display("[%t] video checks done; serial clocks and camera stopped, waiting for the report", $realtime);
    test_uart_report();
    $fclose(uart_fd);
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
