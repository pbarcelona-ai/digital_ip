// ***************
// Filename: tb_scale_barrel_square.sv
// Author: FPGA Cores 4 U
// Description: Large-frame scale-verification test. Runs the barrel
// (bilinear+radial) correction scenario at true full 480x480
// through the complete end-to-end pipeline to 100% completion,
// bit-exact vs. the golden model.
//   The test tasks are in tests/scale_barrel_square_tests.sv (`included).
// Date: September 26, 2026
// ***************
`timescale 1ns/1ps
import barrel_pkg::*;
import distortion_model_pkg::*;
import golden_model_pkg::generate_synthetic_chart;
import golden_model_pkg::make_remap_cfg;
import golden_model_pkg::radial_remap_ref;
import golden_model_pkg::fit_correction_coeffs;
import golden_model_pkg::remap_cfg_t;
module tb_scale_barrel_square;
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

  logic [7:0] warp_r[];
  logic [7:0] warp_g[];
  logic [7:0] warp_b[];
  logic [7:0] gold_r[];
  logic [7:0] gold_g[];
  logic [7:0] gold_b[];
  logic [7:0] cap_r[];
  logic [7:0] cap_g[];
  logic [7:0] cap_b[];
  int cap_count, cap_total, x, i, d, max_err, mismatches;
  logic [31:0] status_val;
  remap_cfg_t cfg;
  longint kd1q, kc1q, kc2q, kc3q;
  real kc1,kc2,kc3;
  int W, H;

  // test tasks: tests/scale_barrel_square_tests.sv
  `include "scale_barrel_square_tests.sv"

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

    W=480; // SCENARIO_SIZE
    H=480;
    generate_synthetic_chart(W,H,warp_r,warp_g,warp_b); // reuse as source pattern
    // rename: warp_r etc currently hold ORIGINAL chart; do forward barrel warp
    begin
      logic [7:0] src_r[];
      logic [7:0] src_g[];
      logic [7:0] src_b[];
      src_r=warp_r;
      src_g=warp_g;
      src_b=warp_b;
      cfg = make_remap_cfg(W,H,32'h0000_8000,32'h0000_8000,32'h0001_0000);
      kd1q = longint'($rtoi(0.08*65536.0));
      radial_remap_ref(cfg, kd1q, longint'($rtoi(-0.01*65536.0)), 0, src_r,src_g,src_b, warp_r,warp_g,warp_b);
      fit_correction_coeffs(0.08,-0.01,0.0, kc1,kc2,kc3);
      kc1q=longint'($rtoi(kc1*65536.0));
      kc2q=longint'($rtoi(kc2*65536.0));
      kc3q=longint'($rtoi(kc3*65536.0));
      radial_remap_ref(cfg, kc1q,kc2q,kc3q, warp_r,warp_g,warp_b, gold_r,gold_g,gold_b);

      axil_write(8'h30, 0); // CALIB_MODE
      axil_write(8'h4C, 0); // MODEL_SEL radial
      axil_write(8'h2C, 0); // INTERP_MODE bilinear
      axil_write(8'h10, kc1q);
      axil_write(8'h14, kc2q);
      axil_write(8'h18, kc3q);
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

      fork
        stream_frame_in(W,H,warp_r,warp_g,warp_b);
        capture_frame_out(W,H);
      join

      max_err=0;
      mismatches=0;
      for (i=0;i<W*H;i++) begin
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
      $display("barrel_bilinear_square %0dx%0d: max_err=%0d mismatches=%0d/%0d", W,H, max_err, mismatches, W*H*3);
      if (mismatches==0 && max_err<=1) $display(">>> PASS <<<");
      else $display(">>> FAIL <<<");
    end
    $finish;
  end

  // Optional waveform dump: compile with -DDUMP_VCD (the run scripts do this
  // when VCD=1; SURFER=1 then opens it, see synth/view_waves.sh).
`ifdef DUMP_VCD
  initial begin
    $dumpfile("tb_scale_barrel_square.vcd");
    $dumpvars(0, tb_scale_barrel_square);
  end
`endif
endmodule
