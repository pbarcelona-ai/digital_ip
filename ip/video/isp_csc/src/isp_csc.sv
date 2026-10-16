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
//   rst_n (active low). Latency - 5 clocks. The output goes through a 2-entry ip_axis_fifo, so s_axis_tready does
//   not depend combinationally on m_axis_tready (+3 clocks).
// Date: 2026-10-16
module isp_csc (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        bypass_i,
  input  logic        bt709_i,
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = 24
  axis_if.slave s_axis,
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = 24
  axis_if.master m_axis
);
  // output stage: the last pipeline register (q_*) feeds a 2-entry FIFO whose ready is registered,
  // so s_axis_tready does not depend combinationally on m_axis_tready
  logic [24-1:0] q_d;
  logic q_l, q_u, q_v, q_r;
  wire en = !q_v || q_r;
  assign s_axis.tready = en;
  wire acc = s_axis.tvalid && en;

  logic by_f, m709_f;
  wire  by   = s_axis.tuser ? bypass_i : by_f;
  wire  m709 = s_axis.tuser ? bt709_i  : m709_f;

  wire signed [9:0] r = {2'b00, s_axis.tdata[7:0]}, g = {2'b00, s_axis.tdata[15:8]}, b = {2'b00, s_axis.tdata[23:16]};
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
      q_v <= 1'b0;
      q_d <= '0;
      q_l <= 1'b0;
      q_u <= 1'b0;
    end else if (en) begin
      if (acc && s_axis.tuser) begin
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
      d1 <= s_axis.tdata;
      v1 <= acc;
      l1 <= s_axis.tlast;
      u1 <= s_axis.tuser;
      b1 <= by;
      q_v <= v1;
      q_l <= l1;
      q_u <= u1;
      q_d  <= b1 ? d1 : {clamp(128 + (scb >>> 8)), clamp(16 + (sy >>> 8)), clamp(128 + (scr >>> 8))};
    end
  end
  axis_if #(.DATA_W(24)) u_out_fifo_s ();
  assign u_out_fifo_s.tdata = q_d;
  assign u_out_fifo_s.tlast = q_l;
  assign u_out_fifo_s.tuser = q_u;
  assign u_out_fifo_s.tvalid = q_v;
  assign q_r = u_out_fifo_s.tready;
  ip_axis_fifo #(
    .DATA_W(24),
    .DEPTH(2)
  ) u_out_fifo (
    .clk,
    .rst_n,
    .s(u_out_fifo_s),
    .m(m_axis),
    .level_o()
  );
endmodule
