// ***************
// Filename: baud_nco.sv
// Author: FPGA Cores 4 U
// Description: Baud rate generator and NCO IP. Phase accumulator NCO gives
//   a baud tick strobe, square wave and, on an AXI-Stream master, 16 bit
//   sine and cosine samples (tdata = {cos, sin}). Registers on the
//   cfg_* / sts_* ports; baud_nco_top.sv is the block with its AXI4-Lite
//   register map (src/include/baud_nco_regs.sv: ID "BNCO" / VERSION / DATE
//   at 0x00-0x08, 0x10 CTRL[0]=en [1]=stream_en [2]=phase reset pulse,
//   0x14 FCW, 0x18 PHASE_OFF[15:0], 0x1C GAIN[14:0], 0x20 STATUS, 0x24
//   TICK_COUNT (write clears)). f_out = f_clk * FCW / 2^PHASE_W. Default FCW is computed for
//   BAUD*OSR at CLK_HZ. Clock - single clock aclk, every
//   input is synchronous to it unless a two-flop synchronizer is
//   mentioned. Reset - synchronous active low aresetn, registers take the
//   documented reset values. Latency - AXI-Lite write response and read
//   data follow the request by about 2 to 3 clocks (ip_axil_regs,
//   registered read path). Timing - registered outputs, no combinational
//   path from the bus to the pins. Errors - out of range AXI-Lite accesses
//   return SLVERR; illegal parameter values stop elaboration with an
//   $error.
// Date: 2026-10-12
module baud_nco #(
  parameter int PHASE_W = 32,
  parameter int CLK_HZ  = 100_000_000,   // clock frequency for default FCW
  parameter int BAUD    = 115_200,       // default baud rate
  parameter int OSR     = 16             // default oversampling ratio
) (

  input  logic        aclk,
  input  logic        aresetn,
  // AXI4-Stream master: {cos[15:0], sin[15:0]}
  output logic [31:0] m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast,
  // Direct outputs
  output logic        baud_tick_o,
  output logic        sq_o,
  // register ports
  input  logic [2:0]  cfg_ctrl,          // CTRL: data written ...
  input  logic        cfg_ctrl_wr,       // ... and its write pulse
  output logic [2:0]  sts_ctrl,          // CTRL: value read
  input  logic [31:0] cfg_fcw,           // FCW
  input  logic [15:0] cfg_phase_off,     // PHASE_OFF
  input  logic [14:0] cfg_gain,          // GAIN
  output logic [1:0]  sts_status,        // STATUS
  input  logic        cfg_tick_count_wr, // TICK_COUNT write pulse: clear
  output logic [31:0] sts_tick_count     // TICK_COUNT
);
  if (PHASE_W < 16 || PHASE_W > 32) begin : g_chk_pw $error("%m: PHASE_W must be 16..32"); end
  if (CLK_HZ < 1 || BAUD < 1 || OSR < 1) begin : g_chk_pos $error("%m: CLK_HZ, BAUD and OSR must be positive"); end
  if (BAUD * OSR > CLK_HZ / 2) begin : g_chk_rate $error("%m: BAUD*OSR must not exceed CLK_HZ/2"); end

  // CTRL: EN (reset 1) and STREAM_EN stored here, PHASE_RST a self-clearing pulse
  logic en, stream_en;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      en <= 1'b1;
      stream_en <= 1'b0;
    end else if (cfg_ctrl_wr) begin
      en <= cfg_ctrl[0];
      stream_en <= cfg_ctrl[1];
    end
  end
  wire        phase_rst = cfg_ctrl_wr & cfg_ctrl[2];
  wire [PHASE_W-1:0] fcw = cfg_fcw[PHASE_W-1:0];

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
    .phase_off(cfg_phase_off),
    .gain(cfg_gain),
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
    else if (cfg_tick_count_wr) tick_cnt <= '0;
    else if (baud_tick_o)    tick_cnt <= tick_cnt + 32'd1;
  end

  assign sts_ctrl = {1'b0, stream_en, en};
  assign sts_status = {m_axis_tvalid, en};
  assign sts_tick_count = tick_cnt;
endmodule
