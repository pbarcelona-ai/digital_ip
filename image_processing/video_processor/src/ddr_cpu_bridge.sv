// ***************
// Filename: ddr_cpu_bridge.sv
// Author: FPGA Cores 4 U
// Description: The CPU's DDR window (py_soc m_ddr_axil, 64 MB at
//   0x1000_0000, after axi4_lite_cdc on pix_clk) onto a DDR controller port:
//   every AXI4-Lite access becomes one single-beat full-width AXI4 transfer
//   at DDR byte address = the window offset (the system model's mapping).
//   A write takes its address and data (either order), writes the 32-bit word
//   in its lane of the 256-bit beat (strobes shifted to it; the other bytes
//   untouched), answers with the B response; a read returns the word's lane
//   of the beat with the R response. One access at a time, a write before a
//   read presented with it; the AXI4 ports never wait for a ready before
//   their valid. Version 1.0.1.
//   Parameters: ADDR_W (the window's offset bits, 26; 6-31), ID_W, ID.
//   Clock - clk (pix_clk, the controller's). Reset - synchronous active low
//   rst_n (the controller's). Clock-domain crossings - none (the CPU side
//   crosses in axi4_lite_cdc).
// Date: 2026-10-26
module ddr_cpu_bridge #(
  parameter int ADDR_W = 26,                     // window offset bits
  parameter int ID_W   = 4,                      // AXI ID bits
  parameter int ID     = 2                       // AWID / ARID
) (
  input  logic                clk,               // clock
  input  logic                rst_n,             // synchronous, active low
  // s_axil: axil_if.slave (ip/shared/src/interfaces/axil_if.sv), ADDR_W = ADDR_W
  axil_if.slave               s_axil,
  // AXI4 master (a ddr_ctrl port)
  output logic [ID_W-1:0]     m_axi_awid,        // write address channel
  output logic [31:0]         m_axi_awaddr,
  output logic [7:0]          m_axi_awlen,
  output logic [2:0]          m_axi_awsize,
  output logic [1:0]          m_axi_awburst,
  output logic                m_axi_awvalid,
  input  logic                m_axi_awready,
  output logic [255:0]        m_axi_wdata,       // write data channel
  output logic [31:0]         m_axi_wstrb,
  output logic                m_axi_wlast,
  output logic                m_axi_wvalid,
  input  logic                m_axi_wready,
  input  logic [ID_W-1:0]     m_axi_bid,         // write response channel
  input  logic [1:0]          m_axi_bresp,
  input  logic                m_axi_bvalid,
  output logic                m_axi_bready,
  output logic [ID_W-1:0]     m_axi_arid,        // read address channel
  output logic [31:0]         m_axi_araddr,
  output logic [7:0]          m_axi_arlen,
  output logic [2:0]          m_axi_arsize,
  output logic [1:0]          m_axi_arburst,
  output logic                m_axi_arvalid,
  input  logic                m_axi_arready,
  input  logic [ID_W-1:0]     m_axi_rid,         // read data channel
  input  logic [255:0]        m_axi_rdata,
  input  logic [1:0]          m_axi_rresp,
  input  logic                m_axi_rlast,
  input  logic                m_axi_rvalid,
  output logic                m_axi_rready
);
  if (ADDR_W < 6 || ADDR_W > 31 || ID_W < 1) begin : g_bad
    $error("ddr_cpu_bridge: ADDR_W 6-31 (a 32-byte beat, a 32-bit address), ID_W >= 1");
  end
  typedef enum logic [2:0] {S_IDLE, S_WR, S_WB, S_WRESP, S_RD, S_RR, S_RRESP} state_e;
  state_e st;
  logic          aw_got, w_got, aw_v, w_v, ar_v;
  logic [ADDR_W-1:0] addr;
  logic [31:0]   data;
  logic [3:0]    strb;
  logic [1:0]    resp;
  logic [31:0]   rword;

  // the lite side: AW / W taken while idle (in any order); AR only when no write is under way or presented
  // (a write first: AR never handshakes with AW or W, so neither the address nor a read is lost)
  assign s_axil.awready = st == S_IDLE && !aw_got;
  assign s_axil.wready = st == S_IDLE && !w_got;
  assign s_axil.arready = st == S_IDLE && !aw_got && !w_got && !s_axil.awvalid && !s_axil.wvalid;
  assign s_axil.bvalid = st == S_WRESP;
  assign s_axil.bresp = resp;
  assign s_axil.rvalid = st == S_RRESP;
  assign s_axil.rresp = resp;
  assign s_axil.rdata = rword;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= S_IDLE;
      aw_got <= 1'b0;
      w_got <= 1'b0;
      aw_v <= 1'b0;
      w_v <= 1'b0;
      ar_v <= 1'b0;
      addr <= '0;
      data <= '0;
      strb <= '0;
      resp <= '0;
      rword <= '0;
    end else begin
      unique case (st)
        S_IDLE: begin
          if (s_axil.awvalid && s_axil.awready) begin
            aw_got <= 1'b1;
            addr <= ADDR_W'(s_axil.awaddr);
          end
          if (s_axil.wvalid && s_axil.wready) begin
            w_got <= 1'b1;
            data <= s_axil.wdata;
            strb <= s_axil.wstrb;
          end
          if ((aw_got || (s_axil.awvalid && s_axil.awready)) && (w_got || (s_axil.wvalid && s_axil.wready))) begin
            aw_v <= 1'b1;
            w_v <= 1'b1;
            st <= S_WR;
          end else if (s_axil.arvalid && s_axil.arready) begin
            addr <= ADDR_W'(s_axil.araddr);
            ar_v <= 1'b1;
            st <= S_RD;
          end
        end
        S_WR: begin                              // AW and W presented together, each held to its handshake
          if (aw_v && m_axi_awready) aw_v <= 1'b0;
          if (w_v && m_axi_wready) w_v <= 1'b0;
          if ((!aw_v || m_axi_awready) && (!w_v || m_axi_wready)) st <= S_WB;
        end
        S_WB: if (m_axi_bvalid) begin
          resp <= m_axi_bresp;
          st <= S_WRESP;
        end
        S_WRESP: if (s_axil.bready) begin
          aw_got <= 1'b0;
          w_got <= 1'b0;
          st <= S_IDLE;
        end
        S_RD: if (m_axi_arready) begin
          ar_v <= 1'b0;
          st <= S_RR;
        end
        S_RR: if (m_axi_rvalid) begin
          rword <= m_axi_rdata[32*addr[4:2] +: 32];
          resp <= m_axi_rresp;
          st <= S_RRESP;
        end
        S_RRESP: if (s_axil.rready) st <= S_IDLE;
        default: st <= S_IDLE;
      endcase
    end
  end
  wire [31:0] beat_addr = {{(32 - ADDR_W){1'b0}}, addr[ADDR_W-1:5], 5'd0};
  assign m_axi_awid = ID_W'(ID);
  assign m_axi_awaddr = beat_addr;
  assign m_axi_awlen = 8'd0;
  assign m_axi_awsize = 3'd5;
  assign m_axi_awburst = 2'b01;
  assign m_axi_awvalid = aw_v;
  assign m_axi_wdata = {8{data}};
  assign m_axi_wstrb = 32'(strb) << (4 * addr[4:2]);
  assign m_axi_wlast = 1'b1;
  assign m_axi_wvalid = w_v;
  assign m_axi_bready = st == S_WB;
  assign m_axi_arid = ID_W'(ID);
  assign m_axi_araddr = beat_addr;
  assign m_axi_arlen = 8'd0;
  assign m_axi_arsize = 3'd5;
  assign m_axi_arburst = 2'b01;
  assign m_axi_arvalid = ar_v;
  assign m_axi_rready = st == S_RR;
  // not used: the IDs back (one access at a time), RLAST (single beats), the byte offset in the word
  wire unused_ok = &{1'b0, m_axi_bid, m_axi_rid, m_axi_rlast, addr[1:0], 1'b0};
endmodule
