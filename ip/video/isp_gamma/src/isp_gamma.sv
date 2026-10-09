// ***************
// Filename: isp_gamma.sv
// Author: FPGA Cores 4 U
// Description: Gamma / tone curve lookup for RGB. Version 1.0.0. One
//   programmable curve of 2^IN_W entries x OUT_W bits is applied to all
//   three components (three copies of the table, written together, so
//   one pixel per clock). Write the table through lut_we_i / lut_addr_i /
//   lut_data_i at any time; a frame in flight may see a mix of old and new
//   entries. Power-up contents are the linear curve in >> (IN_W - OUT_W)
//   (FPGA RAM initialisation). bypass_i (sampled at each frame start)
//   outputs in >> (IN_W - OUT_W) for every component, i.e. the linear curve
//   without the table. Pixel {B, G, R}, component 0 in the LSBs. Clock -
//   clk only. Reset - synchronous rst_n (active low). Latency - 1 clock.
// Date: 2026-10-01
module isp_gamma #(
  parameter int IN_W  = 10,
  parameter int OUT_W = 8
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              bypass_i,
  input  logic              lut_we_i,
  input  logic [IN_W-1:0]   lut_addr_i,
  input  logic [OUT_W-1:0]  lut_data_i,
  input  logic [3*IN_W-1:0] s_axis_tdata,
  input  logic              s_axis_tlast,
  input  logic              s_axis_tuser,
  input  logic              s_axis_tvalid,
  output logic              s_axis_tready,
  output logic [3*OUT_W-1:0] m_axis_tdata,
  output logic              m_axis_tlast,
  output logic              m_axis_tuser,
  output logic              m_axis_tvalid,
  input  logic              m_axis_tready
);
  if (OUT_W > IN_W) begin : g_bad $error("isp_gamma: OUT_W must be <= IN_W"); end
  wire en = !m_axis_tvalid || m_axis_tready;
  assign s_axis_tready = en;
  wire acc = s_axis_tvalid && en;

  logic by_f, by_q;
  wire  by = s_axis_tuser ? bypass_i : by_f;
  logic [3*OUT_W-1:0] lin_q, lut_q;

  for (genvar k = 0; k < 3; k++) begin : g_lut
    logic [OUT_W-1:0] mem [2**IN_W];
    initial for (int a = 0; a < 2**IN_W; a++) mem[a] = OUT_W'(a >> (IN_W - OUT_W));
    always_ff @(posedge clk) begin
      if (lut_we_i) mem[lut_addr_i] <= lut_data_i;
      if (en) lut_q[k*OUT_W +: OUT_W] <= mem[s_axis_tdata[k*IN_W +: IN_W]];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      by_f <= 1'b0;
      by_q <= 1'b0;
      lin_q <= '0;
      m_axis_tvalid <= 1'b0;
      m_axis_tlast <= 1'b0;
      m_axis_tuser <= 1'b0;
    end else if (en) begin
      if (acc && s_axis_tuser) by_f <= bypass_i;
      by_q <= by;
      for (int k = 0; k < 3; k++) lin_q[k*OUT_W +: OUT_W] <= s_axis_tdata[k*IN_W + IN_W - OUT_W +: OUT_W];
      m_axis_tvalid <= acc;
      m_axis_tlast <= s_axis_tlast;
      m_axis_tuser <= s_axis_tuser;
    end
  end
  assign m_axis_tdata = by_q ? lin_q : lut_q;
endmodule
