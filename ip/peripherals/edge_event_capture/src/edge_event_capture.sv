// ***************
// Filename: edge_event_capture.sv
// Author: FPGA Cores 4 U
// Description: Multi-channel edge detector IP. Each of WIDTH inputs goes
//   through a synchronizer chain, an optional debounce filter (input must be
//   stable for DEBOUNCE clocks), and rise/fall detection with enable masks.
//   Events set write-1-to-clear pending flags, increment an event counter,
//   drive direct pulse outputs and are timestamped into an AXI-Stream event
//   record {timestamp, fall flags, rise flags} through a FIFO (drop counter
//   on overflow). Registers on the cfg_* / sts_* ports;
//   edge_event_capture_top.sv is the block with its AXI4-Lite register map
//   (src/include/edge_event_capture_regs.sv: ID "EDGE" / VERSION / DATE at
//   0x00-0x08, 0x10 CTRL [0]en, 0x14 RISE_EN, 0x18 FALL_EN, 0x1C DEBOUNCE
//   clocks, 0x20 RISE_PEND (W1C), 0x24 FALL_PEND (W1C), 0x28 EVENT_COUNT,
//   0x2C TIMESTAMP, 0x30 DROP_COUNT, 0x34 IRQ_EN).
//   Clock - single clock aclk, every input is synchronous to it unless a
//   two-flop synchronizer is mentioned. Reset - synchronous active low
//   aresetn, registers take the documented reset values. Latency - AXI-Lite
//   write response and read data follow the request by about 2 to 3 clocks
//   (ip_axil_regs, registered read path). Timing - registered outputs, no
//   combinational path from the bus to the pins. Errors - out of range
//   AXI-Lite accesses return SLVERR; illegal parameter values stop
//   elaboration with an $error.
// Date: 2026-10-12
module edge_event_capture #(
  parameter int WIDTH      = 8,
  parameter int SYNC_STAGES = 2,
  parameter int FIFO_DEPTH = 512,
  parameter int TS_W       = 32
) (

  input  logic        aclk,
  input  logic        aresetn,
  input  logic [WIDTH-1:0]         sig_i,
  output logic [WIDTH-1:0]         rise_o,      // one clock pulses
  output logic [WIDTH-1:0]         fall_o,
  output logic                     irq_o,
  // Event record stream: {timestamp, fall flags, rise flags}
  output logic [TS_W+2*WIDTH-1:0]  m_axis_tdata,
  output logic                     m_axis_tvalid,
  input  logic                     m_axis_tready,
  output logic                     m_axis_tlast,
  // register ports
  input  logic                     cfg_ctrl,            // CTRL
  input  logic [WIDTH-1:0]         cfg_rise_en,         // RISE_EN
  input  logic [WIDTH-1:0]         cfg_fall_en,         // FALL_EN
  input  logic [15:0]              cfg_debounce,        // DEBOUNCE
  input  logic [WIDTH-1:0]         cfg_rise_pend,       // RISE_PEND
  output logic [WIDTH-1:0]         sts_rise_pend_set,   // RISE_PEND: edges seen this clock
  input  logic [WIDTH-1:0]         cfg_fall_pend,       // FALL_PEND
  output logic [WIDTH-1:0]         sts_fall_pend_set,   // FALL_PEND: edges seen this clock
  output logic [31:0]              sts_event_count,     // EVENT_COUNT
  output logic [31:0]              sts_timestamp,       // TIMESTAMP
  output logic [31:0]              sts_drop_count,      // DROP_COUNT
  input  logic [WIDTH-1:0]         cfg_irq_en           // IRQ_EN
);
  if (WIDTH < 1 || WIDTH > 32) begin : g_chk_w $error("%m: WIDTH must be 1..32"); end
  if (SYNC_STAGES < 2) begin : g_chk_ss $error("%m: SYNC_STAGES must be >= 2"); end
  if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0) begin : g_chk_fd $error("%m: FIFO_DEPTH must be a power of two >= 2"); end
  if (TS_W < 8 || TS_W > 32) begin : g_chk_ts $error("%m: TS_W must be 8..32"); end

  localparam int DW = TS_W + 2*WIDTH;
  localparam int LW = $clog2(FIFO_DEPTH) + 2;
  wire en = cfg_ctrl;
  wire [WIDTH-1:0] rise_en = cfg_rise_en, fall_en = cfg_fall_en;
  wire [15:0] deb = cfg_debounce;

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
  wire  [WIDTH-1:0] rise_pend = cfg_rise_pend, fall_pend = cfg_fall_pend;
  logic [31:0] evt_cnt, drop_cnt;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      ts <= '0;
      evt_cnt <= '0;
      drop_cnt <= '0;
      rise_o <= '0;
      fall_o <= '0;
    end else begin
      ts <= ts + 1'b1;
      rise_o <= rise;
      fall_o <= fall;
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

  assign irq_o = |((rise_pend | fall_pend) & cfg_irq_en);
  assign sts_rise_pend_set = rise;   // a new edge wins over a clear in the same clock
  assign sts_fall_pend_set = fall;
  assign sts_event_count = evt_cnt;
  assign sts_timestamp = 32'(ts);
  assign sts_drop_count = drop_cnt;
endmodule
