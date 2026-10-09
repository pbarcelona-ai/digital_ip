// ***************
// Filename: isp_csc.sv
// Author: FPGA Cores 4 U
// Description: RGB to YCbCr 4:4:4 colour space converter, 8-bit, limited
//   range (Y 16-235, Cb/Cr 16-240). Version 1.0.0. Integer coefficients
//   (x/256), rounded:
//     BT.601: Y = 16 + ( 66R + 129G +  25B + 128) >> 8
//             Cb = 128 + (-38R -  74G + 112B + 128) >> 8
//             Cr = 128 + (112R -  94G -  18B + 128) >> 8
//     BT.709: Y = 16 + ( 47R + 157G +  16B + 128) >> 8
//             Cb = 128 + (-26R -  86G + 112B + 128) >> 8
//             Cr = 128 + (112R - 102G -  10B + 128) >> 8
//   (>> is an arithmetic shift.) bt709_i selects the matrix. Output pixel
//   {Cb, Y, Cr} (component 0 = Cr in the LSBs), so each component lands on
//   the HDMI channel that carries it in YCbCr 4:4:4 (red channel Cr, green
//   channel Y, blue channel Cb). bypass_i passes RGB unchanged. Both are
//   sampled at each frame start. Clock - clk only. Reset - synchronous
//   rst_n (active low). Latency - 2 clocks.
// Date: 2026-10-01
module isp_csc (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        bypass_i,
  input  logic        bt709_i,
  input  logic [23:0] s_axis_tdata,          // {B, G, R}
  input  logic        s_axis_tlast,
  input  logic        s_axis_tuser,
  input  logic        s_axis_tvalid,
  output logic        s_axis_tready,
  output logic [23:0] m_axis_tdata,          // {Cb, Y, Cr} or {B, G, R} when bypassed
  output logic        m_axis_tlast,
  output logic        m_axis_tuser,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready
);
  wire en = !m_axis_tvalid || m_axis_tready;
  assign s_axis_tready = en;
  wire acc = s_axis_tvalid && en;

  logic by_f, m709_f;
  wire  by   = s_axis_tuser ? bypass_i : by_f;
  wire  m709 = s_axis_tuser ? bt709_i  : m709_f;

  wire signed [9:0] r = {2'b00, s_axis_tdata[7:0]}, g = {2'b00, s_axis_tdata[15:8]}, b = {2'b00, s_axis_tdata[23:16]};
  logic signed [18:0] sy, scb, scr;
  logic [23:0] d1;
  logic v1, l1, u1, b1;

  function automatic logic [7:0] clamp(input logic signed [18:0] x);
    clamp = (x < 0) ? 8'd0 : (x > 255) ? 8'd255 : x[7:0];
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      by_f <= 1'b0;
      m709_f <= 1'b0;
      v1 <= 1'b0;
      l1 <= 1'b0;
      u1 <= 1'b0;
      b1 <= 1'b0;
      d1 <= '0;
      sy <= '0;
      scb <= '0;
      scr <= '0;
      m_axis_tvalid <= 1'b0;
      m_axis_tdata <= '0;
      m_axis_tlast <= 1'b0;
      m_axis_tuser <= 1'b0;
    end else if (en) begin
      if (acc && s_axis_tuser) begin
        by_f <= bypass_i;
        m709_f <= bt709_i;
      end
      if (m709) begin
        sy  <= 47 * r + 157 * g + 16 * b + 128;
        scb <= -26 * r - 86 * g + 112 * b + 128;
        scr <= 112 * r - 102 * g - 10 * b + 128;
      end else begin
        sy  <= 66 * r + 129 * g + 25 * b + 128;
        scb <= -38 * r - 74 * g + 112 * b + 128;
        scr <= 112 * r - 94 * g - 18 * b + 128;
      end
      d1 <= s_axis_tdata;
      v1 <= acc;
      l1 <= s_axis_tlast;
      u1 <= s_axis_tuser;
      b1 <= by;
      m_axis_tvalid <= v1;
      m_axis_tlast <= l1;
      m_axis_tuser <= u1;
      m_axis_tdata  <= b1 ? d1 : {clamp(128 + (scb >>> 8)), clamp(16 + (sy >>> 8)), clamp(128 + (scr >>> 8))};
    end
  end
endmodule
