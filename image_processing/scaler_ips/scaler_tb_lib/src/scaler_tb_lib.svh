// ***************
// Filename: scaler_tb_lib.svh
// Author: Paul Barcelona
// Description: Shared self-checking testbench library.
//   Include inside a testbench module after defining the localparams
//   CHANNELS, COMP_W, PIX_W, MAX_W, MAX_H and ADDR_W; the testbench must
//   provide golden_pixel(ox, oy) and the task ip_configure().
//   Provides: AXI4-Stream source/sink with random stalls, test patterns,
//   clamp-to-edge fetch and 16.16 coordinate helpers, PPM (P6) read and
//   write, run_test, run_standard_suite and run_file_suite.
//   Plusargs (tb_init):
//     +IMG=<file.ppm>       input image instead of generated patterns
//     +OUT_W=<n> +OUT_H=<n> output size for +IMG runs
//     +OUTDIR=<dir>         directory for PPM files (must exist)
//     +NO_PPM               do not write PPM files
//   Files: <OUTDIR>/<tb>_tNN_in_WxH.ppm (generated inputs) and
//   <OUTDIR>/<tb>_tNN_out_WxH.ppm (DUT output). R/G/B = components
//   0/1/2; needs CHANNELS = 3; COMP_W > 8 uses 16-bit samples.
// Date: 2026-09-26

`define SCALER_TB_LIB
`include "scaler_tb_axil.svh"

logic [PIX_W-1:0]  s_tdata = '0;
logic              s_tvalid = 1'b0, s_tuser = 1'b0, s_tlast = 1'b0;
wire               s_tready;
wire [PIX_W-1:0]   m_tdata;
wire               m_tvalid, m_tuser, m_tlast;
logic              m_tready = 1'b0;

// ------------------------------------------------------------------ state
int                 in_w, in_h, out_w, out_h;    // current test sizes
logic [31:0]        reg_step_x, reg_step_y;      // programmed STEP_X/Y
logic signed [31:0] reg_offs_x, reg_offs_y;      // programmed OFFS_X/Y
logic [PIX_W-1:0]   img [MAX_H][MAX_W];          // current input image
int                 valid_pct  = 80;   // input tvalid probability  (%)
int                 ready_pct  = 70;   // output tready probability (%)
int                 frames_ok  = 0;    // tests that passed
// Set to 1 by testbenches of same-size filters (e.g. sharpen_cas): only the
// SIZE register (0x008) is programmed, output size = input size.
bit                 lib_filter = 1'b0;
// Extra CTRL bits OR-ed into the enable write (e.g. BYPASS of sharpen_cas)
logic [31:0]        ctrl_bits  = '0;

// ------------------------------------------------------------------ protocol checkers
// Input stream: handshake rules only (the suite injects junk before SOF on
// purpose). Output stream: handshake rules plus full video framing against
// the programmed output size.
int chk_in_w = 0, chk_in_h = 0;
axis_checker #(.DATA_W(PIX_W), .NAME("s_axis"), .CHECK_FRAMING(1'b0)) u_axis_in_chk (
  .clk, .rst_n, .tvalid(s_tvalid), .tready(s_tready), .tdata(s_tdata), .tuser(s_tuser),
  .tlast(s_tlast), .frame_w(chk_in_w), .frame_h(chk_in_h));
axis_checker #(.DATA_W(PIX_W), .NAME("m_axis"), .CHECK_FRAMING(1'b1)) u_axis_out_chk (
  .clk, .rst_n, .tvalid(m_tvalid), .tready(m_tready), .tdata(m_tdata), .tuser(m_tuser),
  .tlast(m_tlast), .frame_w(out_w), .frame_h(out_h));

// ------------------------------------------------------------------ buffering monitor
// Measures what the frame-store mode promises:
//   overlap  : input beats accepted while an output frame is in progress
//              (0 for a single frame buffer, > 0 for ping-pong / line buffer)
//   latency  : input rows received when the first output pixel of a frame
//              appears (= in_h for frame buffers, a few lines for line buffers)
int  mon_overlap = 0;
bit  mon_out_active = 1'b0;
int  mon_in_beats = 0, mon_out_beats = 0;
int  mon_lat_rows = -1;                  // latency of the last checked frame
int  mon_lat_min = 1 << 30, mon_lat_max = -1;
bit  mon_lat_en = 1'b0;                  // set by run_test for single-frame tests
bit  mon_strict_overlap = 1'b1;          // 0 for chained DUTs whose output lags the
                                         // frame generator (e.g. scaler + sharpener)
always @(posedge clk) begin
  if (s_tvalid && s_tready) begin
    if (s_tuser) mon_in_beats = 0;
    mon_in_beats++;
    if (mon_out_active) mon_overlap++;
  end
  if (m_tvalid && m_tready) begin
    if (m_tuser) begin
      mon_out_active = 1'b1;
      mon_out_beats  = 0;
      if (mon_lat_en) begin
        mon_lat_rows = (mon_in_beats + in_w - 1) / ((in_w > 0) ? in_w : 1);
        if (mon_lat_rows < mon_lat_min) mon_lat_min = mon_lat_rows;
        if (mon_lat_rows > mon_lat_max) mon_lat_max = mon_lat_rows;
      end
    end
    mon_out_beats++;
    if (mon_out_beats == out_w * out_h) mon_out_active = 1'b0;
  end
end

// Mode-specific checks after each single-frame test (run_test)
task automatic check_buffering(input int ih);
`ifdef TB_LINE_BUF
  if (`TB_LINE_BUF && ih >= 30 && mon_lat_rows >= ih / 2) begin
    errors++;
    $display("ERROR: line buffer: first output after %0d of %0d input rows", mon_lat_rows, ih);
  end
  if (!`TB_LINE_BUF && mon_lat_rows != ih && mon_lat_rows >= 0) begin
    errors++;
    $display("ERROR: frame buffer: output started after %0d of %0d rows", mon_lat_rows, ih);
  end
`endif
endtask

task automatic buffering_report();
  string mode;
  mode = "n/a";
`ifdef TB_LINE_BUF
  if (`TB_LINE_BUF)     mode = "line-buffer";
  else if (`TB_PINGPONG) mode = "ping-pong";
  else                  mode = "frame";
`endif
  $display("COVERAGE buffering  mode=%s  in/out overlap beats=%0d  first-output latency (input rows) min=%0d max=%0d",
           mode, mon_overlap, (mon_lat_max < 0) ? 0 : mon_lat_min, mon_lat_max);
`ifdef TB_LINE_BUF
  if (!`TB_LINE_BUF && !`TB_PINGPONG && mon_strict_overlap && mon_overlap != 0) begin
    errors++; $display("ERROR: single frame buffer accepted input while generating");
  end
  if ((`TB_LINE_BUF || `TB_PINGPONG) && fcov_multi > 0 && mon_overlap == 0) begin
    errors++; $display("ERROR: no capture/generation overlap in %s mode", mode);
  end
`endif
endtask

// ------------------------------------------------------------------ feature coverage
// Scaling-scenario bins filled by run_test(); reported by finish_report().
int fcov_x_up = 0, fcov_x_down = 0, fcov_x_same = 0;
int fcov_y_up = 0, fcov_y_down = 0, fcov_y_same = 0;
int fcov_mixed = 0, fcov_int2x = 0, fcov_nonint = 0, fcov_big_down = 0;
int fcov_in_1px = 0, fcov_out_1px = 0, fcov_in_max = 0;
int fcov_junk = 0, fcov_fullrate = 0, fcov_backpressure = 0, fcov_file = 0, fcov_multi = 0;
int fcov_pattern [4];
initial for (int i = 0; i < 4; i++) fcov_pattern[i] = 0;

task automatic sample_feature_cov(input int iw, input int ih, input int ow, input int oh,
                                  input int pattern, input int junk, input int nframes);
  if (ow > iw) fcov_x_up++; else if (ow < iw) fcov_x_down++; else fcov_x_same++;
  if (oh > ih) fcov_y_up++; else if (oh < ih) fcov_y_down++; else fcov_y_same++;
  if ((ow > iw && oh < ih) || (ow < iw && oh > ih)) fcov_mixed++;
  if (ow == 2 * iw && oh == 2 * ih) fcov_int2x++;
  if ((ow % iw) != 0 && (iw % ow) != 0) fcov_nonint++;
  if (iw >= 4 * ow || ih >= 4 * oh) fcov_big_down++;
  if (iw == 1 && ih == 1) fcov_in_1px++;
  if (ow == 1 && oh == 1) fcov_out_1px++;
  if (iw == MAX_W && ih == MAX_H) fcov_in_max++;
  if (junk > 0) fcov_junk++;
  if (nframes > 1) fcov_multi++;
  if (valid_pct == 100 && ready_pct == 100) fcov_fullrate++; else fcov_backpressure++;
  if (pattern < 0) fcov_file++; else if (pattern < 4) fcov_pattern[pattern]++;
endtask

function automatic int feature_bins_hit();
  int h;
  h = (fcov_x_up > 0) + (fcov_x_down > 0) + (fcov_x_same > 0) + (fcov_y_up > 0)
    + (fcov_y_down > 0) + (fcov_y_same > 0) + (fcov_mixed > 0) + (fcov_int2x > 0)
    + (fcov_nonint > 0) + (fcov_big_down > 0) + (fcov_in_1px > 0) + (fcov_out_1px > 0)
    + (fcov_in_max > 0) + (fcov_junk > 0) + (fcov_fullrate > 0) + (fcov_backpressure > 0)
    + (fcov_multi > 0);
  for (int i = 0; i < 4; i++) h += (fcov_pattern[i] > 0);
  return h;
endfunction

// called from finish_report(): print stream/feature coverage, add checker errors
task automatic lib_report(inout int chk);
  buffering_report();
  u_axis_in_chk.report();
  u_axis_out_chk.report();
  $display("COVERAGE features   x_up=%0d x_down=%0d x_same=%0d y_up=%0d y_down=%0d y_same=%0d mixed=%0d int2x=%0d non_integer=%0d down>=4x=%0d",
           fcov_x_up, fcov_x_down, fcov_x_same, fcov_y_up, fcov_y_down, fcov_y_same,
           fcov_mixed, fcov_int2x, fcov_nonint, fcov_big_down);
  $display("COVERAGE features   in_1px=%0d out_1px=%0d in_max=%0d junk_sof=%0d multi_frame=%0d full_rate=%0d backpressure=%0d file=%0d patterns=%0d|%0d|%0d|%0d  bins %0d/21",
           fcov_in_1px, fcov_out_1px, fcov_in_max, fcov_junk, fcov_multi, fcov_fullrate, fcov_backpressure,
           fcov_file, fcov_pattern[0], fcov_pattern[1], fcov_pattern[2], fcov_pattern[3],
           feature_bins_hit());
  chk += u_axis_in_chk.errors + u_axis_in_chk.sva_errors
       + u_axis_out_chk.errors + u_axis_out_chk.sva_errors;
endtask

// ------------------------------------------------------------------ helpers
// Extract component c of a pixel as an integer
function automatic int comp(input logic [PIX_W-1:0] p, input int c);
  return int'(p[c*COMP_W +: COMP_W]);
endfunction

// Clamp v into [lo, hi]
function automatic int clampi(input int v, input int lo, input int hi);
  return (v < lo) ? lo : (v > hi) ? hi : v;
endfunction

// clamp-to-edge fetch from the current input image
function automatic logic [PIX_W-1:0] fetch(input int x, input int y);
  return img[clampi(y, 0, in_h - 1)][clampi(x, 0, in_w - 1)];
endfunction

// source coordinate of output pixel (signed 16.16), identical to scaler_dda
function automatic longint src_x(input int ox);
  return longint'(reg_offs_x) + longint'(ox) * longint'(reg_step_x);
endfunction
function automatic longint src_y(input int oy);
  return longint'(reg_offs_y) + longint'(oy) * longint'(reg_step_y);
endfunction

// Coordinate mapping registers for centre-aligned scaling:
//   src = (o + 0.5) * in/out - 0.5
function automatic logic [31:0] calc_step(input int in_sz, input int out_sz);
  return 32'((((longint'(in_sz)) << 16) + out_sz / 2) / out_sz);
endfunction
function automatic logic signed [31:0] calc_offs(input logic [31:0] step);
  return $signed(32'(step >> 1)) - 32'sh8000;
endfunction

// Largest component value, 2^COMP_W - 1
function automatic int max_comp();
  return (1 << COMP_W) - 1;
endfunction

// ------------------------------------------------------------------ patterns
// 0: random noise, 1: diagonal edges + gradient, 2: stripes/checker, 3: flat
task automatic fill_image(input int pattern);
  // fill the in_w x in_h area of img[][] with the selected pattern
  for (int y = 0; y < in_h; y++)
    for (int x = 0; x < in_w; x++)
      for (int c = 0; c < CHANNELS; c++) begin
        int v;
        case (pattern)
          0: v = int'($urandom_range(max_comp(), 0));
          1: v = ((x + 2 * y + c) % 11 < 5) ? max_comp() - (x * 3 % 17) : (y * 5 + c * 9) % 23;
          2: v = (((x >> 1) ^ (y >> 1) ^ c) & 1) ? max_comp() : 0;
          default: v = (37 * (c + 1)) & max_comp();
        endcase
        img[y][x][c*COMP_W +: COMP_W] = COMP_W'(v);
      end
endtask

// ------------------------------------------------------------------ PPM (P6) I/O
string tb_name   = "tb";      // prefix of written file names
string outdir    = ".";       // +OUTDIR
string img_file  = "";        // +IMG
bit    use_file  = 1'b0;      // 1 when +IMG was given
bit    ppm_en    = 1'b1;      // 0 with +NO_PPM
int    file_w    = 0, file_h = 0;          // size of the +IMG image
int    file_out_w = 0, file_out_h = 0;     // +OUT_W / +OUT_H
string out_ppm_name = "";     // output file of the current test

// maxval written to PPM headers
function automatic int ppm_maxval();
  return (1 << COMP_W) - 1;
endfunction

// read one unsigned decimal header field, skipping whitespace and comments;
// consumes exactly one whitespace character after the number
function automatic int ppm_read_int(input int fd);
  int c, v;
  c = $fgetc(fd);
  while (c == 8'h20 || c == 8'h0A || c == 8'h0D || c == 8'h09 || c == 8'h23) begin
    if (c == 8'h23) while (c != 8'h0A && c != -1) c = $fgetc(fd);
    c = $fgetc(fd);
  end
  v = -1;
  while (c >= 8'h30 && c <= 8'h39) begin
    v = ((v < 0) ? 0 : v * 10) + (c - 8'h30);
    c = $fgetc(fd);
  end
  return v;
endfunction

// Load a P6 image into img[][]; sets file_w / file_h. Samples are rescaled
// from the file's maxval to the COMP_W range.
task automatic read_ppm(input string fname);
  int fd, c0, c1, mv, v, hi, lo;
  fd = $fopen(fname, "rb");
  if (fd == 0) begin
    $display("TB_RESULT: FAIL (cannot open +IMG=%s)", fname); $finish;
  end
  c0 = $fgetc(fd); c1 = $fgetc(fd);
  if (c0 != 8'h50 || c1 != 8'h36) begin
    $display("TB_RESULT: FAIL (%s is not a binary PPM / P6 file)", fname); $finish;
  end
  file_w = ppm_read_int(fd);
  file_h = ppm_read_int(fd);
  mv     = ppm_read_int(fd);
  if (file_w < 1 || file_h < 1 || mv < 1 || mv > 65535) begin
    $display("TB_RESULT: FAIL (bad PPM header in %s)", fname); $finish;
  end
  if (file_w > MAX_W || file_h > MAX_H) begin
    $display("TB_RESULT: FAIL (%s is %0dx%0d but the testbench MAX is %0dx%0d; recompile with TB_MAX_W / TB_MAX_H defines, e.g. iverilog -DTB_MAX_W=%0d -DTB_MAX_H=%0d)",
             fname, file_w, file_h, MAX_W, MAX_H, file_w, file_h);
    $finish;
  end
  for (int y = 0; y < file_h; y++)
    for (int x = 0; x < file_w; x++)
      for (int c = 0; c < 3; c++) begin
        if (mv < 256) v = $fgetc(fd);
        else begin hi = $fgetc(fd); lo = $fgetc(fd); v = (hi << 8) | lo; end
        if (v < 0) begin
          $display("TB_RESULT: FAIL (unexpected end of file in %s)", fname); $finish;
        end
        if (mv != ppm_maxval())
          v = int'((longint'(v) * ppm_maxval() + mv / 2) / mv);
        img[y][x][c*COMP_W +: COMP_W] = COMP_W'(v);
      end
  $fclose(fd);
  $display("Loaded %s : %0dx%0d, maxval %0d", fname, file_w, file_h, mv);
endtask

// Create a PPM file and write its header; returns 0 on failure
function automatic int ppm_open(input string fname, input int w, input int h);
  int fd;
  fd = $fopen(fname, "wb");
  if (fd == 0) $display("WARNING: cannot write %s (does +OUTDIR exist?)", fname);
  else $fwrite(fd, "P6\n%0d %0d\n%0d\n", w, h, ppm_maxval());
  return fd;
endfunction

// Append one pixel as R, G, B samples (8- or 16-bit big-endian)
task automatic ppm_put_pixel(input int fd, input logic [PIX_W-1:0] p);
  for (int c = 0; c < 3; c++) begin
    if (COMP_W <= 8)
      $fwrite(fd, "%c", 8'(p[c*COMP_W +: COMP_W]));
    else begin
      $fwrite(fd, "%c", 8'(p[c*COMP_W +: COMP_W] >> 8));
      $fwrite(fd, "%c", 8'(p[c*COMP_W +: COMP_W]));
    end
  end
endtask

// Write the current input image (in_w x in_h) to a PPM file
task automatic write_input_ppm(input string fname);
  int fd;
  fd = ppm_open(fname, in_w, in_h);
  if (fd != 0) begin
    for (int y = 0; y < in_h; y++)
      for (int x = 0; x < in_w; x++)
        ppm_put_pixel(fd, img[y][x]);
    $fclose(fd);
  end
endtask

// Parse command-line options. Call first in the testbench's initial block.
task automatic tb_init(input string name);
  tb_name = name;
  if ($value$plusargs("OUTDIR=%s", outdir)) ;
  if ($test$plusargs("NO_PPM")) ppm_en = 1'b0;
  if (CHANNELS != 3 && ppm_en) begin
    $display("NOTE: PPM output disabled (CHANNELS=%0d, PPM needs 3)", CHANNELS);
    ppm_en = 1'b0;
  end
  if ($value$plusargs("OUT_W=%d", file_out_w)) ;
  if ($value$plusargs("OUT_H=%d", file_out_h)) ;
  if ($value$plusargs("IMG=%s", img_file)) begin
    if (CHANNELS != 3) begin
      $display("TB_RESULT: FAIL (+IMG requires CHANNELS == 3)"); $finish;
    end
    use_file = 1'b1;
    read_ppm(img_file);
  end
endtask

// Test sequence for +IMG runs: +OUT_W/+OUT_H if given, otherwise a 1.5x
// upscale, a 0.4x downscale and an anamorphic 1 : 1/4 squeeze.
task automatic run_file_suite();
  if (lib_filter) begin
    run_test(file_w, file_h, file_w, file_h, -1);
  end else if (file_out_w > 0 || file_out_h > 0) begin
    run_test(file_w, file_h, (file_out_w > 0) ? file_out_w : file_w,
             (file_out_h > 0) ? file_out_h : file_h, -1);
  end else begin
    run_test(file_w, file_h, (file_w * 3 + 1) / 2, (file_h * 3 + 1) / 2, -1);
    run_test(file_w, file_h, (file_w * 2 + 4) / 5, (file_h * 2 + 4) / 5, -1);
    run_test(file_w, file_h, file_w, (file_h + 3) / 4, -1);
  end
endtask

// ------------------------------------------------------------------ streams
// Drive one AXI4-Stream beat: random idle cycles (valid_pct), then hold
// the beat until the DUT accepts it (tready sampled at the clock edge).
task automatic send_beat(input logic [PIX_W-1:0] d, input bit user, input bit last);
  // called right after the previous handshake edge: presenting the next beat
  // at the following negedge gives true back-to-back (full-rate) transfers
  @(negedge clk);
  while ($urandom_range(99, 0) >= valid_pct) begin
    s_tvalid = 1'b0;
    @(negedge clk);
  end
  s_tvalid = 1'b1; s_tdata = d; s_tuser = user; s_tlast = last;
  do @(posedge clk); while (!s_tready);
endtask

// junk > 0 sends that many beats without SOF first (must be dropped)
task automatic send_frame(input int junk = 0);
  for (int k = 0; k < junk; k++)
    send_beat(PIX_W'($urandom), 1'b0, 1'b0);
  for (int y = 0; y < in_h; y++)
    for (int x = 0; x < in_w; x++)
      send_beat(img[y][x], (x == 0 && y == 0), (x == in_w - 1));
  @(negedge clk);
  s_tvalid = 1'b0; s_tuser = 1'b0; s_tlast = 1'b0;
endtask

// Receive one output frame with random tready (ready_pct). Every beat
// is compared with golden_pixel(), tuser must mark pixel 0 and tlast the
// end of each line; the beats are also written to the output PPM. After
// the frame no further beat may appear.
task automatic recv_frame();
  int ox = 0, oy = 0, n = 0, bad = 0;
  bit extra;
  int total = out_w * out_h;
  int fd = 0;
  if (ppm_en && out_ppm_name != "") fd = ppm_open(out_ppm_name, out_w, out_h);
  while (n < total) begin
    @(negedge clk);
    m_tready = ($urandom_range(99, 0) < ready_pct);
    @(posedge clk);
    if (m_tvalid && m_tready) begin
      logic [PIX_W-1:0] exp;
      exp = golden_pixel(ox, oy);
      checks++;
      if (m_tdata !== exp || m_tuser !== (n == 0) || m_tlast !== (ox == out_w - 1)) begin
        errors++; bad++;
        if (bad <= 8)
          $display("ERROR: out(%0d,%0d) got 0x%0h user=%0b last=%0b exp 0x%0h user=%0b last=%0b",
                   ox, oy, m_tdata, m_tuser, m_tlast, exp, (n == 0), (ox == out_w - 1));
      end
      if (fd != 0) ppm_put_pixel(fd, m_tdata);
      n++;
      if (ox == out_w - 1) begin ox = 0; oy++; end else ox++;
    end
  end
  if (fd != 0) $fclose(fd);
  @(negedge clk) m_tready = 1'b0;
  // no extra beats may follow
  extra = 0;
  repeat (20) begin
    @(posedge clk);
    if (m_tvalid) extra = 1;
  end
  if (extra) begin
    errors++;
    $display("ERROR: unexpected extra output beat");
  end
endtask

// ------------------------------------------------------------------ receiver process
// Runs recv_frame() whenever run_test raises rx_go; rx_done reports the
// end of the frame back to run_test.
bit rx_go = 1'b0, rx_done = 1'b0;
int rx_frames = 1;                        // frames to receive per run_test
int frames_total = 0;                     // frames streamed by all run_test calls
initial begin
  forever begin
    wait (rx_go && !rx_done);
    for (int f = 0; f < rx_frames; f++) recv_frame();
    rx_done = 1'b1;
    wait (!rx_go);
  end
end

// ------------------------------------------------------------------ test
// One complete test: choose sizes, derive the coordinate registers,
// prepare the input image, program the DUT, stream one frame in while
// checking the frame out, then verify STATUS / FRAME_CNT and disable.
// pattern >= 0 selects a generated image, -1 uses the +IMG image.
task automatic run_test(input int iw, input int ih, input int ow, input int oh,
                        input int pattern, input int junk = 0, input int nframes = 1);
  logic [31:0] st, fc0, fc1;
  string src_desc;
  int e0 = errors;
  tests++;
  sample_feature_cov(iw, ih, ow, oh, pattern, junk, nframes);
  in_w = iw; in_h = ih; out_w = ow; out_h = oh;
  reg_step_x = calc_step(iw, ow);
  reg_step_y = calc_step(ih, oh);
  reg_offs_x = calc_offs(reg_step_x);
  reg_offs_y = calc_offs(reg_step_y);
  if (pattern >= 0) fill_image(pattern);   // pattern -1: image from +IMG
  out_ppm_name = $sformatf("%s/%s_t%02d_out_%0dx%0d.ppm", outdir, tb_name, tests, ow, oh);
  if (ppm_en && pattern >= 0)
    write_input_ppm($sformatf("%s/%s_t%02d_in_%0dx%0d.ppm", outdir, tb_name, tests, iw, ih));

  // program the common registers and read back two of them
  axil_read (12'h020, fc0);
  axil_write(12'h008, {16'(ih), 16'(iw)});
  axil_check(12'h008, {16'(ih), 16'(iw)});
  if (!lib_filter) begin
    axil_write(12'h00C, {16'(oh), 16'(ow)});
    axil_write(12'h010, reg_step_x);
    axil_write(12'h014, reg_step_y);
    axil_write(12'h018, reg_offs_x);
    axil_write(12'h01C, reg_offs_y);
    axil_check(12'h018, reg_offs_x);
  end else if (ow != iw || oh != ih) begin
    errors++; $display("ERROR: filter testbench asked for %0dx%0d -> %0dx%0d", iw, ih, ow, oh);
  end
  ip_configure();
  axil_write(12'h004, 32'hE);           // clear sticky status
  axil_write(12'h000, 32'h1 | ctrl_bits); // enable

  // The receiver runs in its own process (see "receiver process") not a
  // fork/join here: this sidesteps a Verilator 5.020 coroutine code-generation
  // bug seen with fork/join inside large automatic tasks.
  mon_lat_en   = (nframes == 1) && (junk == 0);
  mon_lat_rows = -1;
  rx_done   = 1'b0;
  rx_frames = nframes;
  frames_total += nframes;
  rx_go     = 1'b1;                      // start the checker
  send_frame(junk);                      // stream the input frame(s); frames
  for (int f = 1; f < nframes; f++)      // after the first stall while the
    send_frame(0);                       // DUT is still producing output
  wait (rx_done);
  rx_go   = 1'b0;
  if (mon_lat_en) check_buffering(ih);
  mon_lat_en = 1'b0;

  // STATUS must show FRAME_DONE, SOF_ERR only if junk was sent, no
  // EOL_ERR; FRAME_CNT must have advanced by one
  axil_read(12'h004, st);
  checks++;
  if (!st[1]) begin errors++; $display("ERROR: FRAME_DONE not set (status 0x%0h)", st); end
  if (st[2] !== (junk > 0)) begin
    errors++; $display("ERROR: SOF_ERR=%0b expected %0b", st[2], (junk > 0));
  end
  if (st[3]) begin errors++; $display("ERROR: EOL_ERR set"); end
  axil_read(12'h020, fc1);
  checks++;
  if (fc1 != fc0 + nframes) begin errors++; $display("ERROR: FRAME_CNT %0d -> %0d", fc0, fc1); end

  axil_write(12'h000, 32'h0);           // disable -> back to idle
  axil_write(12'h004, 32'hE);
  axil_check(12'h004, 32'h0, 32'h3F);

  // one summary line per test
  if (pattern < 0) src_desc = img_file;
  else             src_desc = $sformatf("pattern %0d", pattern);
  $display("TEST %0d: %0dx%0d -> %0dx%0d %s junk %0d : %s", tests, iw, ih, ow, oh,
           src_desc, junk, (errors == e0) ? "pass" : "FAIL");
  if (errors == e0) frames_ok++;
endtask

// Size sweep for same-size filters (lib_filter = 1)
task automatic run_filter_suite();
  run_test(16, 12, 16, 12, 0);
  run_test(33, 17, 33, 17, 1);
  run_test(1, 1, 1, 1, 0);                     // single pixel
  run_test(1, 9, 1, 9, 2);                     // single column
  run_test(13, 1, 13, 1, 1);                   // single row
  run_test(2, 2, 2, 2, 0);
  run_test(MAX_W, MAX_H, MAX_W, MAX_H, 1, 3);  // max size + junk before SOF
  run_test(20, 16, 20, 16, 3);                 // flat
  valid_pct = 100; ready_pct = 100;            // full rate
  run_test(24, 18, 24, 18, 1);
  valid_pct = 100; ready_pct = 40;             // heavy output back-pressure
  run_test(31, 23, 31, 23, 0);
  valid_pct = 80;  ready_pct = 70;
  run_test(19, 7, 19, 7, 2, 0, 3);             // 3 back-to-back frames
  valid_pct = 100; ready_pct = 100;
  run_test(9, 5, 9, 5, 0, 0, 4);               // back-to-back at full rate
  valid_pct = 80;  ready_pct = 70;
endtask

// Standard sweep of size combinations used by every IP testbench
task automatic run_standard_suite();
  run_test(16, 12, 16, 12, 0);            // identity
  run_test(16, 12, 37, 29, 0);            // non-integer upscale
  run_test(MAX_W, MAX_H, 13, 9, 0);       // strong downscale
  run_test(33, 17, 20, 40, 1);            // down-x / up-y
  run_test(10, 10, 20, 20, 2);            // exact 2x
  run_test(1, 1, 5, 3, 3);                // degenerate source
  run_test(7, 5, 1, 1, 0);                // single output pixel
  run_test(MAX_W, MAX_H, MAX_W, MAX_H, 1, 3);  // max size + junk before SOF
  valid_pct = 100; ready_pct = 100;       // full-rate streaming
  run_test(24, 18, 41, 31, 1);
  valid_pct = 80;  ready_pct = 70;
  run_test(20, 14, 9, 23, 0, 0, 3);       // 3 back-to-back frames: input
endtask                                   // back-pressure while generating
