// ***************
// Filename: scaler_ctrl.sv
// Author: Paul Barcelona
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
//     0x000 CTRL      [0] ENABLE (RW) - run continuously while set
//     0x004 STATUS    [0] BUSY [1] FRAME_DONE* [2] SOF_ERR* [3] EOL_ERR*
//                     [4] CAPTURING [5] GENERATING   (* = write 1 clears)
//     0x008 IN_SIZE   [15:0] width [31:16] height
//     0x00C OUT_SIZE  [15:0] width [31:16] height
//     0x010 STEP_X    unsigned 16.16 source pixels per output pixel
//     0x014 STEP_Y    unsigned 16.16
//     0x018 OFFS_X    signed 16.16 source position of output pixel 0
//     0x01C OFFS_Y    signed 16.16
//     0x020 FRAME_CNT (RO) frames completed
//     0x024 IP_ID     (RO) ASCII IP tag
//     0x028 CAPS      (RO) IP capability word
//     0x02C MAX_SIZE  (RO) [15:0] MAX_W [31:16] MAX_H
//     0x040+          forwarded to the IP (1-cycle read latency)
// Date: 2026-09-26

module scaler_ctrl #(
  parameter int          PIX_W   = 24,     // pixel width in bits
  parameter int          ADDR_W  = 14,     // AXI-Lite address width
  parameter int          MAX_W   = 1920,   // frame buffer width (RO reg)
  parameter int          MAX_H   = 1080,   // frame buffer height (RO reg)
  parameter logic [31:0] IP_ID   = 32'h0,  // value of the IP_ID register
  parameter logic [31:0] CAPS    = 32'h0,  // value of the CAPS register
  parameter int          NBUF    = 1,      // 1 = single, 2 = double frame buffer
  parameter int          LB_ROWS = 0,      // > 0: line-buffer mode, ring size
  parameter int          LB_TAPS = 1,      // line-buffer mode: vertical taps
  parameter int          LB_CTR  = 0,      //   window top = int(y) - LB_CTR
  parameter int          LB_RND  = 0       //   rounding added to y (16.16)
)(
  input  logic               clk,         // clock
  input  logic               rst_n,       // async reset, active low
  // AXI4-Lite slave
  input  logic [ADDR_W-1:0]  s_axil_awaddr,
  input  logic               s_axil_awvalid,
  output logic               s_axil_awready,
  input  logic [31:0]        s_axil_wdata,
  input  logic [3:0]         s_axil_wstrb,
  input  logic               s_axil_wvalid,
  output logic               s_axil_wready,
  output logic [1:0]         s_axil_bresp,
  output logic               s_axil_bvalid,
  input  logic               s_axil_bready,
  input  logic [ADDR_W-1:0]  s_axil_araddr,
  input  logic               s_axil_arvalid,
  output logic               s_axil_arready,
  output logic [31:0]        s_axil_rdata,
  output logic [1:0]         s_axil_rresp,
  output logic               s_axil_rvalid,
  input  logic               s_axil_rready,
  // AXI4-Stream video input
  input  logic [PIX_W-1:0]   s_axis_tdata,   // pixel
  input  logic               s_axis_tvalid,
  output logic               s_axis_tready,  // high only while capturing
  input  logic               s_axis_tuser,   // start of frame
  input  logic               s_axis_tlast,   // end of line
  // Frame buffer write port
  output logic               fb_we,          // write strobe
  output logic [15:0]        fb_wx,          // pixel column
  output logic [15:0]        fb_wy,          // pixel row
  output logic [PIX_W-1:0]   fb_wdata,       // pixel data
  output logic               fb_wbuf,        // buffer written (NBUF = 2)
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
  output logic               ext_wr,
  output logic [ADDR_W-1:0]  ext_waddr,
  output logic [31:0]        ext_wdata,
  output logic               ext_rd,
  output logic [ADDR_W-1:0]  ext_raddr,
  input  logic [31:0]        ext_rdata    // valid the cycle after ext_rd
);

  // ---------------------------------------------------------------------------
  // AXI-Lite bridge
  // ---------------------------------------------------------------------------
  logic              reg_wr, reg_rd;
  logic [ADDR_W-1:0] reg_waddr, reg_raddr;
  logic [31:0]       reg_wdata, reg_rdata;
  logic [3:0]        reg_wstrb;

  axil_regbus #(.ADDR_W(ADDR_W), .DATA_W(32)) u_axil (
    .clk, .rst_n,
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata,  .s_axil_wstrb,   .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp,  .s_axil_bvalid,  .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata,  .s_axil_rresp,   .s_axil_rvalid, .s_axil_rready,
    .reg_wr, .reg_waddr, .reg_wdata, .reg_wstrb,
    .reg_rd, .reg_raddr, .reg_rdata
  );

  // Addresses at or above EXT_BASE belong to the IP-specific registers
  localparam logic [ADDR_W-1:0] EXT_BASE = ADDR_W'('h40);

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

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      enable     <= 1'b0;
      cfg_in_w   <= 16'd1;  cfg_in_h  <= 16'd1;
      cfg_out_w  <= 16'd1;  cfg_out_h <= 16'd1;
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
          6'h00: enable <= reg_wdata[0];           // CTRL
          6'h01: begin                             // STATUS: W1C bits
            if (reg_wdata[1]) st_done    <= 1'b0;
            if (reg_wdata[2]) st_sof_err <= 1'b0;
            if (reg_wdata[3]) st_eol_err <= 1'b0;
          end
          // IN_SIZE / OUT_SIZE / STEP / OFFS
          6'h02: begin cfg_in_w  <= reg_wdata[15:0]; cfg_in_h  <= reg_wdata[31:16]; end
          6'h03: begin cfg_out_w <= reg_wdata[15:0]; cfg_out_h <= reg_wdata[31:16]; end
          6'h04: cfg_step_x <= reg_wdata;
          6'h05: cfg_step_y <= reg_wdata;
          6'h06: cfg_offs_x <= reg_wdata;
          6'h07: cfg_offs_y <= reg_wdata;
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
  assign ext_wr    = reg_wr && (reg_waddr >= EXT_BASE);
  assign ext_waddr = reg_waddr;
  assign ext_raddr = reg_raddr;
  assign ext_wdata = reg_wdata;
  assign ext_rd    = reg_rd && (reg_raddr >= EXT_BASE);

  // Read mux (registered, 1-cycle latency as axil_regbus expects).
  // rd_ext_q remembers whether the read targeted the IP registers, in
  // which case the IP's own registered ext_rdata is returned instead.
  logic [31:0] common_rdata;
  logic        rd_ext_q;
  always_ff @(posedge clk or negedge rst_n) begin
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
  assign reg_rdata = rd_ext_q ? ext_rdata : common_rdata;

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
  assign s_axis_tready = (state == S_CAPTURE) && lb_row_ok;

  // A beat carrying tuser starts a new frame at (0,0) (line-buffer mode: only
  // the first SOF; a mid-frame SOF is flagged and otherwise ignored because
  // the generator is already consuming the frame). Beats before the first SOF
  // are dropped (accept = 0).
  wire         restart = s_axis_tuser && (!LB || !started);
  wire         beat    = s_axis_tvalid && s_axis_tready;
  wire  [15:0] px      = restart ? 16'd0 : cx;
  wire  [15:0] py      = restart ? 16'd0 : cy;
  wire         accept  = s_axis_tuser || started;
  wire         last_x  = (px == cfg_in_w - 16'd1);
  wire         last_px = last_x && (py == cfg_in_h - 16'd1);
  wire         gen_free = !gen_busy || gen_done;   // generator idle this cycle

  always_ff @(posedge clk or negedge rst_n) begin
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
      fb_we       <= 1'b0;
      fb_wx       <= '0;
      fb_wy       <= '0;
      fb_wdata    <= '0;
      fb_wbuf     <= 1'b0;
      gen_start   <= 1'b0;
      set_sof_err <= 1'b0;
      set_eol_err <= 1'b0;
      set_done    <= 1'b0;
      frame_cnt   <= '0;
    end else begin
      // default: all strobes are single-cycle pulses
      fb_we       <= 1'b0;
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
            if (s_axis_tuser && started && (cx != 0 || cy != 0))
              set_sof_err <= 1'b1;              // SOF in the middle of a frame
            if (!accept) begin
              set_sof_err <= 1'b1;              // data before SOF: dropped
            end else begin
              // write the pixel into the frame store
              fb_we    <= 1'b1;
              fb_wx    <= px;
              fb_wy    <= py;
              fb_wdata <= s_axis_tdata;
              fb_wbuf  <= cap_buf;
              // tlast must coincide with the last column of IN_SIZE
              if (s_axis_tlast != last_x) set_eol_err <= 1'b1;
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
                if (last_x) begin cx <= '0;         cy <= py + 16'd1; end
                else        begin cx <= px + 16'd1; cy <= py;         end
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
          if (gen_free) begin
            if (enable) state <= S_CAPTURE;
            else        state <= S_IDLE;
          end
        end
        // NBUF = 2: a frame is waiting in cap_buf for the generator
        S_HOLD: begin
          if (gen_free) begin
            gen_buf   <= cap_buf;
            gen_busy  <= 1'b1;
            gen_start <= 1'b1;
            cap_buf   <= !cap_buf;
            if (enable) state <= S_CAPTURE;
            else        state <= S_IDLE;
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
