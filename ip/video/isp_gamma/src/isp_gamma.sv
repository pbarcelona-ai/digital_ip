// ***************
// Filename: isp_gamma.sv
// Author: FPGA Cores 4 U
// Description: Gamma / tone curve lookup for RGB. Version 1.0.0. One
//   programmable curve of 2^IN_W entries x OUT_W bits is applied to all
//   three components (three copies of the table, written together, so
//   one pixel per clock). Write the table through lut_we_i / lut_addr_i /
//   lut_data_i at any time; a frame in flight may see a mix of old and new
//   entries. Power-up contents are the linear curve in >> (IN_W - OUT_W)
//   (FPGA RAM initialisation; a build that defines NO_RAM_INIT, e.g. an
//   ASIC, has no power-up contents and keeps bypass_i set until the table
//   is loaded). bypass_i (sampled at each frame start)
//   outputs in >> (IN_W - OUT_W) for every component, i.e. the linear curve
//   without the table. Pixel {B, G, R}, component 0 in the LSBs. Clock -
//   clk only. Reset - synchronous rst_n (active low). Latency - 4 clocks.
//   The output goes through a 2-entry ip_axis_fifo, so s_axis_tready does
//   not depend combinationally on m_axis_tready (+3 clocks).
//   Golden model: model/isp_gamma_model.py (gamma_frame; tb/python).
// Date: 2026-10-21
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
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = 3*IN_W
  axis_if.slave s_axis,
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = 3*OUT_W
  axis_if.master m_axis
);
  // output stage: the last pipeline register (q_*) feeds a 2-entry FIFO whose ready is registered,
  // so s_axis_tready does not depend combinationally on m_axis_tready
  logic [3*OUT_W-1:0] q_d;
  logic q_l, q_u, q_v, q_r;
  if (OUT_W > IN_W) begin : g_bad $error("isp_gamma: OUT_W must be <= IN_W"); end
  wire en = !q_v || q_r;
  assign s_axis.tready = en;
  wire acc = s_axis.tvalid && en;

  logic by_f, by_q;
  wire  by = s_axis.tuser ? bypass_i : by_f;
  logic [3*OUT_W-1:0] lin_q, lut_q;

  for (genvar k = 0; k < 3; k++) begin : g_lut
    logic [OUT_W-1:0] mem [2**IN_W];
`ifndef NO_RAM_INIT
    // FPGA RAM initialisation: the linear curve (NO_RAM_INIT: none, keep bypass_i set until loaded)
    initial for (int a = 0; a < 2**IN_W; a++) mem[a] = OUT_W'(a >> (IN_W - OUT_W));
`endif
    always_ff @(posedge clk) begin
      if (lut_we_i) mem[lut_addr_i] <= lut_data_i;
      if (en) lut_q[k*OUT_W +: OUT_W] <= mem[s_axis.tdata[k*IN_W +: IN_W]];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      by_f <= 1'b0;
      by_q <= 1'b0;
      lin_q <= '0;
      q_v <= 1'b0;
      q_l <= 1'b0;
      q_u <= 1'b0;
    end else if (en) begin
      if (acc && s_axis.tuser) by_f <= bypass_i;
      by_q <= by;
      for (int k = 0; k < 3; k++) lin_q[k*OUT_W +: OUT_W] <= s_axis.tdata[k*IN_W + IN_W - OUT_W +: OUT_W];
      q_v <= acc;
      q_l <= s_axis.tlast;
      q_u <= s_axis.tuser;
    end
  end
  assign q_d = by_q ? lin_q : lut_q;
  logic [2:0] out_level;                       // not used
  axis_if #(.DATA_W((3*OUT_W))) u_out_fifo_s ();
  assign u_out_fifo_s.tdata = q_d;
  assign u_out_fifo_s.tlast = q_l;
  assign u_out_fifo_s.tuser = q_u;
  assign u_out_fifo_s.tvalid = q_v;
  assign q_r = u_out_fifo_s.tready;
  ip_axis_fifo #(
    .DATA_W(3*OUT_W),
    .DEPTH(2)
  ) u_out_fifo (
    .clk,
    .rst_n,
    .s(u_out_fifo_s),
    .m(m_axis),
    .level_o(out_level)
  );
  wire unused_ok = &{1'b0, out_level, 1'b0};
endmodule
