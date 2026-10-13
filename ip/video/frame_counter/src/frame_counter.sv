// ***************
// Filename: frame_counter.sv
// Author: FPGA Cores 4 U
// Description: Frame counters with an event log for a video pipeline.
//   Version: the VERSION register. NCH 32-bit counters, each advanced by a frame marker
//   pulse (eof_i[i], one clock; an end or a start of frame at some point of
//   the pipeline): in video_processor channel 0 counts the frames leaving
//   the first pipeline stage (csi2_raw_unpack) and channel 1 the frames
//   reaching the last stream stage (into axis_to_video). Every marker also
//   sets STATUS[i]; irq_o[i] = STATUS[i] & IRQ_EN[i] (level, until the CPU
//   writes 1 to STATUS[i]), so the CPU can read COUNT[i] at each end of
//   frame. A marker in the same clock as a CLEAR still counts (the counter
//   becomes 1).
//   Event log: every marker of a channel enabled in EV_EN is queued, in the
//   order the markers happened, in an EVQ-entry FIFO with its channel, the
//   channel's count after the marker and a timestamp (TIME, a free-running
//   counter advanced every TS_DIV clocks: TS_DIV = clock MHz gives
//   microseconds). Markers of several channels in one clock are queued
//   lowest channel first (same timestamp). The CPU reads the oldest entry
//   (EVENT, EVENT_TIME) and removes it by writing EVENT_POP; reading has no
//   side effect. A marker that finds the log full is lost and sets
//   EVENT[30] (overflow) until EVENT_POP[1] clears it.
//   The logic of frame_counter: its registers come and go on the cfg_* /
//   sts_* ports. frame_counter_top.sv is the block with its AXI4-Lite
//   register map (src/include/frame_counter_regs.sv: ID "FCNT" / VERSION /
//   DATE at 0x00-0x08, IRQ_EN 0x18, STATUS 0x1C, CLEAR 0x20, EVENT 0x24,
//   EVENT_TIME 0x28, EVENT_POP 0x2C, COUNT[i] 0x30 + 4 i, TIME 0x50, EV_EN
//   0x54).
//   Clock - clk (the pipeline pixel clock). Reset - synchronous active low
//   rst_n.
// Date: 2026-10-11
module frame_counter #(
  parameter int NCH    = 2,                      // counters (1..8)
  parameter int EVQ    = 64,                     // event log entries (power of two >= 2)
  parameter int TS_DIV = 1                       // clocks per timestamp tick (>= 1)
) (
  input  logic           clk,
  input  logic           rst_n,
  input  logic [NCH-1:0] eof_i,                  // frame marker pulses
  output logic [NCH-1:0] irq_o,                  // per channel: marker seen, enabled, not yet cleared
  // register map (frame_counter_regs, joined in frame_counter_top)
  input  logic [NCH-1:0]   cfg_irq_en,           // IRQ_EN
  input  logic [NCH-1:0]   cfg_status,           // STATUS (marker seen, cleared by software)
  output logic [NCH-1:0]   sts_status_set,       // STATUS set: the markers
  input  logic [NCH-1:0]   cfg_clear,            // CLEAR data ...
  input  logic             cfg_clear_wr,         // ... and its write pulse
  output logic [31:0]      sts_event,            // EVENT
  output logic [31:0]      sts_event_time,       // EVENT_TIME
  input  logic [1:0]       cfg_event_pop,        // EVENT_POP data ...
  input  logic             cfg_event_pop_wr,     // ... and its write pulse
  output logic [NCH*32-1:0] sts_count,           // COUNT[i]
  output logic [31:0]      sts_time,             // TIME
  input  logic [NCH-1:0]   cfg_ev_en             // EV_EN
);
  if (NCH < 1 || NCH > 8) begin : g_bad_nch $error("frame_counter: NCH must be 1..8"); end
  if (EVQ < 2 || (EVQ & (EVQ - 1)) != 0) begin : g_bad_evq $error("frame_counter: EVQ must be a power of two >= 2"); end
  if (TS_DIV < 1) begin : g_bad_ts $error("frame_counter: TS_DIV must be >= 1"); end

  // ---------------- register ports
  wire [NCH-1:0] irq_en = cfg_irq_en, ev_en = cfg_ev_en, status = cfg_status, clear_mask = cfg_clear;
  wire clear = cfg_clear_wr, pop_wr = cfg_event_pop_wr;
  wire [1:0] pop_data = cfg_event_pop;
  logic [31:0] ev_word, ev_time, ts;
  logic [NCH*32-1:0] count_flat;
  assign sts_status_set = eof_i;                 // a marker sets STATUS (and wins over a clear)
  assign sts_event = ev_word;
  assign sts_event_time = ev_time;
  assign sts_count = count_flat;
  assign sts_time = ts;
  localparam int QW = $clog2(EVQ);
  logic [31:0] count [NCH];
  logic [31:0] n_count [NCH];                    // counts after this clock
  always_comb for (int i = 0; i < NCH; i++) count_flat[i*32 +: 32] = count[i];

  // ---------------- timestamp
  logic [$clog2(TS_DIV+1)-1:0] div;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ts <= '0;
      div <= '0;
    end else if (div == $bits(div)'(TS_DIV - 1)) begin
      div <= '0;
      ts <= ts + 32'd1;
    end else div <= div + 1'b1;
  end

  // ---------------- counters and STATUS
  always_comb
    for (int i = 0; i < NCH; i++) begin
      if (clear && clear_mask[i]) n_count[i] = eof_i[i] ? 32'd1 : 32'd0;
      else if (eof_i[i])                  n_count[i] = count[i] + 32'd1;
      else                                n_count[i] = count[i];
    end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < NCH; i++) count[i] <= '0;
    end else begin
      for (int i = 0; i < NCH; i++) count[i] <= n_count[i];
    end
  end
  assign irq_o = status & irq_en;

  // ---------------- event log: per-channel pending event, then the FIFO in marker order
  logic [NCH-1:0] pend;
  logic [23:0] pend_cnt [NCH];
  logic [31:0] pend_ts [NCH];
  logic [58:0] q [EVQ];                          // {channel[2:0], count[23:0], time[31:0]}
  logic [QW:0] wp, rp;
  logic ovf;
  wire  full = (wp - rp) == (QW+1)'(EVQ);
  wire  empty = wp == rp;
  // pending event to queue this clock: the oldest (lowest channel among equal timestamps), so the log
  // keeps the marker order even when markers of several channels came in one clock
  logic push;
  logic [2:0] pch;
  always_comb begin
    push = 1'b0;
    pch = '0;
    for (int i = 0; i < NCH; i++)
      if (pend[i] && (!push || pend_ts[i] < pend_ts[pch])) begin
        push = 1'b1;
        pch = 3'(i);
      end
  end
  wire pop = pop_wr && pop_data[0] && !empty;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pend <= '0;
      wp <= '0;
      rp <= '0;
      ovf <= 1'b0;
      for (int i = 0; i < NCH; i++) begin
        pend_cnt[i] <= '0;
        pend_ts[i] <= '0;
      end
    end else begin
      if (pop) rp <= rp + 1'b1;
      if (pop_wr && pop_data[1]) ovf <= 1'b0;
      if (push) begin
        if (!full || pop) begin
          q[wp[QW-1:0]] <= {pch, pend_cnt[pch], pend_ts[pch]};
          wp <= wp + 1'b1;
        end else ovf <= 1'b1;                    // log full: the event is lost
      end
      for (int i = 0; i < NCH; i++) begin
        if (eof_i[i] && ev_en[i]) begin
          if (pend[i] && !(push && pch == 3'(i))) ovf <= 1'b1;   // previous one not yet queued
          pend[i] <= 1'b1;
          pend_cnt[i] <= n_count[i][23:0];
          pend_ts[i] <= ts;
        end else if (push && pch == 3'(i)) pend[i] <= 1'b0;
      end
    end
  end
  wire [58:0] head = q[rp[QW-1:0]];

  assign ev_word = empty ? {1'b0, ovf, 30'd0} : {1'b1, ovf, 3'd0, head[58:56], head[55:32]};
  assign ev_time = empty ? 32'd0 : head[31:0];
endmodule
