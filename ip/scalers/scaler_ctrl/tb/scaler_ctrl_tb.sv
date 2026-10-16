// ***************
// Filename: tb_scaler_ctrl.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for scaler_ctrl.
//   Checks common register reset values, read/write and RO ID registers;
//   frame capture (every pixel written once to the right x,y, gen_start
//   pulses once after the last write, input stalled while generating);
//   SOF/EOL error detection, re-sync on SOF, W1C sticky status bits;
//   FRAME_CNT/FRAME_DONE on gen_done, ENABLE loop and return to idle;
//   forwarding of addresses >= 0x40 to the IP register bus; SLVERR on
//   writes to the ID block and read-only words and on unmapped words.
//   Plusargs: +VCD=<file> waveform file, +NO_VCD disables dumping.
//   The test tasks are in tests/scaler_ctrl_tests.sv (`included).
// Date: 2026-10-16

`timescale 1ns/1ps

// -DTB_NBUF=2 builds the DUT as a double (ping-pong) buffer and runs the
// ping-pong sequencing test instead of the single-buffer capture tests.
`ifndef TB_NBUF
`define TB_NBUF 1
`endif
module tb_scaler_ctrl;
  localparam int ADDR_W = 14;
  localparam int PIX_W  = 16;
  localparam int MAX_W  = 32, MAX_H = 24;

  // clock, reset, AXI-Lite master and result reporting
  `include "scaler_tb_axil.svh"

  // stream source and the DUT-side interfaces (IP role played by the tb)
  axis_if #(.DATA_W(PIX_W), .USER_W(1)) s ();
  initial s.tdata = '0;
  initial s.tvalid = 0;
  initial s.tuser = 0;
  initial s.tlast = 0;
  fb_wr_if #(.PIX_W(PIX_W)) dut_fb ();
  logic gen_start;
  logic gen_done = 0;
  logic [15:0] in_w, in_h, out_w, out_h;
  logic [31:0] step_x, step_y;
  logic signed [31:0] offs_x, offs_y;
  logic gen_buf;
  regbus_if #(.ADDR_W(ADDR_W), .DATA_W(32)) ext ();

  // Device under test (distinct IP_ID/CAPS values to check the RO regs)
  axil_if #(.ADDR_W(ADDR_W)) dut_s_axil ();
  assign dut_s_axil.awaddr = awaddr;
  assign dut_s_axil.awvalid = awvalid;
  assign awready = dut_s_axil.awready;
  assign dut_s_axil.wdata = wdata;
  assign dut_s_axil.wstrb = wstrb;
  assign dut_s_axil.wvalid = wvalid;
  assign wready = dut_s_axil.wready;
  assign bresp = dut_s_axil.bresp;
  assign bvalid = dut_s_axil.bvalid;
  assign dut_s_axil.bready = bready;
  assign dut_s_axil.araddr = araddr;
  assign dut_s_axil.arvalid = arvalid;
  assign arready = dut_s_axil.arready;
  assign rdata = dut_s_axil.rdata;
  assign rresp = dut_s_axil.rresp;
  assign rvalid = dut_s_axil.rvalid;
  assign dut_s_axil.rready = rready;
  scaler_ctrl #(.PIX_W(PIX_W), .ADDR_W(ADDR_W), .MAX_W(MAX_W), .MAX_H(MAX_H),
                .IP_ID(32'hCAFE_0001), .CAPS(32'h1234_5678), .NBUF(`TB_NBUF)) dut (
    .clk,
    .rst_n,
    .s_axil(dut_s_axil),
    .s_axis(s),
    .fb(dut_fb),
    .gen_buf,
    .gen_start,
    .gen_done,
    .lb_nxt_y(32'sd0),
    .lb_nxt_v(1'b0),
    .lb_o_y(32'sd0),
    .lb_o_v(1'b0),
    .lb_a_y(32'sd0),
    .lb_a_v(1'b0),
    .lb_hold(),
    .cfg_in_w(in_w),
    .cfg_in_h(in_h),
    .cfg_out_w(out_w),
    .cfg_out_h(out_h),
    .cfg_step_x(step_x),
    .cfg_step_y(step_y),
    .cfg_offs_x(offs_x),
    .cfg_offs_y(offs_y),
    .ext(ext)
  );

  // ---------------- IP-side models
  // IP register bus model: records writes, returns 0xA500_0000 | addr
  logic [31:0] ext_last_waddr, ext_last_wdata;
  int ext_wr_cnt = 0;
  always_ff @(posedge clk) begin
    if (ext.wr) begin
      ext_last_waddr <= 32'(ext.waddr);
      ext_last_wdata <= ext.wdata;
      ext_wr_cnt++;
    end
    if (ext.rd) ext.rdata <= 32'hA500_0000 | 32'(ext.raddr);
  end

  // Frame buffer model: stores writes, counts them, and checks that no
  // write follows gen_start and that tready is low while generating
  logic [PIX_W-1:0] fb [MAX_H][MAX_W];
  logic [PIX_W-1:0] fbp [2][MAX_H][MAX_W];     // per-buffer model (ping-pong)
  int               fb_cnt [MAX_H][MAX_W];
  int               n_writes = 0, n_starts = 0;
  bit               write_after_start = 0;
  always @(posedge clk) begin
    if (dut_fb.en) begin
      fb[dut_fb.y][dut_fb.x] <= dut_fb.data;
      fb_cnt[dut_fb.y][dut_fb.x]++;
      n_writes++;
      fbp[dut_fb.buf_sel][dut_fb.y][dut_fb.x] <= dut_fb.data;
      if (n_starts > 0) write_after_start = 1;
    end
    if (gen_start) n_starts++;
    if (`TB_NBUF == 1 && dut.state == 2 && s.tready) begin
      errors++;
      $display("ERROR: tready during GENERATE");
    end
  end

  // send a frame; returns expected pixel values in exp
  logic [PIX_W-1:0] exp_img [MAX_H][MAX_W];

  // used by task capture_test (tests/scaler_ctrl_tests.sv)
  int e_pre;                            // error count at the start of a scenario

  // Main sequence: register checks, ext bus forwarding, then captures

  // ---------------- ping-pong sequencing test (NBUF = 2)
  // A is captured into buffer 0 and handed to the generator; B is captured
  // into buffer 1 while A is still being generated (no stall); C must stall
  // until A's generation finishes, then lands in buffer 0 while B is
  // generated. Buffer contents, gen_buf and FRAME_CNT are checked.
  logic [PIX_W-1:0] img_b [MAX_H][MAX_W];
  bit send_bg = 0;
  initial forever begin               // background sender for frame C
    wait (send_bg);
    frame(5, 4, 0, 0, 0);
    send_bg = 0;
  end
  // test tasks: tests/scaler_ctrl_tests.sv
  `include "scaler_ctrl_tests.sv"

  initial begin
    reset_dut();
    // reset values / identification
    axil_check(12'h000, 0);
    axil_check(12'h008, 32'h0001_0001);
    axil_check(12'h010, 32'h0001_0000);
    axil_check(12'h024, 32'hCAFE_0001);
    check_id_block('h0, 32'hCAFE_0001);      // ID block: ID, VERSION, DATE
    axil_check(12'h028, 32'h1234_5678);
    axil_check(12'h02C, {16'(MAX_H), 16'(MAX_W)});
    // read/write
    axil_write(12'h00C, 32'h0123_0456);
    axil_check(12'h00C, 32'h0123_0456);
    axil_write(12'h010, 32'h0002_8000);
    axil_check(12'h010, 32'h0002_8000);
    axil_write(12'h014, 32'h0000_C000);
    axil_check(12'h014, 32'h0000_C000);
    axil_write(12'h018, 32'hFFFF_C000);
    axil_check(12'h018, 32'hFFFF_C000);
    axil_write(12'h01C, 32'h0000_2000);
    axil_check(12'h01C, 32'h0000_2000);
    checks++;
    if (out_w != 16'h0456 || out_h != 16'h0123 || offs_x != -32'sh4000) begin
      errors++;
      $display("ERROR: cfg outputs");
    end
    // extension bus
    axil_write(12'h044, 32'hDEAD_BEEF);
    axil_write(16'h2abc, 32'h0000_1234);
    checks++;
    if (ext_wr_cnt != 2 || ext_last_waddr != 32'h2abc || ext_last_wdata != 32'h1234) begin
      errors++;
      $display("ERROR: ext write forwarding");
    end
    axil_check(12'h040, 32'hA500_0040);
    axil_check(16'h1ffc, 32'hA500_1ffc);
    // refused accesses (SLVERR, no effect): read-only words, unmapped words
    axil_write_err(axil_map('h020), 32'h5555_5555);      // FRAME_CNT
    axil_write_err(axil_map('h024), 32'h5555_5555);      // IP_ID
    axil_check(12'h024, 32'hCAFE_0001);
    axil_write_err(axil_map('h030), 32'h5555_5555);      // unmapped
    axil_read_err(axil_map('h03C));
    checks++;
    if (ext_wr_cnt != 2) begin
      errors++;
      $display("ERROR: a refused write reached the IP bus");
    end
    // captures
    if (`TB_NBUF == 2) pingpong_test();
    else begin
      capture_test(5, 4, 0, 0, 0);
      capture_test(MAX_W, MAX_H, 0, 0, 0);
      capture_test(1, 1, 0, 0, 0);
      capture_test(9, 3, 4, 0, 0);        // junk before SOF
      capture_test(6, 5, 0, 1, 0);        // wrong tlast
      capture_test(7, 6, 0, 0, 5);        // SOF mid-frame -> restart
    end
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
