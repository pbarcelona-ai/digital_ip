// ***************
// Filename: vision_system_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of vision_system for the comparison with its
//   model (vision_system_tb.py): the streams as s_* / m_* ports, the
//   register bus as flattened axi_* ports (ADDR_W 8), the on-chip frame
//   store sized by ADDR_W / FB_DEPTH (small frames), or (USE_EXT_FB) the
//   SDRAM store with a short power-up wait: its data bus split as in
//   ext_frame_buffer_cocotb_top (dq_seen the bus, the test's SDRAM
//   responder drives tb_dq onto it unless the controller issues a WRITE).
//   Clock - clk. Reset - rst_n (synchronous, active low).
// Date: 2026-10-21
module vision_system_cocotb_top #(
  parameter int ADDR_W     = 12,
  parameter int FB_DEPTH   = 4096,
  parameter bit USE_EXT_FB = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [23:0] s_tdata,
  input  logic        s_tvalid,
  output logic        s_tready,
  input  logic        s_tlast,
  input  logic        s_tuser,
  output logic [23:0] m_tdata,
  output logic        m_tvalid,
  input  logic        m_tready,
  output logic        m_tlast,
  output logic        m_tuser,
  input  logic [7:0]  axi_awaddr,
  input  logic        axi_awvalid,
  output logic        axi_awready,
  input  logic [31:0] axi_wdata,
  input  logic [3:0]  axi_wstrb,
  input  logic        axi_wvalid,
  output logic        axi_wready,
  output logic [1:0]  axi_bresp,
  output logic        axi_bvalid,
  input  logic        axi_bready,
  input  logic [7:0]  axi_araddr,
  input  logic        axi_arvalid,
  output logic        axi_arready,
  output logic [31:0] axi_rdata,
  output logic [1:0]  axi_rresp,
  output logic        axi_rvalid,
  input  logic        axi_rready,
  output logic        sdram_cs_n,
  output logic        sdram_ras_n,
  output logic        sdram_cas_n,
  output logic        sdram_we_n,
  output logic [12:0] sdram_a,
  input  logic [63:0] tb_dq,
  output logic [63:0] dq_seen
);
  axis_if #(.DATA_W(24)) si ();
  axis_if #(.DATA_W(24)) mi ();
  axil_if #(.ADDR_W(8)) bus ();
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
  assign bus.awaddr = axi_awaddr;
  assign bus.awvalid = axi_awvalid;
  assign axi_awready = bus.awready;
  assign bus.wdata = axi_wdata;
  assign bus.wstrb = axi_wstrb;
  assign bus.wvalid = axi_wvalid;
  assign axi_wready = bus.wready;
  assign axi_bresp = bus.bresp;
  assign axi_bvalid = bus.bvalid;
  assign bus.bready = axi_bready;
  assign bus.araddr = axi_araddr;
  assign bus.arvalid = axi_arvalid;
  assign axi_arready = bus.arready;
  assign axi_rdata = bus.rdata;
  assign axi_rresp = bus.rresp;
  assign axi_rvalid = bus.rvalid;
  assign bus.rready = axi_rready;
  wire        sdram_clk, sdram_cke;
  wire [1:0]  sdram_ba;
  wire [7:0]  sdram_dqm;
  wire [63:0] sdram_dq;
  wire        ctrl_writes = !sdram_cs_n && sdram_ras_n && !sdram_cas_n && !sdram_we_n;
  assign sdram_dq = (USE_EXT_FB && !ctrl_writes) ? tb_dq : 64'bz;
  assign dq_seen  = sdram_dq;
  vision_system #(
    .ADDR_W(ADDR_W),
    .FB_DEPTH(FB_DEPTH),
    .USE_EXT_FB(USE_EXT_FB),
    .SDRAM_INIT_WAIT_CYCLES(40)
  ) u_dut (
    .clk,
    .rst_n,
    .s_axis(si),
    .m_axis(mi),
    .s_axil(bus),
    .sdram_clk,
    .sdram_cke,
    .sdram_cs_n,
    .sdram_ras_n,
    .sdram_cas_n,
    .sdram_we_n,
    .sdram_a,
    .sdram_ba,
    .sdram_dqm,
    .sdram_dq
  );
  // not used: the SDRAM pins the responder ignores (bank, mask, clock enable), tkeep
  wire unused_ok = &{1'b0, sdram_clk, sdram_cke, sdram_ba, sdram_dqm, mi.tkeep, 1'b0};
endmodule
