// ***************
// Filename: tb_bounded_bicubic_radial.sv
// Author: FPGA Cores 4 U
// Description: Large-frame scale-verification test. Configures the
// DUT at true full 480x480 in bicubic+radial mode and verifies
// a bounded partial capture (tens of thousands of pixels, many
// full rows) bit-exact vs. the golden model, since bicubic mode
// cannot complete a full frame in a practical simulation time.
//   The test tasks are in tests/bounded_bicubic_radial_tests.sv (`included).
// Date: September 26, 2026
// ***************
`timescale 1ns/1ps
import barrel_pkg::*;
import distortion_model_pkg::*;
import golden_model_pkg::generate_synthetic_chart;
import golden_model_pkg::make_remap_cfg;
import golden_model_pkg::radial_remap_ref;
import golden_model_pkg::full_remap_ref;
import golden_model_pkg::radial_remap_bicubic_ref;
import golden_model_pkg::fit_division_model_coeffs;
import golden_model_pkg::invert_homography;
import golden_model_pkg::remap_cfg_t;
module tb_bounded_bicubic_radial;
  logic clk=0, rst_n=0;
  always #5 clk=~clk;

  axis_if #(.DATA_W(PIX_W), .USER_W(1)) s_axis ();
  axis_if #(.DATA_W(PIX_W), .USER_W(1)) m_axis ();
  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();

  vision_system dut (
    .clk,
    .rst_n,
    .s_axis(s_axis),
    .m_axis(m_axis),
    .s_axil(s_axil)
  );

  logic [7:0] src_r[];
  logic [7:0] src_g[];
  logic [7:0] src_b[];
  logic [7:0] gold_r[];
  logic [7:0] gold_g[];
  logic [7:0] gold_b[];
  logic [7:0] cap_r[];
  logic [7:0] cap_g[];
  logic [7:0] cap_b[];
  int cap_count, max_cap, i, d, max_err, mismatches;
  logic [31:0] status_val;
  remap_cfg_t cfg;
  int W, H;

  // test tasks: tests/bounded_bicubic_radial_tests.sv
  `include "bounded_bicubic_radial_tests.sv"

  initial begin
    m_axis.tready<=1'b1;
    s_axis.tvalid<=1'b0;
    s_axis.tlast<=1'b0;
    s_axis.tuser<=1'b0;
    s_axis.tdata<='0;
    s_axil.awvalid<=1'b0;
    s_axil.wvalid<=1'b0;
    s_axil.bready<=1'b0;
    s_axil.arvalid<=1'b0;
    s_axil.rready<=1'b0;
    rst_n=1'b0;
    repeat(5) @(posedge clk);
    rst_n=1'b1;
    repeat(5) @(posedge clk);

    W=480;
    H=480;
    max_cap=45000;
    generate_synthetic_chart(W,H,src_r,src_g,src_b);
    cfg = make_remap_cfg(W,H,32'h0000_8000,32'h0000_8000,32'h0001_0000);

    radial_remap_bicubic_ref(cfg, longint'($rtoi(0.08*65536.0)), longint'($rtoi(-0.01*65536.0)), 0, src_r,src_g,src_b, gold_r,gold_g,gold_b);

    axil_write(8'h30, 0);
    axil_write(8'h4C, 0);
    axil_write(8'h2C, 1);
    axil_write(8'h10, longint'($rtoi(0.08*65536.0)));
    axil_write(8'h14, longint'($rtoi(-0.01*65536.0)));
    axil_write(8'h18, 0);
    axil_write(8'h1C, 32'h0000_8000);
    axil_write(8'h20, 32'h0000_8000);
    axil_write(8'h24, 32'h0001_0000);
    axil_write(8'h08, W);
    axil_write(8'h0C, H);

    status_val=32'hFFFF_FFFF;
    i=0;
    while (i<200 && status_val[2]!==1'b0) begin
      axil_read(8'h04, status_val);
      if (status_val[2]===1'b0) i=200;
      else begin
        @(posedge clk);
        i++;
      end
    end

    // stream_frame_in runs detached (input streaming completes fast and
    // unconditionally streams the WHOLE frame, independent of how slow
    // the DISTORTION model's output pacing is); capture_bounded is
    // awaited explicitly since IT determines when we have enough output
    // pixels to check -- using join_any here was a real testbench bug
    // (caught by this exact large-scale run): it returned as soon as
    // the fast input side finished, long before capture_bounded had
    // gathered anywhere near max_cap pixels for the slow output side,
    // leaving most of the capture buffer at its zero-initialized
    // default and comparing that (not real captured data) against gold.
    fork
      stream_frame_in(W,H,src_r,src_g,src_b);
    join_none
    capture_bounded(W,max_cap);

    max_err=0;
    mismatches=0;
    for (i=0;i<max_cap;i++) begin
      d=int'(cap_r[i])-int'(gold_r[i]);
      if(d<0) d=-d;
      if(d>max_err) max_err=d;
      if(d>1) mismatches++;
      d=int'(cap_g[i])-int'(gold_g[i]);
      if(d<0) d=-d;
      if(d>max_err) max_err=d;
      if(d>1) mismatches++;
      d=int'(cap_b[i])-int'(gold_b[i]);
      if(d<0) d=-d;
      if(d>max_err) max_err=d;
      if(d>1) mismatches++;
    end
    $display("bicubic_radial %0dx%0d (bounded to %0d/%0d pixels = %0d full rows): max_err=%0d mismatches=%0d/%0d",
               W,H,max_cap,W*H,max_cap/W, max_err, mismatches, max_cap*3);
    if (mismatches==0 && max_err<=1) $display(">>> PASS <<<");
    else $display(">>> FAIL <<<");
    $finish;
  end

  // Optional waveform dump: compile with -DDUMP_VCD (the run scripts do this
  // when VCD=1; SURFER=1 then opens it, see synth/view_waves.sh).
`ifdef DUMP_VCD
  initial begin
    $dumpfile("tb_bounded_bicubic_radial.vcd");
    $dumpvars(0, tb_bounded_bicubic_radial);
  end
`endif
endmodule
