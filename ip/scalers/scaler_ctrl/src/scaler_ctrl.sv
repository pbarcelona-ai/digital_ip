// ***************
// Filename: scaler_ctrl.sv
// Author: FPGA Cores 4 U
// Description: Common control block for all scaler IPs.
//   * AXI4-Lite slave (axil_regbus) implementing the common registers
//   * forwards addresses >= 0x040 to the IP-specific ext_* bus
//   * captures AXI4-Stream frames (tuser = SOF, tlast = EOL) into the
//     frame store, dropping data before SOF and flagging errors
//   * frame sequencing in one of three buffering modes:
//       NBUF = 1, LB_ROWS = 0  frame buffer: capture a frame, then generate
//                              it; input is stalled while generating
//       NBUF = 2, LB_ROWS = 0  double buffer (ping-pong): the next frame is
//                              captured into the other buffer while the
//                              current one is generated; input only stalls
//                              if both buffers are busy
//       LB_ROWS > 0            line buffer: the frame store is a ring of
//                              LB_ROWS lines; generation starts at SOF and
//                              runs concurrently with capture, with row-level
//                              flow control in both directions (latency of a
//                              few lines). STEP_Y must be >= 0.
//     Line-buffer flow control: the IP reports the source y coordinate of the
//     next pixel its DDA will emit (lb_nxt_*) and of the pixels already
//     emitted but whose rows are not yet read (lb_o_*, lb_a_*). From these the
//     block derives
//       need(y) = clamp(((y + LB_RND) >>> 16) - LB_CTR + LB_TAPS - 1, 0, H-1)
//       top(y)  = clamp(((y + LB_RND) >>> 16) - LB_CTR,               0, H-1)
//     lb_hold = 1 while row need(next) has not been fully received, and input
//     row r is accepted only while r < top(oldest in-flight pixel) + LB_ROWS.
//   Common register map (byte offsets, 32-bit):
//     0x000 ID        (RO) ASCII IP tag (IP_ID, first character in [31:24])
//     0x004 VERSION   (RO) ASCII "d.dd" (IP_VERSION of the scaler)
//     0x008 DATE      (RO) BCD mm/dd/yyyy (IP_DATE of the scaler)
//     0x00C reserved  (reads 0)
//     0x010 CTRL      [0] ENABLE (RW) - run continuously while set
//     0x014 STATUS    [0] BUSY [1] FRAME_DONE* [2] SOF_ERR* [3] EOL_ERR*
//                     [4] CAPTURING [5] GENERATING   (* = write 1 clears)
//     0x018 IN_SIZE   [15:0] width [31:16] height
//     0x01C OUT_SIZE  [15:0] width [31:16] height
//     0x020 STEP_X    unsigned 16.16 source pixels per output pixel
//     0x024 STEP_Y    unsigned 16.16
//     0x028 OFFS_X    signed 16.16 source position of output pixel 0; pixel-
//                     centre alignment as OpenCV cv::resize INTER_LINEAR is
//                     OFFS = STEP / 2 - 0.5, i.e. (STEP >> 1) - 0x8000
//     0x02C OFFS_Y    signed 16.16
//     0x030 FRAME_CNT (RO) frames completed
//     0x034 IP_ID     (RO) ASCII IP tag (same as ID)
//     0x038 CAPS      (RO) IP capability word
//     0x03C MAX_SIZE  (RO) [15:0] MAX_W [31:16] MAX_H
//     0x050-0x0FF     forwarded to the IP (1-cycle read latency); the IP
//                     sees these addresses less 0x10 (0x040-0x0EF, the
//                     offsets its own decoder uses), so the ID block
//                     does not move its registers internally
//     0x100+          forwarded to the IP unchanged (coefficient tables)
//   Responses: SLVERR for writes to the ID block (0x000-0x00F) and to the
//   read-only words 0x030-0x03F, and for any access to the unmapped words
//   0x040-0x04F (0x00C reads 0, OKAY); the access has no effect. With
//   EXT_WORDS >= 0 the IP has EXT_WORDS registers at 0x050 and up: accesses
//   beyond them (0x050 + 4 * EXT_WORDS and up, including 0x100+) answer
//   SLVERR and are not forwarded. EXT_WORDS = -1 (default) forwards the
//   whole range and always answers OKAY there (the IP decodes it).
// Date: 2026-10-21

module scaler_ctrl #(
  /* verilator lint_off UNUSEDPARAM */           // the width of s_axis / fb (set by their interfaces)
  parameter int          PIX_W   = 24,     // pixel width in bits
  /* verilator lint_on UNUSEDPARAM */
  parameter int          ADDR_W  = 14,     // AXI-Lite address width
  parameter int          MAX_W   = 1920,   // frame buffer width (RO reg)
  parameter int          MAX_H   = 1080,   // frame buffer height (RO reg)
  parameter logic [31:0] IP_ID   = 32'h0,  // value of the ID / IP_ID registers
  parameter logic [31:0] IP_VERSION = "1.00",       // VERSION: ASCII "d.dd" of the scaler
  parameter logic [31:0] IP_DATE    = 32'h0101_2026, // DATE: BCD mm/dd/yyyy of the scaler
  parameter logic [31:0] CAPS    = 32'h0,  // value of the CAPS register
  parameter int          NBUF    = 1,      // 1 = single, 2 = double frame buffer
  parameter int          LB_ROWS = 0,      // > 0: line-buffer mode, ring size
  parameter int          LB_TAPS = 1,      // line-buffer mode: vertical taps
  parameter int          LB_CTR  = 0,      //   window top = int(y) - LB_CTR
  parameter int          LB_RND  = 0,      //   rounding added to y (16.16)
  parameter int          EXT_WORDS = -1    // IP registers at 0x050+ (-1: the IP decodes its own range)
)(
  input  logic               clk,         // clock
  input  logic               rst_n,       // synchronous reset, active low
  // AXI4-Lite slave
  // s_axil: axil_if.slave (ip/shared/src/interfaces/axil_if.sv), ADDR_W = ADDR_W
  axil_if.slave s_axil,
  // AXI4-Stream video input
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = PIX_W
  axis_if.slave s_axis,
  // Frame buffer write port
  // fb: fb_wr_if.source (ip/shared/src/interfaces/fb_wr_if.sv), PIX_W = PIX_W {fb_we=en fb_wx=x fb_wy=y fb_wdata=data fb_wbuf=buf_sel}
  fb_wr_if.source fb,
  output logic               gen_buf,        // buffer to generate from
  // Generation handshake
  output logic               gen_start,   // 1-cycle pulse, frame captured
  input  logic               gen_done,    // 1-cycle pulse, last output pixel sent
  // Line-buffer flow control (ignored when LB_ROWS = 0)
  input  logic signed [31:0] lb_nxt_y,    // y of the next pixel the DDA emits
  input  logic               lb_nxt_v,    //   valid (DDA busy)
  input  logic signed [31:0] lb_o_y,      // y of the DDA output register
  input  logic               lb_o_v,
  input  logic signed [31:0] lb_a_y,      // y of the pixel in read stage A
  input  logic               lb_a_v,
  output logic               lb_hold,     // 1: DDA must not emit (insert bubble)
  // Configuration registers (static while a frame is processed)
  output logic [15:0]        cfg_in_w,
  output logic [15:0]        cfg_in_h,
  output logic [15:0]        cfg_out_w,
  output logic [15:0]        cfg_out_h,
  output logic [31:0]        cfg_step_x,
  output logic [31:0]        cfg_step_y,
  output logic signed [31:0] cfg_offs_x,
  output logic signed [31:0] cfg_offs_y,
  // IP-specific register bus (addresses >= 0x040)
  // ext: regbus_if.host (ip/shared/src/interfaces/regbus_if.sv), ADDR_W = ADDR_W {ext_wr=wr ext_waddr=waddr ext_wdata=wdata ext_rd=rd ext_raddr=raddr ext_rdata=rdata}
  regbus_if.host ext
);
  assign ext.wstrb = '1;      // not used by this block

  // ---------------------------------------------------------------------------
  // AXI-Lite bridge
  // ---------------------------------------------------------------------------
  regbus_if #(.ADDR_W(ADDR_W), .DATA_W(32)) bus ();
  logic              reg_wr, reg_rd;
  logic [ADDR_W-1:0] reg_waddr, reg_raddr;
  logic [31:0]       reg_rdata;

  axil_regbus #(
    .ADDR_W(ADDR_W),
    .DATA_W(32)
  ) u_axil (
    .clk,
    .rst_n,
    .s_axil(s_axil),
    .bus(bus)
  );

  // ID block at 0x00-0x0F; the rest of the 0x000-0x0FF window is the old map moved up by 0x10:
  // internal address = bus address - 0x10 (below 0x100), 0x100 and up unchanged
  localparam logic [ADDR_W-1:0] ID_END = ADDR_W'('h10), WIN_END = ADDR_W'('h100);
  function automatic logic [ADDR_W-1:0] remap(input logic [ADDR_W-1:0] a);
    return (a < WIN_END) ? a - ID_END : a;
  endfunction
  // Address classes (internal addresses): 0x20-0x2F read only, 0x30-0x3F unmapped, 0x40+ the IP
  localparam logic [ADDR_W-1:0] RO_BASE = ADDR_W'('h20), UNM_BASE = ADDR_W'('h30);
  localparam logic [ADDR_W-1:0] EXT_BASE = ADDR_W'('h40);
  /* verilator lint_off UNSIGNED */               // constant for EXT_WORDS = 0 (every IP address is beyond)
  function automatic logic ext_bad(input logic [ADDR_W-1:0] a);   // beyond the IP's EXT_WORDS
    return (EXT_WORDS >= 0) && (a >= EXT_BASE) && (32'(a - EXT_BASE) >= 32'(EXT_WORDS) * 32'd4);
  endfunction
  /* verilator lint_on UNSIGNED */
  wire [ADDR_W-1:0] bus_wi = remap(bus.waddr), bus_ri = remap(bus.raddr);
  wire wr_bad = (bus.waddr < ID_END) || ((bus_wi >= RO_BASE) && (bus_wi < EXT_BASE)) || ext_bad(bus_wi);
  wire rd_bad = (bus.raddr >= ID_END) && (((bus_ri >= UNM_BASE) && (bus_ri < EXT_BASE)) || ext_bad(bus_ri));
  assign reg_wr    = bus.wr && !wr_bad;          // refused writes have no effect
  assign reg_rd    = bus.rd && (bus.raddr >= ID_END);
  assign reg_waddr = bus_wi;
  assign reg_raddr = bus_ri;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      bus.wr_err <= 1'b0;
      bus.rd_err <= 1'b0;
    end else begin
      bus.wr_err <= bus.wr && wr_bad;
      if (bus.rd) bus.rd_err <= rd_bad;
    end
  end
  logic        id_q;
  logic [31:0] id_rdata;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      id_q     <= 1'b0;
      id_rdata <= '0;
    end else if (bus.rd) begin
      id_q <= (bus.raddr < ID_END);
      case (bus.raddr[3:2])
        2'd0:    id_rdata <= IP_ID;
        2'd1:    id_rdata <= IP_VERSION;
        2'd2:    id_rdata <= IP_DATE;
        default: id_rdata <= '0;
      endcase
    end
  end
  assign bus.rdata = id_q ? id_rdata : reg_rdata;

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------
  // Frame sequencing states
  //   S_IDLE     : disabled, input not accepted
  //   S_CAPTURE  : accepting the input frame into the frame buffer
  //   S_GENERATE : IP is producing the output frame, input stalled
  //   S_HOLD     : (NBUF = 2) frame captured, waiting for the generator to
  //                finish the other buffer
  typedef enum logic [1:0] {S_IDLE, S_CAPTURE, S_GENERATE, S_HOLD} state_t;
  state_t state;
  logic        cap_buf;    // buffer being captured into
  logic        gen_busy;   // output generator running
  logic [15:0] rows_rcvd;  // line-buffer mode: complete rows received
  logic        lb_run;     // line-buffer mode: DDA has started this frame

  logic        enable;                          // CTRL.ENABLE
  logic        st_done, st_sof_err, st_eol_err; // sticky STATUS bits
  logic [31:0] frame_cnt;                       // FRAME_CNT

  // capture side flags written from the capture process
  logic        set_sof_err, set_eol_err, set_done;

  // Write to a common register; widx is the 32-bit word index
  wire wr_common = reg_wr && (reg_waddr < EXT_BASE);
  wire [5:0] widx = reg_waddr[7:2];

  // Common register writes (reset values give a 1x1 identity setup)

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      enable     <= 1'b0;
      cfg_in_w   <= 16'd1;
      cfg_in_h  <= 16'd1;
      cfg_out_w  <= 16'd1;
      cfg_out_h <= 16'd1;
      cfg_step_x <= 32'h1_0000;
      cfg_step_y <= 32'h1_0000;
      cfg_offs_x <= '0;
      cfg_offs_y <= '0;
      st_done    <= 1'b0;
      st_sof_err <= 1'b0;
      st_eol_err <= 1'b0;
    end else begin
      if (wr_common) begin
        case (widx)
          6'h00: enable <= bus.wdata[0];           // CTRL
          6'h01: begin                             // STATUS: W1C bits
            if (bus.wdata[1]) st_done    <= 1'b0;
            if (bus.wdata[2]) st_sof_err <= 1'b0;
            if (bus.wdata[3]) st_eol_err <= 1'b0;
          end
          // IN_SIZE / OUT_SIZE / STEP / OFFS
          6'h02: begin
            cfg_in_w  <= bus.wdata[15:0];
            cfg_in_h  <= bus.wdata[31:16];
          end
          6'h03: begin
            cfg_out_w <= bus.wdata[15:0];
            cfg_out_h <= bus.wdata[31:16];
          end
          6'h04: cfg_step_x <= bus.wdata;
          6'h05: cfg_step_y <= bus.wdata;
          6'h06: cfg_offs_x <= bus.wdata;
          6'h07: cfg_offs_y <= bus.wdata;
          default: ;
        endcase
      end
      // hardware set has priority over software clear
      if (set_done)    st_done    <= 1'b1;
      if (set_sof_err) st_sof_err <= 1'b1;
      if (set_eol_err) st_eol_err <= 1'b1;
    end
  end

  // External (IP-specific) register bus: pass through addresses >= 0x40
  assign ext.wr    = reg_wr && (reg_waddr >= EXT_BASE);
  assign ext.waddr = reg_waddr;
  assign ext.raddr = reg_raddr;
  assign ext.wdata = bus.wdata;
  assign ext.rd    = reg_rd && (reg_raddr >= EXT_BASE) && !ext_bad(reg_raddr);   // refused reads are not forwarded

  // Read mux (registered, 1-cycle latency as axil_regbus expects).
  // rd_ext_q remembers whether the read targeted the IP registers, in
  // which case the IP's own registered ext_rdata is returned instead.
  logic [31:0] common_rdata;
  logic        rd_ext_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      common_rdata <= '0;
      rd_ext_q     <= 1'b0;
    end else if (reg_rd) begin
      rd_ext_q <= (reg_raddr >= EXT_BASE);
      case (reg_raddr[7:2])
        6'h00: common_rdata <= {31'd0, enable};
        // STATUS: {GENERATING, CAPTURING, EOL_ERR, SOF_ERR, DONE, BUSY}
        6'h01: common_rdata <= {26'd0, gen_busy, state == S_CAPTURE,
                                st_eol_err, st_sof_err, st_done, (state != S_IDLE) || gen_busy};
        6'h02: common_rdata <= {cfg_in_h, cfg_in_w};
        6'h03: common_rdata <= {cfg_out_h, cfg_out_w};
        6'h04: common_rdata <= cfg_step_x;
        6'h05: common_rdata <= cfg_step_y;
        6'h06: common_rdata <= cfg_offs_x;
        6'h07: common_rdata <= cfg_offs_y;
        6'h08: common_rdata <= frame_cnt;
        6'h09: common_rdata <= IP_ID;
        6'h0A: common_rdata <= CAPS;
        6'h0B: common_rdata <= {16'(MAX_H), 16'(MAX_W)};
        default: common_rdata <= '0;
      endcase
    end
  end
  assign reg_rdata = rd_ext_q ? ext.rdata : common_rdata;

  // ---------------------------------------------------------------------------
  // Capture / sequencing FSM
  // ---------------------------------------------------------------------------
  localparam bit LB = (LB_ROWS > 0);

  logic [15:0] cx, cy;     // position of the next expected pixel
  logic        started;    // SOF seen, frame capture in progress

  // ---- line-buffer flow control -------------------------------------------
  function automatic logic [15:0] lb_row(input logic signed [31:0] y, input int add);
    logic signed [31:0] r;
    r = ((y + 32'(LB_RND)) >>> 16) - 32'(LB_CTR) + 32'(add);
    if (r < 0)                                return 16'd0;
    else if (r > $signed({16'd0, cfg_in_h}) - 1) return cfg_in_h - 16'd1;
    else                                      return r[15:0];
  endfunction

  logic [15:0] lb_need, lb_low;
  logic        lb_row_ok;
  always_comb begin
    lb_need = lb_row(lb_nxt_y, LB_TAPS - 1);
    if (lb_a_v)        lb_low = lb_row(lb_a_y, 0);
    else if (lb_o_v)   lb_low = lb_row(lb_o_y, 0);
    else if (lb_nxt_v) lb_low = lb_row(lb_nxt_y, 0);
    else               lb_low = lb_run ? cfg_in_h : 16'd0;     // DDA finished / not started
    // the next input row (0 before SOF) may overwrite ring slot row - LB_ROWS
    lb_row_ok = !LB || (32'(started ? cy : 16'd0) < 32'(lb_low) + LB_ROWS);
  end
  assign lb_hold = LB && lb_nxt_v && (rows_rcvd <= lb_need);

  // Input is accepted while capturing (line-buffer mode: while the ring has
  // room); otherwise it is back-pressured.
  assign s_axis.tready = (state == S_CAPTURE) && lb_row_ok;

  // A beat carrying tuser starts a new frame at (0,0) (line-buffer mode: only
  // the first SOF; a mid-frame SOF is flagged and otherwise ignored because
  // the generator is already consuming the frame). Beats before the first SOF
  // are dropped (accept = 0).
  wire         restart = s_axis.tuser && (!LB || !started);
  wire         beat    = s_axis.tvalid && s_axis.tready;
  wire  [15:0] px      = restart ? 16'd0 : cx;
  wire  [15:0] py      = restart ? 16'd0 : cy;
  wire         accept  = s_axis.tuser || started;
  wire         last_x  = (px == cfg_in_w - 16'd1);
  wire         last_px = last_x && (py == cfg_in_h - 16'd1);
  wire         gen_free = !gen_busy || gen_done;   // generator idle this cycle

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state       <= S_IDLE;
      cx          <= '0;
      cy          <= '0;
      started     <= 1'b0;
      cap_buf     <= 1'b0;
      gen_buf     <= 1'b0;
      gen_busy    <= 1'b0;
      rows_rcvd   <= '0;
      lb_run      <= 1'b0;
      fb.en       <= 1'b0;
      fb.x       <= '0;
      fb.y       <= '0;
      fb.data    <= '0;
      fb.buf_sel     <= 1'b0;
      gen_start   <= 1'b0;
      set_sof_err <= 1'b0;
      set_eol_err <= 1'b0;
      set_done    <= 1'b0;
      frame_cnt   <= '0;
    end else begin
      // default: all strobes are single-cycle pulses
      fb.en       <= 1'b0;
      gen_start   <= 1'b0;
      set_sof_err <= 1'b0;
      set_eol_err <= 1'b0;
      set_done    <= 1'b0;

      // line-buffer bookkeeping: remember that the DDA has started
      if (gen_start)     lb_run <= 1'b0;
      else if (lb_nxt_v) lb_run <= 1'b1;

      // generator completion (any state)
      if (gen_done) begin
        gen_busy  <= 1'b0;
        frame_cnt <= frame_cnt + 32'd1;
        set_done  <= 1'b1;
      end

      case (state)
        // wait for ENABLE
        S_IDLE: begin
          started <= 1'b0;
          if (enable && (!LB || gen_free)) state <= S_CAPTURE;
        end
        // store pixels until the last pixel of the frame arrives
        S_CAPTURE: begin
          if (beat) begin
            if (s_axis.tuser && started && (cx != 0 || cy != 0))
              set_sof_err <= 1'b1;              // SOF in the middle of a frame
            if (!accept) begin
              set_sof_err <= 1'b1;              // data before SOF: dropped
            end else begin
              // write the pixel into the frame store
              fb.en    <= 1'b1;
              fb.x    <= px;
              fb.y    <= py;
              fb.data <= s_axis.tdata;
              fb.buf_sel  <= cap_buf;
              // tlast must coincide with the last column of IN_SIZE
              if (s_axis.tlast != last_x) set_eol_err <= 1'b1;
              // line-buffer mode: generation starts with the frame
              if (LB && !started) begin
                rows_rcvd <= '0;
                gen_buf   <= cap_buf;
                gen_busy  <= 1'b1;
                gen_start <= 1'b1;
              end
              if (last_x) rows_rcvd <= py + 16'd1;
              if (last_px) begin
                started <= 1'b0;
                cx      <= '0;
                cy      <= '0;
                if (LB) begin
                  state <= S_GENERATE;                 // wait for the last rows
                end else if (gen_free) begin
                  // hand the captured buffer to the generator
                  gen_buf   <= cap_buf;
                  gen_busy  <= 1'b1;
                  gen_start <= 1'b1;
                  if (NBUF == 2) begin
                    cap_buf <= !cap_buf;               // capture into the other one
                    state   <= enable ? S_CAPTURE : S_IDLE;
                  end else begin
                    state   <= S_GENERATE;
                  end
                end else begin
                  state <= S_HOLD;                     // NBUF = 2: both buffers full
                end
              end else begin
                // advance to the next pixel position (raster order)
                started <= 1'b1;
                if (last_x) begin
                  cx <= '0;
                  cy <= py + 16'd1;
                end
                else        begin
                  cx <= px + 16'd1;
                  cy <= py;
                end
              end
            end
          end else if (!enable && !started) begin
            // disabled between frames: go idle (a started frame is
            // always completed first)
            state <= S_IDLE;
          end
        end
        // wait for the generator (NBUF = 1 and line-buffer mode)
        S_GENERATE: begin
          if (gen_free) state <= state_t'(enable ? S_CAPTURE : S_IDLE);
        end
        // NBUF = 2: a frame is waiting in cap_buf for the generator
        S_HOLD: begin
          if (gen_free) begin
            gen_buf   <= cap_buf;
            gen_busy  <= 1'b1;
            gen_start <= 1'b1;
            cap_buf   <= !cap_buf;
            state     <= state_t'(enable ? S_CAPTURE : S_IDLE);
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
