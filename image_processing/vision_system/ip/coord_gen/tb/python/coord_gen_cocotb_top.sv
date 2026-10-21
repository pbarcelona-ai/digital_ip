// ***************
// Filename: coord_gen_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of coord_gen for the comparison with its
//   model (coord_gen_tb.py): the calib_params_t fields as separate ports
//   (Q16.16, model_sel 3 bits), the request and the result as ports.
//   Clock - clk. Reset - rst_n (synchronous, active low, as coord_gen).
// Date: 2026-10-21
module coord_gen_cocotb_top (
  input  logic               clk,
  input  logic               rst_n,
  input  logic signed [31:0] cx_pix, cy_pix, fx_pix, fy_pix,
  input  logic        [31:0] recip_fx, recip_fy,
  input  logic signed [31:0] k1, k2, k3, p1, p2,
  input  logic signed [31:0] h11, h12, h13, h21, h22, h23, h31, h32,
  input  logic        [2:0]  model_sel,
  input  logic               in_valid,
  input  logic [barrel_pkg::COORD_W-1:0] in_x,
  input  logic [barrel_pkg::COORD_W-1:0] in_y,
  output logic               out_valid,
  output logic signed [31:0] out_sx_q16,
  output logic signed [31:0] out_sy_q16,
  output logic               busy
);
  distortion_model_pkg::calib_params_t cfg;
  always_comb begin
    cfg.cx_pix = cx_pix;
    cfg.cy_pix = cy_pix;
    cfg.fx_pix = fx_pix;
    cfg.fy_pix = fy_pix;
    cfg.recip_fx = recip_fx;
    cfg.recip_fy = recip_fy;
    cfg.k1 = k1;
    cfg.k2 = k2;
    cfg.k3 = k3;
    cfg.p1 = p1;
    cfg.p2 = p2;
    cfg.h11 = h11;
    cfg.h12 = h12;
    cfg.h13 = h13;
    cfg.h21 = h21;
    cfg.h22 = h22;
    cfg.h23 = h23;
    cfg.h31 = h31;
    cfg.h32 = h32;
    cfg.model_sel = distortion_model_pkg::distortion_model_e'(model_sel);
  end
  coord_gen u_dut (
    .clk,
    .rst_n,
    .cfg,
    .in_valid,
    .in_x,
    .in_y,
    .out_valid,
    .out_sx_q16,
    .out_sy_q16,
    .busy
  );
endmodule
