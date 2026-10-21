// ***************
// Filename: isp_gamma_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of isp_gamma for the comparison with its model
//   (isp_gamma_tb.py): the streams as s_* / m_* ports, bypass and the table write port as ports.
//   Clock - clk. Reset - rst_n (synchronous, active low).
// Date: 2026-10-21
module isp_gamma_cocotb_top #(
  parameter int IN_W = 10,
  parameter int OUT_W = 8
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          bypass_i,
  input  logic          lut_we_i,
  input  logic [IN_W-1:0] lut_addr_i,
  input  logic [OUT_W-1:0] lut_data_i,
  input  logic [3*IN_W-1:0] s_tdata,
  input  logic          s_tvalid,
  output logic          s_tready,
  input  logic          s_tlast,
  input  logic          s_tuser,
  output logic [3*OUT_W-1:0] m_tdata,
  output logic          m_tvalid,
  input  logic          m_tready,
  output logic          m_tlast,
  output logic          m_tuser
);
  axis_if #(.DATA_W(3*IN_W)) si ();
  axis_if #(.DATA_W(3*OUT_W)) mi ();
  assign si.tdata = s_tdata;
  assign si.tvalid = s_tvalid;
  assign s_tready = si.tready;
  assign si.tlast = s_tlast;
  assign si.tuser = s_tuser;
  assign si.tkeep = '1;
  assign m_tdata = mi.tdata;
  assign m_tvalid = mi.tvalid;
  assign mi.tready = m_tready;
  assign m_tlast = mi.tlast;
  assign m_tuser = mi.tuser;
  isp_gamma #(.IN_W(IN_W), .OUT_W(OUT_W)) u_dut (
    .clk,
    .rst_n,
    .bypass_i,
    .lut_we_i,
    .lut_addr_i,
    .lut_data_i,
    .s_axis(si),
    .m_axis(mi)
  );
  wire unused_ok = &{1'b0, si.tkeep, mi.tkeep, 1'b0};
endmodule
