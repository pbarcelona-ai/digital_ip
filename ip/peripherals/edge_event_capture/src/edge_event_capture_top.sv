// ***************
// Filename: edge_event_capture_top.sv
// Author: FPGA Cores 4 U
// Description: Multi-channel edge detector IP. Each of WIDTH inputs goes
//   through a synchronizer chain, an optional debounce filter (input must be
//   stable for DEBOUNCE clocks), and rise/fall detection with enable masks.
//   Events set write-1-to-clear pending flags, increment an event counter,
//   drive direct pulse outputs and are timestamped into an AXI-Stream event
//   record {timestamp, fall flags, rise flags} through a FIFO (drop counter
//   on overflow). Map - 0x00 CTRL [0]en, 0x04 RISE_EN, 0x08 FALL_EN, 0x0C
//   DEBOUNCE clocks, 0x10 RISE_PEND (W1C), 0x14 FALL_PEND (W1C), 0x18
//   EVENT_COUNT, 0x1C TIMESTAMP, 0x20 DROP_COUNT, 0x24 IRQ_EN. Version 1.0.0.
//   Clock - single clock aclk, every input is synchronous to it unless a
//   two-flop synchronizer is mentioned. Reset - synchronous active low
//   aresetn, registers take the documented reset values. Latency - AXI-Lite
//   write response and read data follow the request by about 2 to 3 clocks
//   (ip_axil_regs, registered read path). Timing - registered outputs, no
//   combinational path from the bus to the pins. Errors - out of range
//   AXI-Lite accesses return SLVERR; illegal parameter values stop
//   elaboration with an $error.
// Date: 2026-09-29
module edge_event_capture_top #(
  parameter int WIDTH      = 8,
  parameter int SYNC_STAGES = 2,
  parameter int FIFO_DEPTH = 512,
  parameter int TS_W       = 32
) (
  input  logic        aclk,
  input  logic        aresetn,
  // AXI4-Lite slave (register access)
  input  logic [7:0]  s_axil_awaddr,
  input  logic        s_axil_awvalid,
  output logic        s_axil_awready,
  input  logic [31:0] s_axil_wdata,
  input  logic [3:0]  s_axil_wstrb,
  input  logic        s_axil_wvalid,
  output logic        s_axil_wready,
  output logic [1:0]  s_axil_bresp,
  output logic        s_axil_bvalid,
  input  logic        s_axil_bready,
  input  logic [7:0]  s_axil_araddr,
  input  logic        s_axil_arvalid,
  output logic        s_axil_arready,
  output logic [31:0] s_axil_rdata,
  output logic [1:0]  s_axil_rresp,
  output logic        s_axil_rvalid,
  input  logic        s_axil_rready,
  input  logic [WIDTH-1:0]         sig_i,
  output logic [WIDTH-1:0]         rise_o,      // one clock pulses
  output logic [WIDTH-1:0]         fall_o,
  output logic                     irq_o,
  // Event record stream: {timestamp, fall flags, rise flags}
  output logic [TS_W+2*WIDTH-1:0]  m_axis_tdata,
  output logic                     m_axis_tvalid,
  input  logic                     m_axis_tready,
  output logic                     m_axis_tlast
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (WIDTH < 1 || WIDTH > 32) begin : g_chk_w $error("%m: WIDTH must be 1..32"); end
  if (SYNC_STAGES < 2) begin : g_chk_ss $error("%m: SYNC_STAGES must be >= 2"); end
  if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0) begin : g_chk_fd $error("%m: FIFO_DEPTH must be a power of two >= 2"); end
  if (TS_W < 8 || TS_W > 32) begin : g_chk_ts $error("%m: TS_W must be 8..32"); end

`ifndef SYNTHESIS
  // verification-only checks: excluded from code coverage
  // verilator coverage_off
  // ---- immediate assertions (simulation only; skipped by synthesis) ----
  logic ip_chk_b_q, ip_chk_r_q;
  always @(posedge aclk) begin
    if (aresetn) begin
      ip_chk_b_q <= s_axil_bvalid & ~s_axil_bready;
      ip_chk_r_q <= s_axil_rvalid & ~s_axil_rready;
      assert (s_axil_bresp == 2'b00 || s_axil_bresp == 2'b10) else $error("%m: reserved BRESP value");
      assert (s_axil_rresp == 2'b00 || s_axil_rresp == 2'b10) else $error("%m: reserved RRESP value");
      if (ip_chk_b_q) assert (s_axil_bvalid) else $error("%m: BVALID dropped before BREADY");
      if (ip_chk_r_q) assert (s_axil_rvalid) else $error("%m: RVALID dropped before RREADY");
    end else begin
      ip_chk_b_q <= 1'b0;
      ip_chk_r_q <= 1'b0;
    end
  end
  // verilator coverage_on
`endif

  localparam int DW = TS_W + 2*WIDTH;
  localparam int LW = $clog2(FIFO_DEPTH) + 2;
  logic [10*32-1:0] regs, rd;
  logic [9:0] wr_pulse;
  logic [31:0] wr_data;
  ip_axil_regs #(
    .ADDR_W(8),
    .NREG(10),
    .RESET_VALS({32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd0, 32'd1})
  ) u_regs (
    .aclk,
    .aresetn,
    .s_axil_awaddr,
    .s_axil_awvalid,
    .s_axil_awready,
    .s_axil_wdata,
    .s_axil_wstrb,
    .s_axil_wvalid,
    .s_axil_wready,
    .s_axil_bresp,
    .s_axil_bvalid,
    .s_axil_bready,
    .s_axil_araddr,
    .s_axil_arvalid,
    .s_axil_arready,
    .s_axil_rdata,
    .s_axil_rresp,
    .s_axil_rvalid,
    .s_axil_rready,
    .reg_o(regs),
    .wr_pulse_o(wr_pulse),
    .wr_data_o(wr_data),
    .rd_i(rd)
  );

  wire en = regs[0];
  wire [WIDTH-1:0] rise_en = regs[32 +: WIDTH], fall_en = regs[64 +: WIDTH];
  wire [15:0] deb = regs[96 +: 16];

  // Synchronizer chain
  (* async_reg = "true" *) logic [SYNC_STAGES*WIDTH-1:0] sync_q;
  logic [WIDTH-1:0] s_out;
  always_ff @(posedge aclk) sync_q <= {sync_q[(SYNC_STAGES-1)*WIDTH-1:0], sig_i};
  assign s_out = sync_q[SYNC_STAGES*WIDTH-1 -: WIDTH];

  // Debounce: filtered value follows the input after it is stable for deb clocks
  logic [WIDTH-1:0] filt, prev;
  logic [WIDTH*16-1:0] dcnt;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      filt <= '0;
      prev <= '0;
      dcnt <= '0;
    end
    else begin
      prev <= filt;
      for (int i = 0; i < WIDTH; i++) begin
        if (s_out[i] == filt[i]) dcnt[i*16 +: 16] <= '0;
        else if (deb == 16'd0 || dcnt[i*16 +: 16] >= deb - 16'd1) begin
          filt[i] <= s_out[i];
          dcnt[i*16 +: 16] <= '0;
        end else dcnt[i*16 +: 16] <= dcnt[i*16 +: 16] + 16'd1;
      end
    end
  end

  // Edge detect and event generation
  wire [WIDTH-1:0] rise = en ? (filt & ~prev & rise_en) : '0;
  wire [WIDTH-1:0] fall = en ? (~filt & prev & fall_en) : '0;
  logic [TS_W-1:0] ts;
  logic ev_ready, ev_valid;
  logic [WIDTH-1:0] rise_pend, fall_pend;
  logic [31:0] evt_cnt, drop_cnt;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      ts <= '0;
      rise_pend <= '0;
      fall_pend <= '0;
      evt_cnt <= '0;
      drop_cnt <= '0;
      rise_o <= '0;
      fall_o <= '0;
    end else begin
      ts <= ts + 1'b1;
      rise_o <= rise;
      fall_o <= fall;
      rise_pend <= (rise_pend & ~(wr_pulse[4] ? wr_data[WIDTH-1:0] : '0)) | rise;
      fall_pend <= (fall_pend & ~(wr_pulse[5] ? wr_data[WIDTH-1:0] : '0)) | fall;
      if (|(rise | fall)) evt_cnt <= evt_cnt + 32'd1;
      if (|(rise | fall) && !ev_ready) drop_cnt <= drop_cnt + 32'd1;
    end
  end

  // Event record FIFO. Record is formed one clock after the edge.
  logic [DW-1:0] ev_data;
  logic [LW-1:0] lvl;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      ev_valid <= 1'b0;
      ev_data <= '0;
    end
    else begin
      ev_valid <= |(rise | fall);
      ev_data  <= {ts, fall, rise};
    end
  end
  logic fu, fl;
  ip_axis_fifo #(
    .DATA_W(DW),
    .DEPTH(FIFO_DEPTH)
  ) u_fifo (
    .clk(aclk),
    .rst_n(aresetn),
    .s_tdata(ev_data),
    .s_tlast(1'b1),
    .s_tuser(1'b0),
    .s_tvalid(ev_valid),
    .s_tready(ev_ready),
    .m_tdata(m_axis_tdata),
    .m_tlast(m_axis_tlast),
    .m_tuser(fu),
    .m_tvalid(m_axis_tvalid),
    .m_tready(m_axis_tready),
    .level_o(lvl)
  );

  assign irq_o = |((rise_pend | fall_pend) & regs[9*32 +: WIDTH]);
  assign rd = {regs[9*32 +: 32], drop_cnt, 32'(ts), evt_cnt, 32'(fall_pend), 32'(rise_pend),
               regs[3*32 +: 32], regs[2*32 +: 32], regs[1*32 +: 32], regs[31:0]};
endmodule
