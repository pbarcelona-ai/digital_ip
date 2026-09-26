// ***************
// Filename: tb_scaler_ctrl.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for scaler_ctrl.
//   Checks common register reset values, read/write and RO ID registers;
//   frame capture (every pixel written once to the right x,y, gen_start
//   pulses once after the last write, input stalled while generating);
//   SOF/EOL error detection, re-sync on SOF, W1C sticky status bits;
//   FRAME_CNT/FRAME_DONE on gen_done, ENABLE loop and return to idle;
//   forwarding of addresses >= 0x40 to the IP register bus.
//   Plusargs: +VCD=<file> waveform file, +NO_VCD disables dumping.
// Date: 2026-09-26

`timescale 1ns/1ps
module tb_scaler_ctrl;
  localparam int ADDR_W = 14;
  localparam int PIX_W  = 16;
  localparam int MAX_W  = 32, MAX_H = 24;

  // clock, reset, AXI-Lite master and result reporting
  `include "scaler_tb_axil.svh"

  // stream source and the DUT-side interfaces (IP role played by the tb)
  logic [PIX_W-1:0] s_tdata = '0;
  logic s_tvalid = 0, s_tuser = 0, s_tlast = 0;
  wire  s_tready;
  logic fb_we, gen_start; logic [15:0] fb_wx, fb_wy; logic [PIX_W-1:0] fb_wdata;
  logic gen_done = 0;
  logic [15:0] in_w, in_h, out_w, out_h;
  logic [31:0] step_x, step_y; logic signed [31:0] offs_x, offs_y;
  logic ext_wr, ext_rd; logic [ADDR_W-1:0] ext_waddr, ext_raddr;
  logic [31:0] ext_wdata, ext_rdata;

  // Device under test (distinct IP_ID/CAPS values to check the RO regs)
  scaler_ctrl #(.PIX_W(PIX_W), .ADDR_W(ADDR_W), .MAX_W(MAX_W), .MAX_H(MAX_H),
                .IP_ID(32'hCAFE_0001), .CAPS(32'h1234_5678)) dut (
    .clk, .rst_n,
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
    .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
    .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
    .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
    .s_axis_tuser(s_tuser), .s_axis_tlast(s_tlast),
    .fb_we, .fb_wx, .fb_wy, .fb_wdata, .gen_start, .gen_done,
    .cfg_in_w(in_w), .cfg_in_h(in_h), .cfg_out_w(out_w), .cfg_out_h(out_h),
    .cfg_step_x(step_x), .cfg_step_y(step_y), .cfg_offs_x(offs_x), .cfg_offs_y(offs_y),
    .ext_wr, .ext_waddr, .ext_wdata, .ext_rd, .ext_raddr, .ext_rdata);

  // ---------------- IP-side models
  // IP register bus model: records writes, returns 0xA500_0000 | addr
  logic [31:0] ext_last_waddr, ext_last_wdata; int ext_wr_cnt = 0;
  always_ff @(posedge clk) begin
    if (ext_wr) begin ext_last_waddr <= 32'(ext_waddr); ext_last_wdata <= ext_wdata; ext_wr_cnt++; end
    if (ext_rd) ext_rdata <= 32'hA500_0000 | 32'(ext_raddr);
  end

  // Frame buffer model: stores writes, counts them, and checks that no
  // write follows gen_start and that tready is low while generating
  logic [PIX_W-1:0] fb [MAX_H][MAX_W];
  int               fb_cnt [MAX_H][MAX_W];
  int               n_writes = 0, n_starts = 0;
  bit               write_after_start = 0;
  always @(posedge clk) begin
    if (fb_we) begin
      fb[fb_wy][fb_wx] <= fb_wdata; fb_cnt[fb_wy][fb_wx]++; n_writes++;
      if (n_starts > 0) write_after_start = 1;
    end
    if (gen_start) n_starts++;
    if (dut.state == 2 && s_tready) begin errors++; $display("ERROR: tready during GENERATE"); end
  end

  // Drive one input beat with random idle cycles
  task automatic beat(logic [PIX_W-1:0] d, bit u, bit l);
    @(negedge clk);
    while ($urandom_range(3, 0) == 0) begin s_tvalid = 0; @(negedge clk); end
    s_tvalid = 1; s_tdata = d; s_tuser = u; s_tlast = l;
    do @(posedge clk); while (!s_tready);
    @(negedge clk); s_tvalid = 0; s_tuser = 0; s_tlast = 0;
  endtask

  // send a frame; returns expected pixel values in exp
  logic [PIX_W-1:0] exp_img [MAX_H][MAX_W];
  // Send an input frame (optionally junk first, a restarted partial
  // frame, or one wrong tlast); the expected image is kept in exp_img
  task automatic frame(int w, int h, int junk, bit bad_eol, int restart_at);
    for (int k = 0; k < junk; k++) beat(PIX_W'($urandom), 0, 0);
    if (restart_at > 0)                             // partial frame, then new SOF
      for (int k = 0; k < restart_at; k++) beat(PIX_W'($urandom), k == 0, 0);
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) begin
      exp_img[y][x] = PIX_W'($urandom);
      beat(exp_img[y][x], x == 0 && y == 0, (x == w - 1) ^ (bad_eol && y == 1 && x == 0));
    end
  endtask

  // Complete capture scenario: configure, enable, send a frame, check the
  // frame-buffer writes, gen_start and STATUS, emulate gen_done, check
  // FRAME_CNT / FRAME_DONE / error bits, then disable and clear
  task automatic capture_test(int w, int h, int junk, bit bad_eol, int restart_at);
    logic [31:0] st, fc0, fc1;
    e_pre = errors;
    for (int y = 0; y < MAX_H; y++) for (int x = 0; x < MAX_W; x++) fb_cnt[y][x] = 0;
    n_writes = 0; n_starts = 0; write_after_start = 0;
    axil_read(12'h020, fc0);
    axil_write(12'h008, {16'(h), 16'(w)});
    axil_write(12'h004, 32'hE);
    axil_write(12'h000, 1);
    frame(w, h, junk, bad_eol, restart_at);
    repeat (5) @(posedge clk);
    checks += 3;
    if (n_starts != 1) begin errors++; $display("ERROR: gen_start pulses=%0d", n_starts); end
    if (write_after_start) begin errors++; $display("ERROR: fb write after gen_start"); end
    if (n_writes != w * h + restart_at) begin errors++; $display("ERROR: writes %0d", n_writes); end
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) begin
      checks++;
      if (fb[y][x] !== exp_img[y][x]) begin
        errors++; $display("ERROR: fb(%0d,%0d)=%0h exp %0h", x, y, fb[y][x], exp_img[y][x]);
      end
    end
    axil_check(12'h004, 32'h21, 32'h23);   // busy, generating, not done yet
    @(negedge clk) gen_done = 1; @(negedge clk) gen_done = 0;
    axil_read(12'h004, st);
    checks += 4;
    if (!st[1]) begin errors++; $display("ERROR: FRAME_DONE not set"); end
    if (st[2] !== (junk > 0 || restart_at > 0)) begin errors++; $display("ERROR: SOF_ERR=%0b", st[2]); end
    if (st[3] !== bad_eol) begin errors++; $display("ERROR: EOL_ERR=%0b", st[3]); end
    if (!st[4]) begin errors++; $display("ERROR: not back in CAPTURE with ENABLE=1"); end
    axil_read(12'h020, fc1);
    checks++;
    if (fc1 != fc0 + 1) begin errors++; $display("ERROR: FRAME_CNT"); end
    axil_write(12'h000, 0);
    axil_write(12'h004, 32'hE);
    axil_check(12'h004, 32'h0, 32'h3F);   // idle, sticky bits cleared
    tests++;
    $display("capture %0dx%0d junk=%0d bad_eol=%0b restart=%0d : %s", w, h, junk, bad_eol,
             restart_at, errors == e_pre ? "pass" : "FAIL");
  endtask
  int e_pre;

  // Main sequence: register checks, ext bus forwarding, then captures
  initial begin
    reset_dut();
    // reset values / identification
    axil_check(12'h000, 0);
    axil_check(12'h008, 32'h0001_0001);
    axil_check(12'h010, 32'h0001_0000);
    axil_check(12'h024, 32'hCAFE_0001);
    axil_check(12'h028, 32'h1234_5678);
    axil_check(12'h02C, {16'(MAX_H), 16'(MAX_W)});
    // read/write
    axil_write(12'h00C, 32'h0123_0456); axil_check(12'h00C, 32'h0123_0456);
    axil_write(12'h010, 32'h0002_8000); axil_check(12'h010, 32'h0002_8000);
    axil_write(12'h014, 32'h0000_C000); axil_check(12'h014, 32'h0000_C000);
    axil_write(12'h018, 32'hFFFF_C000); axil_check(12'h018, 32'hFFFF_C000);
    axil_write(12'h01C, 32'h0000_2000); axil_check(12'h01C, 32'h0000_2000);
    checks++;
    if (out_w != 16'h0456 || out_h != 16'h0123 || offs_x != -32'sh4000) begin
      errors++; $display("ERROR: cfg outputs");
    end
    // extension bus
    axil_write(12'h044, 32'hDEAD_BEEF);
    axil_write(16'h2abc, 32'h0000_1234);
    checks++;
    if (ext_wr_cnt != 2 || ext_last_waddr != 32'h2abc || ext_last_wdata != 32'h1234) begin
      errors++; $display("ERROR: ext write forwarding");
    end
    axil_check(12'h040, 32'hA500_0040);
    axil_check(16'h1ffc, 32'hA500_1ffc);
    // captures
    capture_test(5, 4, 0, 0, 0);
    capture_test(MAX_W, MAX_H, 0, 0, 0);
    capture_test(1, 1, 0, 0, 0);
    capture_test(9, 3, 4, 0, 0);        // junk before SOF
    capture_test(6, 5, 0, 1, 0);        // wrong tlast
    capture_test(7, 6, 0, 0, 5);        // SOF mid-frame -> restart
    finish_report();
  end

  // ---------------------------------------------------------------- waveform dump
  // Writes a VCD of the whole testbench hierarchy.
  //   +VCD=<file>  output file (default tb_scaler_ctrl.vcd in the working directory)
  //   +NO_VCD      disable dumping (faster, no large file)
  // With the Verilator simulator, compile with --trace (tools/run_sim.sh does).
  initial begin : vcd_dump
    string vcd_file;
    if (!$test$plusargs("NO_VCD")) begin
      if (!$value$plusargs("VCD=%s", vcd_file)) vcd_file = "tb_scaler_ctrl.vcd";
      $dumpfile(vcd_file);
      $dumpvars(0, tb_scaler_ctrl);
    end
  end
endmodule
