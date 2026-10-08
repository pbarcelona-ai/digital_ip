// ***************
// Filename: video_processor_tb.sv
// Author: FPGA Cores 4 U
// Description: System testbench of video_processor. Nothing is programmed
//   by the testbench: py_soc boots sw/video_init.py from a SPI flash model
//   and the firmware brings the system up over its external AXI4-Lite
//   window. Board models:
//     - spi_flash_model holding the firmware image (pyc.py);
//     - camera module: sensor CCI register model (i2c_slave_model, address
//       0x36 on I2C 0) and a CSI-2 RAW10 source (csi2_lane_driver) that
//       streams 32x24 frames only after the firmware releases its reset
//       (GPIO0[0]) and writes "stream on" (register 0x01 = 1);
//     - HDMI: tmds_serializer lanes deserialised on the TMDS clock lane and
//       decoded by hdmi_sink_model;
//     - LVDS link A: lvds_serializer lanes deserialised on the clock lane,
//       decoded as single-link VESA 24 bpp.
//   Checks: the firmware reaches its last stage with no errors, counted the
//   isp_stats interrupts and switched the "running" LED (GPIO0[1]) on;
//   vision_system's output (csi2_rx -> ISP bypassed: raw / 4 on R, G, B ->
//   insert point -> vs_stream_adapter -> identity correction) is the camera
//   image within 1 LSB (vision_system's own tolerance) and the same in every
//   frame; the HDMI and LVDS images equal blur_sharpen MODE 3 (blur, then
//   sharpen, conv2d_ref) of that output exactly; no core trap, no HDMI
//   protocol error.
//   Prints TEST PASSED on success.
// Date: 2026-10-08
`timescale 1ns/1ps
module video_processor_tb;
  `include "video_init_syms.svh"
  localparam int W = 32, H = 24;
  logic cpu_clk = 0, pix_clk = 0, tmds_ser_clk = 0, lvds_ser_clk = 0, byte_clk = 0, arst_n = 0;
  always #5   cpu_clk = ~cpu_clk;                    // 100 MHz
  always #7   pix_clk = ~pix_clk;                    // 71.4 MHz
  always #0.7 tmds_ser_clk = ~tmds_ser_clk;          // exactly 10x
  always #1   lvds_ser_clk = ~lvds_ser_clk;          // exactly 7x
  always #4   byte_clk = ~byte_clk;                  // 125 MHz D-PHY byte clock (RX and TX)
  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 20) $display("ERROR @%0t: %s", $time, m); end
  endtask
  initial begin #12ms; $display("ERROR: simulation timeout (firmware stage %0d)", g(G_stage)); $display("TEST FAILED"); $finish; end

  // ---------------- DUT ----------------
  logic fl_sclk, fl_cs_n, fl_mosi, fl_miso; int fl_wip;
  logic [1:0] uart_txd, scl_o, scl_t, sda_o, sda_t, spi_sclk, spi_mosi; logic [3:0] spi_cs_n;
  logic [95:0] gpio_o, gpio_t; logic boot_done, boot_err, trap, wdt_reset, sdone;
  logic [15:0] cam_d; logic [1:0] cam_v;
  logic [3:0] tmds_ser; logic [4:0] lvds_a_ser, lvds_b_ser;
  logic [15:0] dsi_d, ctx_d; logic [1:0] dsi_v, ctx_v; logic dsi_req, ctx_req;
  wire  [63:0] sdram_dq; wire sd_clk, sd_cke, sd_cs_n, sd_ras_n, sd_cas_n, sd_we_n; wire [12:0] sd_a; wire [1:0] sd_ba; wire [7:0] sd_dqm;
  tri1 sda0, scl0, sda1, scl1;

  video_processor #(.NLANES(2), .MAX_W(64), .CSI_FIFO(256), .OUT_FIFO(512),
                    .CPU_HZ(100_000_000), .UART_BAUD(2_000_000), .I2C_HZ(2_000_000), .SPI_HZ(10_000_000),
                    .FLASH_CLKDIV(3)) dut (
    .arst_n, .cpu_clk, .pix_clk,
    .flash_sclk_o(fl_sclk), .flash_cs_n_o(fl_cs_n), .flash_mosi_o(fl_mosi), .flash_miso_i(fl_miso),
    .uart_txd_o(uart_txd), .uart_rxd_i(uart_txd),
    .i2c_scl_i({scl1, scl0}), .i2c_scl_o(scl_o), .i2c_scl_t(scl_t),
    .i2c_sda_i({sda1, sda0}), .i2c_sda_o(sda_o), .i2c_sda_t(sda_t),
    .spi_sclk_o(spi_sclk), .spi_mosi_o(spi_mosi), .spi_miso_i(spi_mosi), .spi_cs_n_o(spi_cs_n),
    .gpio_i(gpio_o), .gpio_o, .gpio_t, .ext_irq_i(3'b000),
    .boot_done_o(boot_done), .boot_err_o(boot_err), .cpu_trap_o(trap), .wdt_reset_o(wdt_reset),
`ifdef VP_CSI2_RX
    .byte_clk, .cam_lane_data_i(cam_d), .cam_lane_valid_i(cam_v),
`endif
`ifdef VP_HDMI
    .tmds_ser_clk, .tmds_serial_o(tmds_ser),
`endif
`ifdef VP_LVDS
    .lvds_ser_clk, .lvds_a_serial_o(lvds_a_ser), .lvds_b_serial_o(lvds_b_ser),
`endif
`ifdef VP_MIPI_TX
    .tx_byte_clk(byte_clk),
`endif
`ifdef VP_DSI
    .dsi_lane_data_o(dsi_d), .dsi_lane_valid_o(dsi_v), .dsi_hs_req_o(dsi_req), .dsi_tx_ready_i(1'b0),
`endif
`ifdef VP_CSI2_TX
    .csitx_lane_data_o(ctx_d), .csitx_lane_valid_o(ctx_v), .csitx_hs_req_o(ctx_req), .csitx_tx_ready_i(1'b0),
`endif
`ifdef VP_VISION
    .sdram_clk(sd_clk), .sdram_cke(sd_cke), .sdram_cs_n(sd_cs_n), .sdram_ras_n(sd_ras_n), .sdram_cas_n(sd_cas_n),
    .sdram_we_n(sd_we_n), .sdram_a(sd_a), .sdram_ba(sd_ba), .sdram_dqm(sd_dqm), .sdram_dq(sdram_dq),
`endif
    .stats_done_o(sdone));
`ifndef VP_HDMI
  assign tmds_ser = '0;
`endif
`ifndef VP_LVDS
  assign lvds_a_ser = '0; assign lvds_b_ser = '0;
`endif

  // ---------------- board: flash, I2C, camera ----------------
  spi_flash_model flash (.sclk(fl_sclk), .cs_n(fl_cs_n), .mosi(fl_mosi), .miso(fl_miso), .wip_cycles(fl_wip));
  assign sda0 = sda_t[0] ? 1'bz : sda_o[0];  assign scl0 = scl_t[0] ? 1'bz : scl_o[0];
  assign sda1 = sda_t[1] ? 1'bz : sda_o[1];  assign scl1 = scl_t[1] ? 1'bz : scl_o[1];
  i2c_slave_model #(.ADDR(7'h36)) sensor_cci (.sda(sda0), .scl(scl0));
  csi2_lane_driver #(.NL(2)) cam (.clk(byte_clk), .lane_data(cam_d), .lane_valid(cam_v));

  int raw [H][W];
  initial for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) raw[y][x] = 64 + ((37 * x + 91 * y + 13 * x * y) % 900);
  // Expected output: ISP bypassed (raw value on R, G and B, 10 -> 8 bit), vision_system identity.
  // vision_system's Q16.16 coordinate arithmetic may round a sample by 1 LSB (its own regression
  // accepts max error 1): its output is checked within 1 of this.
  function automatic logic [23:0] ex(input int x, input int y);
    logic [7:0] v; v = 8'(raw[y][x] >> 2); return {v, v, v};
  endfunction

  int cam_frames = 0;
  wire cam_on = gpio_o[0] && !gpio_t[0] && sensor_cci.mem[8'h01] == 8'h01;
  initial begin
    wait (cam_on);
    $display("[%t] camera released from reset and streaming (I2C 0x36 reg 0x01 = 1)", $realtime);
    forever begin
      cam.gap = 4; cam.csi_pay.delete(); cam.csi_packet(2'd0, 6'h00, 16'(cam_frames + 1)); cam.send_pkt();
      for (int y = 0; y < H; y++) begin
        cam.csi_px.delete(); for (int x = 0; x < W; x++) cam.csi_px.push_back(10'(raw[y][x]));
        cam.csi_pack_raw10();
        cam.csi_packet(2'd0, 6'h2B, 16'(cam.csi_pay.size()));
        cam.gap = 110; cam.send_pkt();
      end
      cam.csi_pay.delete(); cam.csi_packet(2'd0, 6'h01, 16'(cam_frames + 1)); cam.gap = 1600; cam.send_pkt();
      cam_frames++;
    end
  end

  // ---------------- HDMI: deserialise (LSB first) and decode ----------------
  logic [9:0] tsr [4]; logic [9:0] tw0 = 0, tw1 = 0, tw2 = 0; logic trclk = 0; int tcnt = 0, tlocks = 0;
  always @(posedge tmds_ser_clk) begin
    for (int c = 0; c < 4; c++) tsr[c] = {tmds_ser[c], tsr[c][9:1]};
    if (tsr[3] == 10'b0000011111) begin tw0 <= tsr[0]; tw1 <= tsr[1]; tw2 <= tsr[2]; tcnt = 0; tlocks++; end
    else tcnt++;
    trclk <= (tcnt >= 4 && tcnt < 9);
  end
`ifdef VP_HDMI
  wire sink_en = tlocks > 20;
`else
  wire sink_en = 1'b0;
`endif
  hdmi_sink_model #(.MAXW(64), .MAXH(32)) sink (.clk(trclk), .en(sink_en), .ch0(tw0), .ch1(tw1), .ch2(tw2));

  // ---------------- LVDS link A: deserialise (bit 6 first) and decode VESA 24 bpp ----------------
  logic [6:0] lsr [5]; logic [27:0] lw = 0; int lcnt = 0, llocks = 0; logic lrclk = 0;
  always @(posedge lvds_ser_clk) begin
    for (int c = 0; c < 5; c++) lsr[c] = {lsr[c][5:0], lvds_a_ser[c]};
    if (lsr[4] == 7'b1100011) begin lw <= {lsr[3], lsr[2], lsr[1], lsr[0]}; lcnt = 0; llocks++; end
    else lcnt++;
    lrclk <= (lcnt >= 2 && lcnt < 5);
  end
  logic [23:0] lv_frame [H][W]; int lv_x = 0, lv_y = 0, lv_frames = 0; bit lv_vs_q = 0;
  always @(posedge lrclk) if (llocks > 20) begin
    logic [6:0] l0, l1, l2, l3; logic [7:0] r, g, b;
    l0 = lw[6:0]; l1 = lw[13:7]; l2 = lw[20:14]; l3 = lw[27:21];
    r = {l3[1], l3[0], l0[5:0]}; g = {l3[3], l3[2], l1[4:0], l0[6]}; b = {l3[5], l3[4], l2[3:0], l1[6:5]};
    if (l2[5] && !lv_vs_q) begin if (lv_y == H) lv_frames++; lv_y = 0; lv_x = 0; end
    lv_vs_q = l2[5];
    if (l2[6]) begin if (lv_y < H && lv_x < W) lv_frame[lv_y][lv_x] = {b, g, r}; lv_x++; end
    else if (lv_x != 0) begin lv_x = 0; lv_y++; end
  end

  // ---------------- firmware globals and traps ----------------
  function automatic longint g(input int idx);
    logic [33:0] v; v = dut.u_cpu.u_core.globals[idx];
    return v[0] ? longint'($signed(v) >>> 1) : -999;
  endfunction
  longint last_stage = -1;
  always @(posedge cpu_clk) if (arst_n) begin
    if (g(G_stage) != last_stage) begin last_stage = g(G_stage); $display("[%t] firmware stage %0d", $realtime, last_stage); end
    if (trap) begin $display("ERROR @%0t: core trap (see build/fw/video_init.lst)", $time); $display("TEST FAILED"); $finish; end
  end

  // ---------------- vision_system output capture (all frames must be identical: static scene) ----------------
  logic [23:0] vs_frame [H][W]; logic [23:0] exp_img [H][W];
  int vs_x = 0, vs_y = 0, vs_frames = 0, vs_changes = 0; bit vs_diff = 0;
`ifdef VP_VISION
  always @(posedge pix_clk) if (dut.vr_v && dut.vr_r) begin
    if (dut.vr_u) begin vs_x = 0; vs_y = 0; vs_diff = 0; end
    if (vs_y < H && vs_x < W) begin
      if (vs_frames > 0 && vs_frame[vs_y][vs_x] !== dut.vr_d) vs_diff = 1;
      vs_frame[vs_y][vs_x] = dut.vr_d;
    end
    if (dut.vr_l) begin
      vs_x = 0; vs_y++;
      if (vs_y == H) begin if (vs_diff && vs_frames > 0) vs_changes++; vs_frames++; end
    end else vs_x++;
  end
`endif
  conv2d_ref #(.N(5), .C(3), .CW(8), .MAXW(W), .MAXH(H)) mdl ();

  // ---------------- test ----------------
  logic [23:0] px, pe; bit pok; int pd;
  initial begin
    $timeformat(-6, 1, " us", 10);
    $readmemh(`FW_HEX, flash.mem);
    repeat (5) @(posedge cpu_clk);
    #3 arst_n = 1;

    wait (boot_done || boot_err);
    check(boot_done && !boot_err, "firmware boot from flash failed");
    $display("[%t] py_soc booted the firmware from flash", $realtime);
    sink.hdmi = 1; sink.vs_active = 1;
    while (g(G_stage) != 100) @(posedge cpu_clk);
    check(g(G_errors) == 0, $sformatf("firmware reported %0d errors", g(G_errors)));
    check(g(G_frames) >= 6, $sformatf("firmware counted %0d statistics interrupts", g(G_frames)));
    repeat (10) @(posedge cpu_clk);
    check(gpio_o[1] && !gpio_t[1], "running LED (GPIO0[1]) not on");
    $display("[%t] firmware done: %0d frame interrupts, LED on", $realtime, g(G_frames));

    // ---- expected display image: vision_system output, then blur_sharpen MODE 3 ----
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
`ifdef VP_VISION
      exp_img[y][x] = vs_frame[y][x];
`else
      exp_img[y][x] = ex(x, y);
`endif
    end
`ifdef VP_VISION
    begin
      int bad, exact; bad = 0; exact = 0;
      check(vs_frames >= 2 && vs_changes == 0,
            $sformatf("vision_system output: %0d frames, %0d differ from the previous one", vs_frames, vs_changes));
      for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
        px = vs_frame[y][x]; pe = ex(x, y); pok = !$isunknown(px);
        for (int c = 0; c < 3; c++) begin
          pd = int'(px[8*c +: 8]) - int'(pe[8*c +: 8]);
          if (pd > 1 || pd < -1) pok = 0;
        end
        if (px === pe) exact++;
        if (!pok) begin if (bad < 4) $display("  vision (%0d,%0d) %h expected %h", x, y, px, pe); bad++; end
      end
      check(bad == 0, $sformatf("vision_system: %0d pixels differ from the camera image", bad));
      $display("[%t] vision_system output: camera image after ISP, %0d pixels exact, rest within 1 LSB", $realtime, exact);
    end
`endif
`ifdef VP_FILTER
    begin
      int changed; changed = 0;
      for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) mdl.img[y][x] = exp_img[y][x];
      mdl.set_kernel(conv2d_pkg::blur_kernel(5), conv2d_pkg::blur_shift(5)); mdl.run(W, H); mdl.chain(W, H);
      mdl.set_kernel(conv2d_pkg::sharpen_kernel(5, 1), conv2d_pkg::blur_shift(5)); mdl.run(W, H);
      for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
        if (mdl.out[y][x] != exp_img[y][x]) changed++;
        exp_img[y][x] = mdl.out[y][x];
      end
      check(changed > 0, "blur_sharpen model did not change the image");
      $display("[%t] expected output: blur_sharpen MODE 3 (blur, then sharpen) of that frame, %0d of %0d pixels changed",
               $realtime, changed, W * H);
    end
`endif

`ifdef VP_HDMI
    begin
      int f0, bad; f0 = sink.frames;
      while (sink.frames < f0 + 2) @(posedge pix_clk);
      bad = 0;
      for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
        px = sink.frame[y][x]; pe = exp_img[y][x];
        if (px !== pe) begin if (bad < 4) $display("  HDMI (%0d,%0d) %h expected %h", x, y, px, pe); bad++; end
      end
      check(sink.lines == H && sink.line_len == W, $sformatf("HDMI frame %0dx%0d", sink.line_len, sink.lines));
      check(bad == 0, $sformatf("HDMI: %0d pixels differ from the expected image", bad));
      check(sink.errors == 0, $sformatf("HDMI sink: %0d protocol errors", sink.errors));
      $display("[%t] HDMI: %0dx%0d image matches exactly", $realtime, W, H);
    end
`endif
`ifdef VP_LVDS
    begin
      int f0, bad; f0 = lv_frames;
      while (lv_frames < f0 + 2) @(posedge pix_clk);
      bad = 0;
      for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
        px = lv_frame[y][x]; pe = exp_img[y][x];
        if (px !== pe) begin if (bad < 4) $display("  LVDS (%0d,%0d) %h expected %h", x, y, px, pe); bad++; end
      end
      check(bad == 0, $sformatf("LVDS: %0d pixels differ from the expected image", bad));
      $display("[%t] LVDS: %0dx%0d image matches exactly", $realtime, W, H);
    end
`endif
`ifdef VP_VISION
    $display("camera frames sent %0d, into vision_system %0d, dropped while it was busy %0d", cam_frames,
             dut.u_vs_adapt.frames_o, dut.u_vs_adapt.drops_o);
    check(dut.u_vs_adapt.frames_o >= 2, "vision_system processed fewer than 2 frames");
    check(dut.u_vs_adapt.ret_drops_o == 0, $sformatf("%0d corrected pixels lost (return FIFO full)", dut.u_vs_adapt.ret_drops_o));
`endif
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
