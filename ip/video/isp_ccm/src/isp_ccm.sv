// ***************
// Filename: isp_ccm.sv
// Author: FPGA Cores 4 U
// Description: 3x3 colour correction matrix with offsets. Version 1.0.0.
//     out[i] = clamp((sum_j coef[i][j] * in[j] + 512) >> 10 + off[i], 0, 2^PW-1)
//   i, j: 0 = R, 1 = G, 2 = B. Coefficients are signed Q5.10 (16 bits,
//   1024 = 1.0, range -32 .. +31.999), coef_i[(3*i + j)*16 +: 16]; offsets
//   are signed, in output units, off_i[i*16 +: 16]. Identity is
//   coef = diag(1024), off = 0. The arithmetic shift rounds half up.
//   bypass_i (sampled at each frame start) passes pixels unchanged through
//   the same latency. Pixel {B, G, R}, component 0 in the LSBs. Clock - clk
//   only. Reset - synchronous rst_n (active low). Latency - 3 clocks,
//   1 pixel per clock (9 multipliers, map to DSP blocks).
// Date: 2026-10-01
module isp_ccm #(
  parameter int PW = 10
) (
  input  logic            clk,
  input  logic            rst_n,
  input  logic            bypass_i,
  input  logic [9*16-1:0] coef_i,
  input  logic [3*16-1:0] off_i,
  input  logic [3*PW-1:0] s_axis_tdata,
  input  logic            s_axis_tlast,
  input  logic            s_axis_tuser,
  input  logic            s_axis_tvalid,
  output logic            s_axis_tready,
  output logic [3*PW-1:0] m_axis_tdata,
  output logic            m_axis_tlast,
  output logic            m_axis_tuser,
  output logic            m_axis_tvalid,
  input  logic            m_axis_tready
);
  localparam int MW = PW + 17;                 // product width (unsigned PW+1 x signed 16)
  localparam int SW = MW + 3;                  // sum of 3 products + rounding + offset

  wire en = !m_axis_tvalid || m_axis_tready;
  assign s_axis_tready = en;
  wire acc = s_axis_tvalid && en;

  logic by_f;
  wire  by = s_axis_tuser ? bypass_i : by_f;

  // Stage 1: products
  logic signed [MW-1:0] p [3][3];
  logic [3*PW-1:0] d1; logic v1, l1, u1, b1;
  // Stage 2: sums
  logic signed [SW-1:0] sum [3];
  logic [3*PW-1:0] d2; logic v2, l2, u2, b2;

  function automatic logic [PW-1:0] clamp(input logic signed [SW-1:0] x);
    if (x < 0)                                 clamp = '0;
    else if (x > $signed({1'b0, {PW{1'b1}}}))  clamp = '1;
    else                                       clamp = x[PW-1:0];
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      by_f <= 1'b0; v1 <= 1'b0; v2 <= 1'b0; l1 <= 1'b0; l2 <= 1'b0; u1 <= 1'b0; u2 <= 1'b0; b1 <= 1'b0; b2 <= 1'b0;
      d1 <= '0; d2 <= '0;
      m_axis_tvalid <= 1'b0; m_axis_tdata <= '0; m_axis_tlast <= 1'b0; m_axis_tuser <= 1'b0;
    end else if (en) begin
      if (acc && s_axis_tuser) by_f <= bypass_i;
      for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++)
        p[i][j] <= $signed({1'b0, s_axis_tdata[j*PW +: PW]}) * $signed(coef_i[(3*i + j)*16 +: 16]);
      d1 <= s_axis_tdata; v1 <= acc; l1 <= s_axis_tlast; u1 <= s_axis_tuser; b1 <= by;

      for (int i = 0; i < 3; i++)
        sum[i] <= ((SW'(p[i][0]) + SW'(p[i][1]) + SW'(p[i][2]) + SW'(512)) >>> 10) + SW'($signed(off_i[i*16 +: 16]));
      d2 <= d1; v2 <= v1; l2 <= l1; u2 <= u1; b2 <= b1;

      m_axis_tvalid <= v2; m_axis_tlast <= l2; m_axis_tuser <= u2;
      m_axis_tdata  <= b2 ? d2 : {clamp(sum[2]), clamp(sum[1]), clamp(sum[0])};
    end
  end
endmodule
