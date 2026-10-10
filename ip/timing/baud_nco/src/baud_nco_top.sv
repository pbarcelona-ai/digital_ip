// ***************
// Filename: baud_nco_top.sv
// Author: FPGA Cores 4 U
// Description: Baud rate generator and NCO IP. Phase accumulator NCO gives
//   a baud tick strobe, square wave and, on an AXI-Stream master, 16 bit
//   sine and cosine samples (tdata = {cos, sin}). AXI-Lite map - 0x00
//   CTRL[0]=en [1]=stream_en [2]=phase reset pulse, 0x04 FCW, 0x08
//   PHASE_OFF[15:0], 0x0C GAIN[14:0], 0x10 STATUS, 0x14 TICK_COUNT (write
//   clears). f_out = f_clk * FCW / 2^PHASE_W. Default FCW is computed for
//   BAUD*OSR at CLK_HZ. Version 1.0.0. Clock - single clock aclk, every
//   input is synchronous to it unless a two-flop synchronizer is
//   mentioned. Reset - synchronous active low aresetn, registers take the
//   documented reset values. Latency - AXI-Lite write response and read
//   data follow the request by about 2 to 3 clocks (ip_axil_regs,
//   registered read path). Timing - registered outputs, no combinational
//   path from the bus to the pins. Errors - out of range AXI-Lite accesses
//   return SLVERR; illegal parameter values stop elaboration with an
//   $error.
// Date: 2026-09-29
module baud_nco_top #(
  parameter int PHASE_W = 32,
  parameter int CLK_HZ  = 100_000_000,   // clock frequency for default FCW
  parameter int BAUD    = 115_200,       // default baud rate
  parameter int OSR     = 16             // default oversampling ratio
) (
  input  logic        aclk,
  input  logic        aresetn,
  // AXI4-Lite slave
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
  // AXI4-Stream master: {cos[15:0], sin[15:0]}
  output logic [31:0] m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast,
  // Direct outputs
  output logic        baud_tick_o,
  output logic        sq_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (PHASE_W < 16 || PHASE_W > 32) begin : g_chk_pw $error("%m: PHASE_W must be 16..32"); end
  if (CLK_HZ < 1 || BAUD < 1 || OSR < 1) begin : g_chk_pos $error("%m: CLK_HZ, BAUD and OSR must be positive"); end
  if (BAUD * OSR > CLK_HZ / 2) begin : g_chk_rate $error("%m: BAUD*OSR must not exceed CLK_HZ/2"); end

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

  // Default FCW = round(BAUD * OSR * 2^PHASE_W / CLK_HZ), 64 bit math
  localparam logic [63:0] FCW64 = ((64'(BAUD) * 64'(OSR) << PHASE_W) + (64'(CLK_HZ) >> 1)) / 64'(CLK_HZ);
  localparam logic [31:0] FCW_DEF = FCW64[31:0];
  // Reset values: reg0 CTRL=en, reg1 FCW, reg2 offset, reg3 gain, reg4/5 rsvd
  localparam logic [6*32-1:0] RSTV = {32'd0, 32'd0, 32'd32767, 32'd0, FCW_DEF, 32'd1};

  logic [6*32-1:0] regs, rd;
  logic [5:0]      wr_pulse;
  logic [31:0]     wr_data;

  ip_axil_regs #(
    .ADDR_W(8),
    .NREG(6),
    .RESET_VALS(RSTV)
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

  wire        en        = regs[0];
  wire        stream_en = regs[1];
  wire        phase_rst = wr_pulse[0] & wr_data[2];     // self clearing bit
  wire [PHASE_W-1:0] fcw = regs[32 +: PHASE_W];

  // Stall the whole NCO when the stream output is blocked
  logic               core_valid;
  logic signed [15:0] sin_s, cos_s;
  wire  out_stall = stream_en & core_valid & ~m_axis_tready;
  wire  adv       = ~out_stall;

  nco_core #(.PHASE_W(PHASE_W)) u_core (
    .clk(aclk),
    .rst_n(aresetn),
    .en(en),
    .adv(adv),
    .phase_rst(phase_rst),
    .fcw(fcw),
    .phase_off(regs[64 +: 16]),
    .gain(regs[96 +: 15]),
    .tick_o(baud_tick_o),
    .sq_o(sq_o),
    .valid_o(core_valid),
    .sin_o(sin_s),
    .cos_o(cos_s)
  );

  // A transfer that completes while the core is disabled must still pop
  assign m_axis_tvalid = stream_en & core_valid;
  assign m_axis_tdata  = {cos_s, sin_s};
  assign m_axis_tlast  = 1'b0;

  // Tick counter (write to the register clears it)
  logic [31:0] tick_cnt;
  always_ff @(posedge aclk) begin
    if (!aresetn)            tick_cnt <= '0;
    else if (wr_pulse[5])    tick_cnt <= '0;
    else if (baud_tick_o)    tick_cnt <= tick_cnt + 32'd1;
  end

  assign rd = {tick_cnt, {30'd0, m_axis_tvalid, en}, regs[127:32], regs[31:0] & 32'hFFFF_FFFB};
endmodule
