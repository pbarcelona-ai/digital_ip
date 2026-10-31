// ***************
// Filename: ddr_frame_store.sv
// Author: FPGA Cores 4 U
// Description: vision_system's frame store in DDR (USE_DDR_FB), an AXI4
//   master of the shared DDR controller (ip/memory/ddr_ctrl). Version 2.0.0.
//   Golden model: model/ddr_frame_store_model.py (clock exact; tb/python,
//   with ddr_ctrl and ddr_mem).
//   - Two frame buffers in DDR at byte addresses BASE0 / BASE1 (wr_buf /
//     rd_buf choose one per access); pixel a of buffer b is the 32-bit slot
//     at BASE<b> + 4 a, the pixel in its low PIX_W bits (the rest 0). Every
//     slot must lie in the memory behind the controller: BRESP / RRESP are
//     not checked, read data is used as returned.
//   - Writes (wr_en with wr_ready): a combiner gathers the pixels of one
//     DATA_W word (PPB = DATA_W / 32 slots, byte strobes per slot). A write
//     to another word pushes the gathered word into the write queue
//     (fallthrough_fifo, WQ_DEPTH words) and starts the next; a word with
//     every slot written is pushed at once; a partial word is pushed after
//     FLUSH_IDLE clocks without a write (with room in the queue). wr_ready =
//     the queue is not full. Each queued word is one single-beat AXI write
//     (AWLEN 0, full size, INCR, AWID WR_ID, WLAST 1): AW and W presented
//     together, each dropped at its handshake; the next word is loaded once
//     both have gone, while fewer than OUT_MAX writes wait for B (BREADY 1).
//     wr_idle = nothing gathered, queued, presented or waiting for B.
//   - Reads (rd_en with rd_ready): a direct-mapped cache of CACHE_LINES lines
//     of LINE_PIX pixels (line = slot index >> log2(LINE_PIX), set = line mod
//     CACHE_LINES, tag = line / CACHE_LINES), its RAM in four copies (one
//     synchronous read port per address, every copy written by a fill). The
//     request in lookup looks its four addresses up every clock: each that
//     hits and is not yet read is read from its copy (the word the next
//     clock, the pixel captured then); a miss loads the line of the first
//     address neither read nor hitting, with one AXI read burst of LINE_PIX /
//     PPB beats (ARID RD_ID, full size, INCR; RREADY 1 while loading), each
//     beat written as it arrives, valid after the last; the lookups go on
//     (addresses already read are kept: two addresses whose lines share a set
//     never evict each other forever). The request completes in the clock its
//     last addresses are read; the clock after, rd_valid pulses with
//     rd_data0..3 (registers). rd_ready = no request in lookup, or the one in
//     lookup completing this clock: one request per clock while the lines are
//     cached, 3 clocks from a request to its rd_valid, requests answered in
//     order (vision_system's output at a pixel per clock, as its on-chip
//     store).
//   - rd_flush (taken with rd_ready, before a request in the same clock):
//     every line becomes invalid. The cache does not see writes: pulse
//     rd_flush after a rewritten buffer is complete (wr_idle), before
//     reading it.
//   - clear (the user's soft reset, e.g. vision_system's CTRL[0]): the read
//     request in lookup is dropped without rd_valid, at once, or after the
//     last beat of its line fill (an AXI burst is always completed), and so
//     is the rd_valid of a request completed the clock before; rd_en is
//     ignored in that clock. Writes and the cache lines
//     are not affected.
//   Every output is a register or a function of registers.
//   Parameters: PIX_W (<= 32), ADDR_W (pixel address bits), DATA_W (AXI data,
//   power of two >= 64), AXI_ADDR_W, ID_W, BASE0 / BASE1, LINE_PIX /
//   CACHE_LINES / WQ_DEPTH (powers of two >= 2; LINE_PIX 2 .. 256 beats of
//   PPB pixels and at most 1024 pixels: a line fill never crosses 4 KB),
//   FLUSH_IDLE / OUT_MAX (1 .. 255), WR_ID / RD_ID.
//   Clock - clk (the controller's). Reset - synchronous active low rst_n,
//   the controller's reset (asserted with it, so that no AXI transaction is
//   abandoned; the cache RAM keeps its contents). Clock-domain crossings -
//   none.
//   Resources - the cache RAM 4 x CACHE_LINES x LINE_PIX x PIX_W bits, the
//   queue WQ_DEPTH x (AXI_ADDR_W + 9 DATA_W / 8) bits. Errors - none
//   reported.
// Date: 2026-10-26
module ddr_frame_store #(
  parameter int PIX_W       = 24,                // pixel bits (<= 32)
  parameter int ADDR_W      = 19,                // pixel address bits
  parameter int DATA_W      = 256,               // AXI data bits
  parameter int AXI_ADDR_W  = 32,                // AXI byte address bits
  parameter int ID_W        = 4,                 // AXI ID bits
  parameter logic [AXI_ADDR_W-1:0] BASE0 = '0,   // byte address of buffer 0
  parameter logic [AXI_ADDR_W-1:0] BASE1 = AXI_ADDR_W'(1) << (ADDR_W + 2),   // byte address of buffer 1
  parameter int LINE_PIX    = 32,                // pixels per cache line
  parameter int CACHE_LINES = 64,                // cache lines
  parameter int WQ_DEPTH    = 8,                 // write queue words
  parameter int FLUSH_IDLE  = 8,                 // clocks without a write before a partial word is written
  parameter int OUT_MAX     = 8,                 // writes waiting for B, at most
  parameter int WR_ID       = 0,                 // AWID
  parameter int RD_ID       = 1                  // ARID
) (
  input  logic                    clk,           // clock
  input  logic                    rst_n,         // synchronous, active low
  // write port
  input  logic                    wr_en,         // write a pixel (taken with wr_ready)
  output logic                    wr_ready,      // the write queue has room
  input  logic [ADDR_W-1:0]       wr_addr,       // pixel address
  input  logic [PIX_W-1:0]        wr_data,       // pixel
  input  logic                    wr_buf,        // buffer written
  output logic                    wr_idle,       // every write has reached the memory
  // read port (four addresses per request)
  input  logic                    rd_en,         // a request (taken with rd_ready)
  output logic                    rd_ready,      // no read active
  input  logic [ADDR_W-1:0]       rd_addr0,      // first address
  input  logic [ADDR_W-1:0]       rd_addr1,      // second address
  input  logic [ADDR_W-1:0]       rd_addr2,      // third address
  input  logic [ADDR_W-1:0]       rd_addr3,      // fourth address
  input  logic                    rd_buf,        // buffer read
  input  logic                    rd_flush,      // invalidate the cache (taken with rd_ready)
  input  logic                    clear,         // drop the read request in progress (soft reset)
  output logic                    rd_valid,      // one clock: the request's four pixels
  output logic [PIX_W-1:0]        rd_data0,      // pixel at rd_addr0
  output logic [PIX_W-1:0]        rd_data1,      // pixel at rd_addr1
  output logic [PIX_W-1:0]        rd_data2,      // pixel at rd_addr2
  output logic [PIX_W-1:0]        rd_data3,      // pixel at rd_addr3
  // AXI4 master (to a ddr_ctrl port)
  output logic [ID_W-1:0]         m_axi_awid,    // write address channel
  output logic [AXI_ADDR_W-1:0]   m_axi_awaddr,
  output logic [7:0]              m_axi_awlen,
  output logic [2:0]              m_axi_awsize,
  output logic [1:0]              m_axi_awburst,
  output logic                    m_axi_awvalid,
  input  logic                    m_axi_awready,
  output logic [DATA_W-1:0]       m_axi_wdata,   // write data channel
  output logic [DATA_W/8-1:0]     m_axi_wstrb,
  output logic                    m_axi_wlast,
  output logic                    m_axi_wvalid,
  input  logic                    m_axi_wready,
  input  logic [ID_W-1:0]         m_axi_bid,     // write response channel (not checked)
  input  logic [1:0]              m_axi_bresp,
  input  logic                    m_axi_bvalid,
  output logic                    m_axi_bready,
  output logic [ID_W-1:0]         m_axi_arid,    // read address channel
  output logic [AXI_ADDR_W-1:0]   m_axi_araddr,
  output logic [7:0]              m_axi_arlen,
  output logic [2:0]              m_axi_arsize,
  output logic [1:0]              m_axi_arburst,
  output logic                    m_axi_arvalid,
  input  logic                    m_axi_arready,
  input  logic [ID_W-1:0]         m_axi_rid,     // read data channel (ID, RRESP, RLAST not checked)
  input  logic [DATA_W-1:0]       m_axi_rdata,
  input  logic [1:0]              m_axi_rresp,
  input  logic                    m_axi_rlast,
  input  logic                    m_axi_rvalid,
  output logic                    m_axi_rready
);
  localparam int PPB   = DATA_W / 32;                        // pixel slots per word
  localparam int PB    = $clog2(PPB);
  localparam int OFF   = $clog2(DATA_W / 8);
  localparam int WAW   = AXI_ADDR_W - OFF;                   // word address bits
  localparam int SW    = AXI_ADDR_W - 2;                     // slot index bits
  localparam int BEATS = LINE_PIX / PPB;                     // beats per line
  localparam int LB    = $clog2(LINE_PIX);
  localparam int BB    = (BEATS > 1) ? $clog2(BEATS) : 1;
  localparam int SB    = $clog2(CACHE_LINES);
  localparam int TW    = SW - LB - SB;                       // tag bits
  localparam int NS    = DATA_W / 8;                         // strobes per word
  localparam int QW    = WAW + DATA_W + NS;                  // queue entry
  localparam int RW    = PPB * PIX_W;                        // cache RAM word
  localparam int RAW   = $clog2(CACHE_LINES * BEATS);
  if (DATA_W < 64 || (DATA_W & (DATA_W - 1)) != 0 || PIX_W < 1 || PIX_W > 32 || LINE_PIX < PPB ||
      (LINE_PIX & (LINE_PIX - 1)) != 0 || BEATS < 2 || BEATS > 256 || LINE_PIX > 1024 || CACHE_LINES < 2 ||
      (CACHE_LINES & (CACHE_LINES - 1)) != 0 || WQ_DEPTH < 2 || (WQ_DEPTH & (WQ_DEPTH - 1)) != 0 ||
      FLUSH_IDLE < 1 || FLUSH_IDLE > 255 || OUT_MAX < 1 || OUT_MAX > 255 || TW < 1) begin : g_bad
    $error("ddr_frame_store: DATA_W, LINE_PIX, CACHE_LINES, WQ_DEPTH powers of two; see the header");
  end

  // the 32-bit slot index of pixel a in buffer b
  function automatic logic [SW-1:0] slot_of(input logic b, input logic [ADDR_W-1:0] a);
    slot_of = (b ? BASE1[AXI_ADDR_W-1:2] : BASE0[AXI_ADDR_W-1:2]) + SW'(a);
  endfunction

  // ---------------- write side: combiner, queue, AXI write engine
  logic              cv;                                     // a word gathered
  logic [WAW-1:0]    cw;
  logic [DATA_W-1:0] cdata;
  logic [NS-1:0]     cstrb;
  logic [7:0]        idle_cnt;
  logic              aw_v, w_v;
  logic [WAW-1:0]    aw_word;
  logic [DATA_W-1:0] w_data;
  logic [NS-1:0]     w_strb;
  logic [7:0]        outst;
  logic              q_rdy, q_vld, push, load;
  logic [QW-1:0]     q_in, q_out;
  logic [$clog2(WQ_DEPTH):0] q_lvl;
  logic              wr, n_cv;
  logic [SW-1:0]     ws;
  logic [WAW-1:0]    wword;
  logic [PB-1:0]     wk;
  logic [DATA_W-1:0] n_cdata;
  logic [NS-1:0]     n_cstrb;
  logic [7:0]        n_idle;
  assign wr_ready = q_rdy;
  assign wr = wr_en && q_rdy;
  assign ws = slot_of(wr_buf, wr_addr);
  assign wword = ws[SW-1:PB];
  assign wk = ws[PB-1:0];
  always_comb begin
    push = 1'b0;
    q_in = {cw, cdata, cstrb};
    n_cv = cv;
    n_cdata = cdata;
    n_cstrb = cstrb;
    n_idle = idle_cnt;
    if (wr) begin
      if (cv && wword != cw) begin                           // another word: push the gathered one
        push = 1'b1;
        n_cdata = '0;
        n_cstrb = '0;
      end else if (!cv) begin
        n_cdata = '0;
        n_cstrb = '0;
      end
      n_cv = 1'b1;
      n_cdata[32*wk +: 32] = 32'(wr_data);
      n_cstrb[4*wk +: 4] = 4'hF;
      if (!push && n_cstrb == '1) begin                      // every slot written: push it
        push = 1'b1;
        q_in = {wword, n_cdata, n_cstrb};
        n_cv = 1'b0;
      end
      n_idle = '0;
    end else if (cv) begin
      if (idle_cnt == 8'(FLUSH_IDLE - 1) && q_rdy) begin    // a partial word after FLUSH_IDLE clocks
        push = 1'b1;
        n_cv = 1'b0;
        n_idle = '0;
      end else if (idle_cnt != 8'(FLUSH_IDLE - 1)) begin
        n_idle = idle_cnt + 8'd1;
      end
    end
  end
  assign load = !aw_v && !w_v && q_vld && outst < 8'(OUT_MAX);
  fallthrough_fifo #(
    .WIDTH(QW),
    .DEPTH(WQ_DEPTH)
  ) u_wq (
    .clk,
    .rst_n,
    .s_data_i(q_in),
    .s_valid_i(push),
    .s_ready_o(q_rdy),
    .m_data_o(q_out),
    .m_valid_o(q_vld),
    .m_ready_i(load),
    .level_o(q_lvl)
  );
  wire b_done = m_axi_bvalid;                                // BREADY is 1
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cv <= 1'b0;
      cw <= '0;
      cdata <= '0;
      cstrb <= '0;
      idle_cnt <= '0;
      aw_v <= 1'b0;
      w_v <= 1'b0;
      aw_word <= '0;
      w_data <= '0;
      w_strb <= '0;
      outst <= '0;
    end else begin
      cv <= n_cv;
      if (wr) cw <= wword;
      cdata <= n_cdata;
      cstrb <= n_cstrb;
      idle_cnt <= n_idle;
      if (aw_v && m_axi_awready) aw_v <= 1'b0;
      if (w_v && m_axi_wready) w_v <= 1'b0;
      if (load) begin
        aw_v <= 1'b1;
        w_v <= 1'b1;
        aw_word <= q_out[QW-1 -: WAW];
        w_data <= q_out[NS +: DATA_W];
        w_strb <= q_out[NS-1:0];
      end
      outst <= outst + 8'(load) - 8'(b_done);
    end
  end
  assign wr_idle = !cv && !q_vld && !aw_v && !w_v && outst == '0;
  assign m_axi_awid = ID_W'(WR_ID);
  assign m_axi_awaddr = {aw_word, {OFF{1'b0}}};
  assign m_axi_awlen = 8'd0;
  assign m_axi_awsize = 3'(OFF);
  assign m_axi_awburst = 2'b01;
  assign m_axi_awvalid = aw_v;
  assign m_axi_wdata = w_data;
  assign m_axi_wstrb = w_strb;
  assign m_axi_wlast = 1'b1;
  assign m_axi_wvalid = w_v;
  assign m_axi_bready = 1'b1;

  // ---------------- read side: four lookups per clock, line fills
  // the request in lookup (lv): its slots, the taps already read (got); a tap that hits is read from its own
  // copy of the cache RAM (four copies, written together by a fill), a missing one's line is filled (the first
  // missing tap, one fill at a time); the request completes in the clock its last taps are read (done), the
  // next one may be taken in that clock. A read's word is on its copy's output the clock after (rp, rsel) and
  // captured then (cap); the clock after a request completed (fin) its four pixels go to the outputs.
  logic              lv, fill, drop;
  logic [SW-1:0]     rslot [4];
  logic [3:0]        got, rp;
  logic [PB-1:0]     rsel [4];
  logic [PIX_W-1:0]  cap [4], rout [4];
  logic              fin;
  logic [CACHE_LINES-1:0] valid;
  logic [TW-1:0]     tag [CACHE_LINES];
  logic [SB-1:0]     fill_set;
  logic [BB-1:0]     fill_beat;
  logic              ar_v;
  logic [AXI_ADDR_W-1:0] ar_addr;
  logic [RW-1:0]     ram_q [4];
  // this clock's lookups
  logic [SW-LB-1:0]  lline [4];
  logic [SB-1:0]     lset [4];
  logic [TW-1:0]     ltag [4];
  logic [3:0]        hit, rd_tap;
  logic [1:0]        mk;                                     // the first missing tap
  logic [RW-1:0]     rbeat;
  logic [RW-1:0]     rq_w [4];                               // the words read last clock
  always_comb begin
    for (int t = 0; t < 4; t++) begin
      lline[t] = rslot[t][SW-1:LB];
      lset[t] = lline[t][SB-1:0];
      ltag[t] = lline[t][SW-LB-1:SB];
      hit[t] = valid[lset[t]] && tag[lset[t]] == ltag[t];
    end
    mk = '0;
    for (int t = 3; t >= 0; t--) if (!got[t] && !hit[t]) mk = 2'(t);
    for (int p = 0; p < PPB; p++) rbeat[p*PIX_W +: PIX_W] = m_axi_rdata[32*p +: PIX_W];
  end
  wire look   = lv && !fill;                                 // a request in lookup, no fill active
  wire all_in = &(got | hit);                                // every tap read or hitting now
  wire done   = look && !clear && all_in;
  wire miss   = look && !clear && !all_in;
  always_comb begin
    for (int t = 0; t < 4; t++) rd_tap[t] = look && !clear && !got[t] && hit[t];
  end
  assign rd_ready = !lv || (look && all_in);                 // (a function of registers)
  wire accept = rd_en && rd_ready && !clear;
  wire beat_in = fill && m_axi_rvalid;                       // RREADY is 1 while filling
  // the cache RAM: a copy per tap, one synchronous read port each, every copy written by a fill
  for (genvar t = 0; t < 4; t++) begin : g_copy
    logic [RW-1:0] ram [CACHE_LINES * BEATS];
    always_ff @(posedge clk) begin
      if (rd_tap[t]) ram_q[t] <= ram[RAW'(lset[t]) * RAW'(BEATS) + RAW'(rslot[t][LB-1:PB])];
      if (beat_in) ram[RAW'(fill_set) * RAW'(BEATS) + RAW'(fill_beat)] <= rbeat;
    end
  end
  always_comb begin
    for (int t = 0; t < 4; t++) rq_w[t] = ram_q[t];
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lv <= 1'b0;
      fill <= 1'b0;
      drop <= 1'b0;
      for (int t = 0; t < 4; t++) begin
        rslot[t] <= '0;
        rsel[t] <= '0;
        cap[t] <= '0;
        rout[t] <= '0;
      end
      got <= '0;
      rp <= '0;
      fin <= 1'b0;
      valid <= '0;
      for (int c = 0; c < CACHE_LINES; c++) tag[c] <= '0;
      fill_set <= '0;
      fill_beat <= '0;
      ar_v <= 1'b0;
      ar_addr <= '0;
      rd_valid <= 1'b0;
    end else begin
      // the words read last clock: into the outputs (their request completed) or the capture
      for (int t = 0; t < 4; t++) begin
        if (fin) rout[t] <= rp[t] ? rq_w[t][rsel[t]*PIX_W +: PIX_W] : cap[t];
        else if (rp[t]) cap[t] <= rq_w[t][rsel[t]*PIX_W +: PIX_W];
      end
      rd_valid <= fin && !clear;
      fin <= done;
      rp <= rd_tap;
      for (int t = 0; t < 4; t++) if (rd_tap[t]) rsel[t] <= rslot[t][PB-1:0];
      got <= got | rd_tap;
      if (rd_flush && rd_ready) valid <= '0;
      if (look && clear) lv <= 1'b0;                         // the request dropped at once
      else if (done) lv <= 1'b0;
      if (accept) begin
        lv <= 1'b1;
        got <= '0;
        rslot[0] <= slot_of(rd_buf, rd_addr0);
        rslot[1] <= slot_of(rd_buf, rd_addr1);
        rslot[2] <= slot_of(rd_buf, rd_addr2);
        rslot[3] <= slot_of(rd_buf, rd_addr3);
      end
      if (miss) begin                                        // the first missing tap's line
        valid[lset[mk]] <= 1'b0;
        tag[lset[mk]] <= ltag[mk];
        fill_set <= lset[mk];
        fill_beat <= '0;
        ar_v <= 1'b1;
        ar_addr <= AXI_ADDR_W'({lline[mk], {(LB + 2){1'b0}}});
        fill <= 1'b1;
      end
      if (fill) begin
        if (ar_v && m_axi_arready) ar_v <= 1'b0;
        drop <= drop || clear;
        if (m_axi_rvalid) begin
          if (fill_beat == BB'(BEATS - 1)) begin
            valid[fill_set] <= 1'b1;
            fill <= 1'b0;
            if (drop || clear) lv <= 1'b0;                   // dropped: the burst completed, no lookup
            drop <= 1'b0;
          end
          fill_beat <= (fill_beat == BB'(BEATS - 1)) ? '0 : fill_beat + 1'b1;
        end
      end
    end
  end
  assign rd_data0 = rout[0];
  assign rd_data1 = rout[1];
  assign rd_data2 = rout[2];
  assign rd_data3 = rout[3];
  assign m_axi_arid = ID_W'(RD_ID);
  assign m_axi_araddr = ar_addr;
  assign m_axi_arlen = 8'(BEATS - 1);
  assign m_axi_arsize = 3'(OFF);
  assign m_axi_arburst = 2'b01;
  assign m_axi_arvalid = ar_v;
  assign m_axi_rready = fill;
  // not used: the responses and RLAST (see the header; the beats are counted), the queue level (q_rdy is
  // its full flag)
  wire unused_ok = &{1'b0, m_axi_bid, m_axi_bresp, m_axi_rid, m_axi_rresp, m_axi_rlast, q_lvl, 1'b0};
endmodule
