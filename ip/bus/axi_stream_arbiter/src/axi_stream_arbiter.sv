// ***************
// Filename: axi_stream_arbiter.sv
// Author: FPGA Cores 4 U
// Description: AXI-Stream arbiter (N inputs to one output). Version 1.0.0.
//   Packet-granular arbitration - once an input wins, it keeps the output
//   until its tlast beat has been transferred, so packets from different
//   inputs are never interleaved. PRIORITY 0 is round-robin (the input
//   after the last winner is preferred), 1 is fixed priority with input 0
//   highest. Signals are packed vectors (input i uses slice i). The output
//   is a registered slice (one extra register stage, full throughput).
//   Clock - aclk. Reset - synchronous aresetn, idle, no owner. Latency - 2
//   clocks from arbitration to first output beat; back-to-back packets
//   from different inputs add 1 idle clock. Errors - a packet longer than
//   TIMEOUT beats without tlast releases the grant (locked_out inputs are
//   not starved) and raises hog_o; TIMEOUT=0 disables. NIN<2 rejected at
//   elaboration.
// Date: 2026-09-29
module axi_stream_arbiter #(
  parameter int NIN      = 4,
  parameter int DATA_W   = 32,
  parameter int USER_W   = 1,
  parameter int PRIORITY = 0,
  parameter int TIMEOUT  = 0
) (
  input  logic                     aclk,
  input  logic                     aresetn,
  input  logic [NIN*DATA_W-1:0]    s_axis_tdata,
  input  logic [NIN*(DATA_W/8)-1:0] s_axis_tkeep,
  input  logic [NIN-1:0]           s_axis_tlast,
  input  logic [NIN*USER_W-1:0]    s_axis_tuser,
  input  logic [NIN-1:0]           s_axis_tvalid,
  output logic [NIN-1:0]           s_axis_tready,
  output logic [DATA_W-1:0]        m_axis_tdata,
  output logic [DATA_W/8-1:0]      m_axis_tkeep,
  output logic                     m_axis_tlast,
  output logic [USER_W-1:0]        m_axis_tuser,
  output logic [$clog2(NIN)-1:0]   m_axis_tid,
  output logic                     m_axis_tvalid,
  input  logic                     m_axis_tready,
  output logic                     hog_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam int IW = $clog2(NIN);
  if (NIN < 2) begin : g_bn $error("axi_stream_arbiter: NIN must be >= 2"); end
  if (PRIORITY < 0 || PRIORITY > 1) begin : g_bp $error("axi_stream_arbiter: PRIORITY must be 0 or 1"); end
  int arb_idx;
  logic busy;
  logic [IW-1:0] owner, last;
  logic [IW-1:0] pick;
  logic pick_v;
  always_comb begin
    pick = '0;
    pick_v = 1'b0;
    if (PRIORITY == 1) begin
      for (int i = NIN-1; i >= 0; i--) if (s_axis_tvalid[i]) begin
        pick = IW'(i);
        pick_v = 1'b1;
      end
    end else begin
      for (int k = NIN; k >= 1; k--) begin
        arb_idx = (32'(last) + k) % NIN;
        if (s_axis_tvalid[arb_idx]) begin
          pick = IW'(arb_idx);
          pick_v = 1'b1;
        end
      end
    end
  end
  // output register slice
  logic [DATA_W-1:0] od;
  logic [DATA_W/8-1:0] ok;
  logic ol;
  logic [USER_W-1:0] ou;
  logic [IW-1:0] oi;
  logic ov;
  wire  o_can = ~ov | m_axis_tready;
  logic [$clog2(TIMEOUT > 1 ? TIMEOUT + 1 : 2)-1:0] beats;
  always_comb begin
    s_axis_tready = '0;
    if (busy && o_can) s_axis_tready[owner] = 1'b1;
  end
  wire xfer = busy & s_axis_tvalid[owner] & o_can;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      busy <= 1'b0;
      owner <= '0;
      last <= '0;
      ov <= 1'b0;
      od <= '0;
      ok <= '0;
      ol <= 1'b0;
      ou <= '0;
      oi <= '0;
      hog_o <= 1'b0;
      beats <= '0;
    end
    else begin
      hog_o <= 1'b0;
      if (m_axis_tready) ov <= 1'b0;
      if (!busy) begin
        beats <= '0;
        if (pick_v) begin
          busy <= 1'b1;
          owner <= pick;
        end
      end else if (xfer) begin
        ov <= 1'b1;
        od <= s_axis_tdata[owner*DATA_W +: DATA_W];
        ok <= s_axis_tkeep[owner*(DATA_W/8) +: DATA_W/8];
        ol <= s_axis_tlast[owner];
        ou <= s_axis_tuser[owner*USER_W +: USER_W];
        oi <= owner;
        beats <= beats + 1'b1;
        if (s_axis_tlast[owner]) begin
          busy <= 1'b0;
          last <= owner;
        end
        else if (TIMEOUT != 0 && beats + 1 >= TIMEOUT) begin
          busy <= 1'b0;
          last <= owner;
          hog_o <= 1'b1;
        end
      end
    end
  end
  assign m_axis_tdata = od;
  assign m_axis_tkeep = ok;
  assign m_axis_tlast = ol;
  assign m_axis_tuser = ou;
  assign m_axis_tid = oi;
  assign m_axis_tvalid = ov;
endmodule
