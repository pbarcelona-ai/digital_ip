// ***************
// Filename: video_processor_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of video_processor_tb, `included into the
//   testbench module (they use its signals and models). Tests, in the order
//   the testbench runs them:
//     test_boot           py_soc boots the firmware (sw/video_proc.py) from the SPI flash
//                         model (boot_done, no boot error).
//     test_core_reset     the core logic (video) stays in reset while the
//                         CPU boots and tests its peripherals, and leaves it
//                         only when the CPU writes SYSCTL CORE_RESET after a
//                         clean initialisation (stage 3, no errors).
//     test_firmware       the firmware reaches stage 100 (video running) with
//                         no errors (its CPU peripheral self-test included),
//                         counted >= 6 isp_stats interrupts and switched the
//                         "running" LED (GPIO0[1]) on.
//     test_vision_output  vision_system's output (csi2_rx -> ISP bypassed:
//                         raw / 4 on R, G, B -> insert point ->
//                         vs_stream_adapter -> identity correction) is the
//                         camera image within 1 LSB (vision_system's own
//                         tolerance) and the same in every frame.
//     expected_image      the display image the outputs must show:
//                         blur_sharpen MODE 3 (blur, then sharpen;
//                         conv2d_ref) of that output.
//     test_hdmi           the HDMI image (tmds_serializer lanes deserialised
//                         and decoded by hdmi_bfm) equals it exactly;
//                         no HDMI protocol error.
//     test_lvds           the LVDS link A image (VESA 24 bpp) equals it
//                         exactly.
//     test_adapter        vision_system processed frames and lost no
//                         corrected pixel (return FIFO).
//     test_images         4 colour and 4 monochrome images, one frame each,
//                         back to back at the camera's frame gap (the
//                         camera sets the image format pin GPIO0[30] during
//                         the gap before each image; the firmware
//                         reprograms the ISP). Each image's frame at every
//                         module output it reached is saved as
//                         output_images/<module>_<c|m>_<n>_output.ppm. Checks:
//                         monochrome - the ISP output (isp_csc) is the input
//                         image exactly; colour - the demosaic keeps every
//                         native Bayer sample and the output is in colour;
//                         both - vision_system within 1 LSB of isp_csc,
//                         blur_sharpen equals conv2d_ref of vision_system,
//                         HDMI and LVDS equal blur_sharpen. Every image must
//                         reach isp_csc; an image vs_stream_adapter drops
//                         (vision_system busy) is reported, not an error,
//                         but at least one must pass the whole pipeline.
//                         frame_counter: 8 more first-stage counts, one
//                         last-stage count per image that passed.
//     test_uart_report    the UART 0 report (saved to cpu_bootup.txt) reaches
//                         "END OF REPORT" with no [FAIL] line and at least
//                         MIN_PASS [PASS] lines, the last frame counts the
//                         CPU reported equal the frame_counter's, and the
//                         firmware stage is 200.
//   check() records a failure; the testbench prints TEST PASSED when none.
//   Image helpers: load_images (input_images/: read each input, generate and
//   write it when missing), ppm_read / ppm_write (P5 monochrome and P6
//   colour, any size: inputs are resampled to the 32 x 24 frame, 16-bit
//   samples scaled), gen_image (moving shapes, so consecutive frames show
//   motion), sensor_px (RAW10 sample the camera sends: grey, or the RGGB
//   Bayer mosaic of a colour image), tap_pixel / frame_done / display_done
//   (frame capture and labelling at each module output).
// Date: 2026-10-08

  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      if (errors < 20) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic test_boot();
    wait (boot_done || boot_err);
    check(boot_done && !boot_err, "firmware boot from flash failed");
    $display("[%t] py_soc booted the firmware from flash", $realtime);
  endtask

  // The core logic (video) is held in reset through the CPU boot and self-test, and released by the
  // CPU (SYSCTL CORE_RESET -> core_rst_n_o) only after its initialisation passed; the core clock
  // domains then leave reset.
  task automatic test_core_reset();
    bit early;
    check(core_rst_n === 1'b0 && dut.pix_rst_n === 1'b0, "core logic must be in reset while the CPU boots");
    early = 0;
    while (core_rst_n !== 1'b1 && g(G_stage) < 100 && !early) begin
      @(posedge cpu_clk);
      if (core_rst_n !== 1'b1 && dut.pix_rst_n !== 1'b0) early = 1;
    end
    check(!early, "core logic left reset before the CPU released it");
    check(core_rst_n === 1'b1, "the CPU did not release the core logic reset");
    check(g(G_stage) == 3 && g(G_errors) == 0,
          $sformatf("core logic released at firmware stage %0d with %0d errors (expected after a clean CPU init, stage 3)",
                    g(G_stage), g(G_errors)));
    repeat (20) @(posedge pix_clk);
    check(dut.pix_rst_n === 1'b1, "pixel-clock domain still in reset after the release");
    $display("[%t] CPU released the core logic reset after its boot and self-test (SYSCTL CORE_RESET)", $realtime);
  endtask

  task automatic test_firmware();
    while (g(G_stage) < 100) @(posedge cpu_clk);
    check(g(G_errors) == 0, $sformatf("firmware reported %0d errors (see cpu_bootup.txt)", g(G_errors)));
    check(g(G_frames) >= 6, $sformatf("firmware counted %0d statistics interrupts", g(G_frames)));
    repeat (10) @(posedge cpu_clk);
    check(gpio_o[1] && !gpio_t[1], "running LED (GPIO0[1]) not on");
    $display("[%t] firmware: video running, %0d frame interrupts, LED on", $realtime, g(G_frames));
  endtask

  task automatic test_vision_output();
    int bad, exact;
    bad = 0;
    exact = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
`ifdef VP_VISION
      exp_img[y][x] = vs_frame[y][x];
`else
      exp_img[y][x] = ex(x, y);
`endif
    end
`ifdef VP_VISION
    check(vs_frames >= 2 && vs_changes == 0,
          $sformatf("vision_system output: %0d frames, %0d differ from the previous one", vs_frames, vs_changes));
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      px = vs_frame[y][x];
      pe = ex(x, y);
      pok = !$isunknown(px);
      for (int c = 0; c < 3; c++) begin
        pd = int'(px[8*c +: 8]) - int'(pe[8*c +: 8]);
        if (pd > 1 || pd < -1) pok = 0;
      end
      if (px === pe) exact++;
      if (!pok) begin
        if (bad < 4) $display("  vision (%0d,%0d) %h expected %h", x, y, px, pe);
        bad++;
      end
    end
    check(bad == 0, $sformatf("vision_system: %0d pixels differ from the camera image", bad));
    $display("[%t] vision_system output: camera image after ISP, %0d pixels exact, rest within 1 LSB", $realtime, exact);
`endif
  endtask

  task automatic expected_image();
`ifdef VP_FILTER
    int changed;
    changed = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) mdl.img[y][x] = exp_img[y][x];
    mdl.set_kernel(conv2d_pkg::blur_kernel(5), conv2d_pkg::blur_shift(5));
    mdl.run(W, H);
    mdl.chain(W, H);
    mdl.set_kernel(conv2d_pkg::sharpen_kernel(5, 1), conv2d_pkg::blur_shift(5));
    mdl.run(W, H);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      if (mdl.out[y][x] != exp_img[y][x]) changed++;
      exp_img[y][x] = mdl.out[y][x];
    end
    check(changed > 0, "blur_sharpen model did not change the image");
    $display("[%t] expected output: blur_sharpen MODE 3 (blur, then sharpen) of that frame, %0d of %0d pixels changed",
             $realtime, changed, W * H);
`endif
  endtask

  task automatic test_hdmi();
`ifdef VP_HDMI
    int f0, bad;
    f0 = sink.frames;
    while (sink.frames < f0 + 2) @(posedge pix_clk);
    bad = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      px = sink.frame[y][x];
      pe = exp_img[y][x];
      if (px !== pe) begin
        if (bad < 4) $display("  HDMI (%0d,%0d) %h expected %h", x, y, px, pe);
        bad++;
      end
    end
    check(sink.lines == H && sink.line_len == W, $sformatf("HDMI frame %0dx%0d", sink.line_len, sink.lines));
    check(bad == 0, $sformatf("HDMI: %0d pixels differ from the expected image", bad));
    check(sink.errors == 0, $sformatf("HDMI sink: %0d protocol errors", sink.errors));
    $display("[%t] HDMI: %0dx%0d image matches exactly", $realtime, W, H);
`endif
  endtask

  task automatic test_lvds();
`ifdef VP_LVDS
    int f0, bad;
    f0 = lvds.frames;
    while (lvds.frames < f0 + 2) @(posedge pix_clk);
    bad = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      px = lvds.frame[y][x];
      pe = exp_img[y][x];
      if (px !== pe) begin
        if (bad < 4) $display("  LVDS (%0d,%0d) %h expected %h", x, y, px, pe);
        bad++;
      end
    end
    check(bad == 0, $sformatf("LVDS: %0d pixels differ from the expected image", bad));
    $display("[%t] LVDS: %0dx%0d image matches exactly", $realtime, W, H);
`endif
  endtask

  task automatic test_adapter();
`ifdef VP_VISION
    $display(
  "camera frames sent %0d, into vision_system %0d, dropped while it was busy %0d",
  cam_frames,
  dut.u_vs_adapt.frames_o,
  dut.u_vs_adapt.drops_o
);
    check(dut.u_vs_adapt.frames_o >= 2, "vision_system processed fewer than 2 frames");
    check(dut.u_vs_adapt.ret_drops_o == 0, $sformatf("%0d corrected pixels lost (return FIFO full)", dut.u_vs_adapt.ret_drops_o));
`endif
  endtask

  task automatic test_uart_report();
    while (g(G_stage) != 200) @(posedge cpu_clk);
    repeat (2000) @(posedge cpu_clk);                  // last characters still on the line
    check(uart_end, "UART 0 report: \"END OF REPORT\" not received");
    check(uart_fail == 0, $sformatf("UART 0 report: %0d [FAIL] lines", uart_fail));
    check(uart_pass >= MIN_PASS, $sformatf("UART 0 report: %0d [PASS] lines, at least %0d expected", uart_pass, MIN_PASS));
    check(g(G_errors) == 0, $sformatf("firmware reported %0d errors", g(G_errors)));
    // the counts the CPU read at the end-of-frame interrupts: the last ones reported are the final counts
    check(rep_lines > 0 && rep_first == dut.u_frame_cnt.count[0] && rep_last == dut.u_frame_cnt.count[1],
          $sformatf("UART 0 report: last frame counts reported first %0d, last %0d; frame_counter has %0d, %0d",
                    rep_first, rep_last, dut.u_frame_cnt.count[0], dut.u_frame_cnt.count[1]));
    $display("[%t] UART 0 report: %0d lines, %0d [PASS], %0d [FAIL], %0d frame count reports (final %0d / %0d), saved to cpu_bootup.txt",
             $realtime, uart_lines, uart_pass, uart_fail, rep_lines, rep_first, rep_last);
  endtask

  // ================================================================ image test

  function automatic string tap_name(input int t);
    case (t)
      T_UNPACK:   return "csi2_raw_unpack";
      T_BLC:      return "isp_blc_wb";
      T_DPC:      return "isp_dpc";
      T_DEMOSAIC: return "isp_demosaic";
      T_CCM:      return "isp_ccm";
      T_GAMMA:    return "isp_gamma";
      T_CSC:      return "isp_csc";
      T_VISION:   return "vision_system";
      T_FILTER:   return "blur_sharpen";
      T_HDMI:     return "hdmi_tx";
      default:    return "lvds_tx";
    endcase
  endfunction

  // Taps built in this configuration
  function automatic bit tap_used(input int t);
    case (t)
`ifndef VP_VISION
      T_VISION: return 0;
`endif
`ifndef VP_FILTER
      T_FILTER: return 0;
`endif
`ifndef VP_HDMI
      T_HDMI:   return 0;
`endif
`ifndef VP_LVDS
      T_LVDS:   return 0;
`endif
      default:  return 1;
    endcase
  endfunction

  function automatic string img_name(input int lab);
    return $sformatf("frame_%s_%0d", lab >= 4 ? "m" : "c", lab % 4);
  endfunction

  // 10-bit samples shown as 8 bits: a raw (Bayer) value as grey, {B, G, R} components each
  function automatic logic [23:0] raw8(input logic [9:0] d);
    return {d[9:2], d[9:2], d[9:2]};
  endfunction
  function automatic logic [23:0] rgb8(input logic [29:0] d);
    return {d[29:22], d[19:12], d[9:2]};
  endfunction

  // RAW10 sample of image lab at (x, y): monochrome - the grey value; colour - its RGGB Bayer mosaic
  // (R at even x / even y, B at odd x / odd y, G elsewhere). 8 -> 10 bits repeats the top bits.
  function automatic logic [9:0] sensor_px(input int lab, input int x, input int y);
    logic [23:0] p;
    logic [7:0] v;
    p = in_img[lab][y][x];
    if (lab >= 4)                  v = p[7:0];
    else if (x % 2 == 0 && y % 2 == 0) v = p[7:0];
    else if (x % 2 == 1 && y % 2 == 1) v = p[23:16];
    else                           v = p[15:8];
    return {v, v[7:6]};
  endfunction

  // ---------------- frame labels: one FIFO per tap, filled by the stage before it
  task automatic lq_push(input int t, input int lab);
    lq[t][lq_w[t] % 16] = lab;
    lq_w[t]++;
  endtask
  task automatic lq_pop(input int t, output int lab);
    if (lq_r[t] == lq_w[t]) lab = -1;
    else begin
      lab = lq[t][lq_r[t] % 16];
      lq_r[t]++;
    end
  endtask

  // One accepted beat at tap t. At a frame start the frame takes the next label of the tap's FIFO and
  // passes it on to the next stage (one frame out per frame in); vision_system's FIFO is filled by
  // vs_stream_adapter's frame admission instead (see the tap block in the testbench).
  task automatic tap_pixel(input int t, input logic [23:0] p, input bit last, input bit sof);
    if (sof) begin
      int lab;
      lq_pop(t, lab);
      tap_lab[t] = lab;
      tap_x[t] = 0;
      tap_y[t] = 0;
      if (t < T_CSC || t == T_VISION) lq_push(t + 1, lab);
    end
    if (tap_y[t] < H && tap_x[t] < W) tap_img[t][tap_y[t]][tap_x[t]] = p;
    if (last) begin
      tap_x[t] = 0;
      tap_y[t]++;
      if (tap_y[t] == H) frame_done(t, tap_lab[t]);
    end else tap_x[t]++;
  endtask

  // A complete frame at tap t: keep (and save) the first one of each image
  task automatic frame_done(input int t, input int lab);
    tap_done_lab[t] = lab;
    if (lab >= 0 && lab < NIMG && !tap_saved[t][lab]) begin
      for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
        out_img[t][lab][y][x] = tap_img[t][y][x];
        io_img[y][x] = tap_img[t][y][x];
      end
      ppm_write($sformatf("%s/%s_%s_%0d_output.ppm", img_out_dir, tap_name(t), lab >= 4 ? "m" : "c", lab % 4), 0);
      tap_saved[t][lab] = 1;
    end
  endtask

  // HDMI / LVDS frame complete (decoded by hdmi_bfm / the LVDS deserialiser in the testbench):
  // it shows the frame blur_sharpen (else vision_system) delivered last
  // (genlock: the next one cannot be complete yet, the output FIFO holds less than a frame)
  task automatic display_done(input int t);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
      tap_img[t][y][x] = (t == T_HDMI) ? sink.frame[y][x] : lvds.frame[y][x];
`ifdef VP_FILTER
    frame_done(
  t,
  tap_done_lab[T_FILTER]
);
`else
    frame_done(t, tap_done_lab[T_VISION]);
`endif
  endtask

  // ---------------- PPM files (netpbm): P5 monochrome, P6 colour
  // Writes io_img: P6 ({B, G, R} -> R G B bytes), or P5 (grey from the R component) when mono.
  task automatic ppm_write(input string path, input bit mono);
    int fd;
    fd = $fopen(path, "wb");
    if (fd == 0) begin
      check(0, {"cannot write ", path, " (does its directory exist?)"});
      return;
    end
    $fwrite(fd, "%s\n%0d %0d\n255\n", mono ? "P5" : "P6", W, H);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
      if (mono) $fwrite(fd, "%c", io_img[y][x][7:0]);
      else      $fwrite(fd, "%c%c%c", io_img[y][x][7:0], io_img[y][x][15:8], io_img[y][x][23:16]);
    $fclose(fd);
  endtask

  // Next header number (whitespace and # comments skipped); the one character after it is consumed.
  task automatic ppm_num(input int fd, output int v);
    int c;
    bit skip;
    v = 0;
    skip = 1;
    while (skip) begin
      c = $fgetc(fd);
      if (c == "#") while (c != "\n" && c != -1) c = $fgetc(fd);
      else if (c != " " && c != "\t" && c != "\n" && c != "\r") skip = 0;
    end
    while (c >= "0" && c <= "9") begin
      v = v * 10 + (c - "0");
      c = $fgetc(fd);
    end
  endtask

  // Reads a P5 or P6 file of any size into io_img (nearest-neighbour resampled to W x H; maxval other
  // than 255 and 16-bit samples scaled). mono: colour pixels become grey (BT.601 luma).
  logic [23:0] ppm_px [];
  task automatic ppm_read(input string path, input bit mono, output bit ok);
    int fd, c0, c1, w, h, maxv, nb, comp, v;
    logic [7:0] s [3];
    ok = 0;
    fd = $fopen(path, "rb");
    if (fd == 0) return;
    c0 = $fgetc(fd);
    c1 = $fgetc(fd);
    if (c0 != "P" || (c1 != "5" && c1 != "6")) begin
      check(0, {path, ": not a binary PPM (P6) or PGM (P5) file"});
      $fclose(fd);
      return;
    end
    ppm_num(fd, w);
    ppm_num(fd, h);
    ppm_num(fd, maxv);
    if (w < 1 || h < 1 || maxv < 1 || maxv > 65535) begin
      check(0, $sformatf("%s: bad header (%0d x %0d, maxval %0d)", path, w, h, maxv));
      $fclose(fd);
      return;
    end
    comp = (c1 == "6") ? 3 : 1;
    nb = (maxv > 255) ? 2 : 1;
    ppm_px = new[w * h];
    for (int i = 0; i < w * h; i++) begin
      for (int k = 0; k < comp; k++) begin
        v = $fgetc(fd);
        if (nb == 2) v = (v << 8) | $fgetc(fd);
        if (v < 0) v = 0;
        s[k] = 8'((v * 255 + maxv / 2) / maxv);
      end
      if (comp == 1) begin
        s[1] = s[0];
        s[2] = s[0];
      end
      if (mono) s[0] = 8'((77 * s[0] + 150 * s[1] + 29 * s[2] + 128) >> 8);
      ppm_px[i] = mono ? {s[0], s[0], s[0]} : {s[2], s[1], s[0]};
    end
    $fclose(fd);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) io_img[y][x] = ppm_px[(y * h / H) * w + x * w / W];
    if (w != W || h != H) $display("  %s: %0d x %0d resampled to %0d x %0d", path, w, h, W, H);
    ok = 1;
  endtask

  // Generated input n (0-3) of each type, moving objects so consecutive frames show motion:
  //   colour     - gradient background, a red ball moving right and down, a blue square moving left;
  //   monochrome - grey gradient background, a white disc moving right and down, a black square
  //                moving left.
  task automatic gen_image(input int lab);
    int n, dx, dy;
    n = lab % 4;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      logic [7:0] r, g, b;
      if (lab < 4) begin
        r = 8'(30 + 5 * x);
        g = 8'(40 + 5 * y);
        b = 8'(170 - 4 * x);
        dx = x - (4 + 7 * n);
        dy = y - (6 + 3 * n);
        if (dx * dx + dy * dy <= 20) begin
          r = 235;
          g = 40;
          b = 30;
        end
        if (x >= 25 - 6 * n && x < 31 - 6 * n && y >= 15 && y < 21) begin
          r = 30;
          g = 70;
          b = 240;
        end
      end else begin
        r = 8'(60 + 4 * y);
        dx = x - (5 + 7 * n);
        dy = y - (5 + 4 * n);
        if (dx * dx + dy * dy <= 16) r = 245;
        if (x >= 26 - 7 * n && x < 31 - 7 * n && y >= 16 && y < 21) r = 15;
        g = r;
        b = r;
      end
      io_img[y][x] = {b, g, r};
    end
  endtask

  // input_images/frame_<c|m>_<n>_input.ppm: read each one, or generate it and write it (colour P6,
  // monochrome P5) when it does not exist. Simulators with $system create both directories; with
  // Icarus scripts/run_sim.sh does.
  task automatic load_images();
    bit ok;
    string f;
    int gen;
    gen = 0;
`ifndef __ICARUS__
    void'($system({"mkdir -p ", img_in_dir, " ", img_out_dir}));
`endif
    for (int lab = 0; lab < NIMG; lab++) begin
      f = {img_in_dir, "/", img_name(lab), "_input.ppm"};
      ppm_read(f, lab >= 4, ok);
      if (!ok) begin
        gen_image(lab);
        ppm_write(f, lab >= 4);
        gen++;
      end
      for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) in_img[lab][y][x] = io_img[y][x];
    end
    $display("input images: %0d read from %s/, %0d generated and written there", NIMG - gen, img_in_dir, gen);
  endtask

  function automatic bit all_saved(input int lab);
    for (int t = 0; t < NT; t++) if (tap_used(t) && !tap_saved[t][lab]) return 0;
    return 1;
  endfunction

  // The camera stops streaming live frames and sends the image sequence back to back at its frame
  // gap (GPIO0[29] high while it lasts); the firmware reprograms the ISP for each image's format during
  // the gap before it. Waits until the pipeline has drained, then checks every image that reached each
  // module output. Images dropped by vs_stream_adapter (vision_system busy) are reported, not errors.
  task automatic test_images();
    realtime t0, tq;
    bit done;
    int c0, c1, passed, dropped;
    // stop the live frames and let the pipeline empty (both frame counters still for 300 us), so the
    // counts at the start of the sequence (here and in the CPU) cover exactly the 8 images
    img_mode = 1;
    t0 = $realtime;                                    // the firmware listens for the sequence (section 7)
    while (g(G_stage) < 161 && $realtime - t0 < 40ms) @(posedge cpu_clk);
    check(g(G_stage) >= 161, "image test: firmware is not waiting for the image sequence (stage 161)");
    c0 = dut.u_frame_cnt.count[0];
    c1 = dut.u_frame_cnt.count[1];
    t0 = $realtime;
    tq = $realtime;
    while ($realtime - tq < 300us && $realtime - t0 < 10ms) begin
      repeat (200) @(posedge pix_clk);
      if (dut.u_frame_cnt.count[0] != c0 || dut.u_frame_cnt.count[1] != c1) begin
        c0 = dut.u_frame_cnt.count[0];
        c1 = dut.u_frame_cnt.count[1];
        tq = $realtime;
      end
    end
    seq_active = 1;
    img_go = 1;
    $display("[%t] image test: %0d images back to back, frame gap %0d ns (GPIO0[29] = 1)", $realtime, NIMG, frame_gap_ns());
    t0 = $realtime;
    while (seq_active && $realtime - t0 < 20ms) @(posedge pix_clk);
    check(!seq_active, "image test: the camera did not send the whole sequence");
    // drain: every saved image complete, or no more frames anywhere (the display's last frame ends
    // after genlock's LOCK_MAX wait)
    t0 = $realtime;
    done = 0;
    while (!done && $realtime - t0 < 4ms) begin
      repeat (500) @(posedge pix_clk);
      done = 1;
      for (int lab = 0; lab < NIMG; lab++) if (!all_saved(lab)) done = 0;
    end
    passed = 0;
    dropped = 0;
    for (int lab = 0; lab < NIMG; lab++) begin
      for (int t = 0; t <= T_CSC; t++)
        check(tap_saved[t][lab], $sformatf("%s: no frame at the %s output", img_name(lab), tap_name(t)));
      if (tap_used(T_VISION) && !tap_saved[T_VISION][lab]) begin
        $display("  %s: dropped by vs_stream_adapter (vision_system busy), no output after isp_csc", img_name(lab));
        dropped++;
      end else begin
        for (int t = T_VISION; t < NT; t++)
          if (tap_used(t)) check(tap_saved[t][lab], $sformatf("%s: no frame at the %s output", img_name(lab), tap_name(t)));
        passed++;
      end
      check_image(lab);
    end
    check(passed > 0, "image test: no image passed the whole pipeline");
    check(dut.u_frame_cnt.count[0] - c0 == NIMG,
          $sformatf("frame_counter: %0d first-stage ends of frame for %0d images", dut.u_frame_cnt.count[0] - c0, NIMG));
    check(dut.u_frame_cnt.count[1] - c1 == passed,
          $sformatf("frame_counter: %0d last-stage ends of frame, %0d images passed", dut.u_frame_cnt.count[1] - c1, passed));
    $display("[%t] image test: %0d images in, %0d through the whole pipeline, %0d dropped before vision_system; outputs in %s/",
             $realtime, NIMG, passed, dropped, img_out_dir);
  endtask

  // Checks of image lab at the module outputs (see the description at the top)
  task automatic check_image(input int lab);
    int bad, colour, d;
    logic [23:0] p, e;
    if (lab >= 4) begin                                // monochrome: ISP bypassed, raw value on R, G, B
      bad = 0;
      for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
        if (out_img[T_CSC][lab][y][x] !== {3{in_img[lab][y][x][7:0]}}) bad++;
      check(bad == 0, $sformatf("%s: isp_csc output differs from the input image in %0d pixels", img_name(lab), bad));
    end else begin                                     // colour: demosaic keeps the native sample of each pixel
      bad = 0;
      colour = 0;
      for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
        int c;
        c = (x % 2 == 0 && y % 2 == 0) ? 0 : (x % 2 == 1 && y % 2 == 1) ? 2 : 1;
        p = out_img[T_DEMOSAIC][lab][y][x];
        if (p[8*c +: 8] !== in_img[lab][y][x][8*c +: 8]) bad++;
        if (p[7:0] > p[15:8] + 60 || p[23:16] > p[15:8] + 60) colour++;
      end
      check(bad == 0, $sformatf("%s: isp_demosaic changed %0d native Bayer samples", img_name(lab), bad));
      check(colour > 20, $sformatf("%s: isp_demosaic output has no colour (%0d coloured pixels)", img_name(lab), colour));
    end
    if (tap_used(T_VISION) && !tap_saved[T_VISION][lab]) return;   // dropped before vision_system
`ifdef VP_VISION
    bad = 0;                                           // vision_system: identity correction, within 1 LSB
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      p = out_img[T_VISION][lab][y][x];
      e = out_img[T_CSC][lab][y][x];
      for (int c = 0; c < 3; c++) begin
        d = int'(p[8*c +: 8]) - int'(e[8*c +: 8]);
        if (d > 1 || d < -1) bad++;
      end
    end
    check(bad == 0, $sformatf("%s: vision_system output differs from isp_csc by more than 1 in %0d samples", img_name(lab), bad));
`endif
`ifdef VP_FILTER
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) mdl.img[y][x] = out_img[T_VISION][lab][y][x];
    mdl.set_kernel(conv2d_pkg::blur_kernel(5), conv2d_pkg::blur_shift(5));
    mdl.run(W, H);
    mdl.chain(W, H);
    mdl.set_kernel(conv2d_pkg::sharpen_kernel(5, 1), conv2d_pkg::blur_shift(5));
    mdl.run(W, H);
    bad = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) if (out_img[T_FILTER][lab][y][x] !== mdl.out[y][x]) bad++;
    check(bad == 0, $sformatf("%s: blur_sharpen output differs from conv2d_ref in %0d pixels", img_name(lab), bad));
`endif
    for (int t = T_HDMI; t <= T_LVDS; t++) if (tap_used(t)) begin
      bad = 0;
      for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) if (out_img[t][lab][y][x] !== out_img[T_FILTER][lab][y][x]) bad++;
      check(bad == 0, $sformatf("%s: %s image differs from blur_sharpen output in %0d pixels", img_name(lab), tap_name(t), bad));
    end
  endtask
