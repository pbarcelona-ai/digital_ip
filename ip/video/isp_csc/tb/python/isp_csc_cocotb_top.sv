// ***************
// Filename: isp_csc_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of isp_csc for the comparison with its model
//   (isp_csc_tb.py): the streams as s_* / m_* ports, bypass and the matrix select as ports.
//   Clock - clk. Reset - rst_n (synchronous, active low).
// Date: 2026-10-21
module isp_csc_cocotb_top (
  input  logic          clk,
  input  logic          rst_n,
  input  logic          bypass_i,
  input  logic          bt709_i,
  input  logic [24-1:0] s_tdata,
  input  logic          s_tvalid,
  output logic          s_tready,
  input  logic          s_tlast,
  input  logic          s_tuser,
  output logic [24-1:0] m_tdata,
  output logic          m_tvalid,
  input  logic          m_tready,
  output logic          m_tlast,
  output logic          m_tuser
);
  axis_if #(.DATA_W(24)) si ();
  axis_if #(.DATA_W(24)) mi ();
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
  isp_csc u_dut (
    .clk,
    .rst_n,
    .bypass_i,
    .bt709_i,
    .s_axis(si),
    .m_axis(mi)
  );
  wire unused_ok = &{1'b0, si.tkeep, mi.tkeep, 1'b0};
endmodule
