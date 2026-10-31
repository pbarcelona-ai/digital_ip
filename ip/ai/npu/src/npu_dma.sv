// ***************
// Filename: npu_dma.sv
// Author: FPGA Cores 4 U
// Description: Byte-addressed DMA of the NPU on one AXI4 master port
//   (256-bit data). Version 1.1.0. Checked by tb/python npu_dma_tb.py
//   against a byte-array memory (every byte read / written).
//   - Read (rd_req_i with rd_ready_o: rd_addr_i, rd_len_i bytes, >= 1): the
//     bytes come back as 32-byte chunks aligned to the first requested byte
//     (rd_data_o byte 0 = the byte at rd_addr_i), rd_cnt_o bytes valid (32,
//     the last chunk the rest), rd_last_o on the last, rd_valid_o / rd_rdy_i
//     handshake. AXI: INCR bursts of up to 16 full-width beats that never
//     cross 4 KB, issued ahead of the data; RREADY while the output register
//     can take the next chunk. Up to RQ requests are queued: their bursts
//     are issued one request after the other while the data of the earlier
//     ones still comes back, and each request's chunks follow the previous
//     request's last one (in request order). rd_ready_o: the queue has room.
//   - Write (wr_req_i with wr_ready_o: wr_addr_i, wr_len_i bytes, >= 1):
//     chunks in on wr_data_i / wr_cnt_i (byte 0 first; every chunk 32 bytes
//     except the last) with wr_valid_i / wr_rdy_o; the bytes are placed at
//     wr_addr_i on, full-width beats with strobes for the bytes written;
//     bursts as for reads, AW issued ahead of W. wr_done_o pulses when every
//     B of the request has come back; wr_ready_o: no write active (also
//     high again after wr_done_o).
//   - Posted writes (wr_post_i with the request): wr_done_o pulses once every
//     beat and address of the request is sent, its B responses still
//     outstanding (counted); the next posted write can start at once. A
//     write that is not posted waits (wr_ready_o low) until every posted B is
//     back; reads do not wait: the caller keeps them off the bytes of posted
//     writes still owed (npu.sv: an operation ends only at wr_idle_o, and
//     CONV's reads and writes are of different tensors). wr_idle_o: no
//     posted write active or outstanding.
//   Reads and writes run independently otherwise (the caller orders them: a
//   read of bytes just written waits for wr_done_o). RRESP / BRESP are not
//   checked.
//   Parameters: ADDR_W (AXI byte address), ID_W, RD_ID / WR_ID, RQ (read
//   requests queued, a power of two >= 2).
//   Clock - clk. Reset - synchronous active low rst_n (the controller's
//   reset: no transaction abandoned). Clock-domain crossings - none.
// Date: 2026-10-26
module npu_dma #(
  parameter int ADDR_W = 32,                     // AXI byte address bits
  parameter int ID_W   = 4,                      // AXI ID bits
  parameter int RD_ID  = 2,                      // ARID
  parameter int WR_ID  = 3,                      // AWID
  parameter int RQ     = 8                       // read requests queued
) (
  input  logic                clk,               // clock
  input  logic                rst_n,             // synchronous, active low
  // read request and data
  input  logic                rd_req_i,          // start a read (taken with rd_ready_o)
  output logic                rd_ready_o,        // a read request can be taken (the queue has room)
  input  logic [ADDR_W-1:0]   rd_addr_i,         // first byte
  input  logic [31:0]         rd_len_i,          // bytes (>= 1)
  output logic                rd_valid_o,        // a chunk
  input  logic                rd_rdy_i,          // the chunk taken
  output logic [255:0]        rd_data_o,         // byte 0 first
  output logic [5:0]          rd_cnt_o,          // bytes in the chunk (1 .. 32)
  output logic                rd_last_o,         // the last chunk
  // write request and data
  input  logic                wr_req_i,          // start a write (taken with wr_ready_o)
  input  logic                wr_post_i,         // with wr_req_i: a posted write (done before its B)
  output logic                wr_ready_o,        // no write active (not posted: no posted B outstanding)
  input  logic [ADDR_W-1:0]   wr_addr_i,         // first byte
  input  logic [31:0]         wr_len_i,          // bytes (>= 1)
  input  logic                wr_valid_i,        // a chunk
  output logic                wr_rdy_o,          // the chunk taken
  input  logic [255:0]        wr_data_i,         // byte 0 first
  input  logic [5:0]          wr_cnt_i,          // bytes in the chunk (32, the last chunk 1 .. 32)
  output logic                wr_done_o,         // one clock: every byte of the write is in memory (posted: sent)
  output logic                wr_idle_o,         // no posted write active or outstanding
  // AXI4 master
  output logic [ID_W-1:0]     m_axi_awid,        // write address channel
  output logic [ADDR_W-1:0]   m_axi_awaddr,
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
  input  logic [ID_W-1:0]     m_axi_bid,         // write response channel (not checked)
  input  logic [1:0]          m_axi_bresp,
  input  logic                m_axi_bvalid,
  output logic                m_axi_bready,
  output logic [ID_W-1:0]     m_axi_arid,        // read address channel
  output logic [ADDR_W-1:0]   m_axi_araddr,
  output logic [7:0]          m_axi_arlen,
  output logic [2:0]          m_axi_arsize,
  output logic [1:0]          m_axi_arburst,
  output logic                m_axi_arvalid,
  input  logic                m_axi_arready,
  input  logic [ID_W-1:0]     m_axi_rid,         // read data channel (ID, RRESP, RLAST not checked)
  input  logic [255:0]        m_axi_rdata,
  input  logic [1:0]          m_axi_rresp,
  input  logic                m_axi_rlast,
  input  logic                m_axi_rvalid,
  output logic                m_axi_rready
);
  localparam int BW = ADDR_W - 5;                // beat (32-byte word) address bits

  // the beats of the burst starting at beat b (its position in the 4 KB page: b[6:0]) with n beats left:
  // at most 16, not across 4 KB (128 beats)
  function automatic logic [4:0] burst_len(input logic [6:0] b, input logic [32:0] n);
    logic [7:0] to4k;
    to4k = 8'd128 - 8'(b);
    burst_len = 5'(n < 33'(16) ? n : 33'd16);
    if (33'(to4k) < 33'(burst_len)) burst_len = 5'(to4k);
  endfunction

  // ================================================================ read
  localparam int QA = $clog2(RQ);
  if (RQ < 2 || (RQ & (RQ - 1)) != 0) begin : g_bad_rq
    $error("npu_dma: RQ a power of two >= 2");
  end
  // the request queue: written at q_wp, its bursts issued from q_ap, its data delivered from q_rp
  logic [BW-1:0]   q_beat [RQ];                  // first beat
  logic [32:0]     q_beats [RQ];                 // beats
  logic [4:0]      q_off [RQ];                   // the first byte's offset in its beat
  logic [32:0]     q_len [RQ];                   // bytes
  logic [QA:0]     q_wp, q_ap, q_rp;
  wire             q_full = q_wp - q_rp == (QA+1)'(RQ);
  // address side: the bursts of request q_ap
  logic            a_act;                        // a request's bursts being issued
  logic [BW-1:0]   ar_beat;                      // next beat to request
  logic [32:0]     ar_left;                      // beats still to request
  logic            ar_v;
  logic [4:0]      ar_n;
  // data side: request q_rp
  logic            r_act;                        // a request's data being delivered
  logic [32:0]     rx_left;                      // beats still to receive
  logic [4:0]      roff;                         // the first byte's offset in its beat
  logic [32:0]     out_left;                     // bytes still to output
  logic [255:0]    prev;
  logic            have_prev, flush;
  logic            o_v, o_last;
  logic [255:0]    o_data;
  logic [5:0]      o_cnt;
  wire  [32:0]     rd_beats = 33'((33'(rd_addr_i[4:0]) + 33'(rd_len_i) + 33'd31) >> 5);
  wire             o_free = !o_v || rd_rdy_i;
  wire             r_take = m_axi_rvalid && m_axi_rready;
  // the chunk the current state yields: aligned beat, two beats, or the last beat alone
  wire  [511:0]    pair = r_take ? {m_axi_rdata, prev} : {256'd0, prev};
  wire  [255:0]    shifted = 256'(pair >> (8 * roff));
  wire  [5:0]      cnt_now = (out_left > 33'd32) ? 6'd32 : 6'(out_left);
  assign m_axi_rready = r_act && rx_left != '0 && o_free && !flush;
  logic            post_busy;                    // a posted write active or its B outstanding (write side)
  assign rd_ready_o = !q_full;
  wire             q_push = rd_req_i && rd_ready_o;
  wire             r_end = r_act && out_left == '0 && !flush && rx_left == '0;   // the request's last chunk out
  always_ff @(posedge clk) begin
    if (q_push) begin
      q_beat[QA'(q_wp)] <= rd_addr_i[ADDR_W-1:5];
      q_beats[QA'(q_wp)] <= rd_beats;
      q_off[QA'(q_wp)] <= rd_addr_i[4:0];
      q_len[QA'(q_wp)] <= 33'(rd_len_i);
    end
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      q_wp <= '0;
      q_ap <= '0;
      q_rp <= '0;
      a_act <= 1'b0;
      ar_beat <= '0;
      ar_left <= '0;
      ar_v <= 1'b0;
      ar_n <= '0;
      r_act <= 1'b0;
      rx_left <= '0;
      roff <= '0;
      out_left <= '0;
      prev <= '0;
      have_prev <= 1'b0;
      flush <= 1'b0;
      o_v <= 1'b0;
      o_last <= 1'b0;
      o_data <= '0;
      o_cnt <= '0;
    end else begin
      if (o_v && rd_rdy_i) o_v <= 1'b0;
      if (q_push) q_wp <= q_wp + 1'b1;
      // address channel: one burst presented at a time, issued ahead of the data, request after request
      if (!a_act) begin
        if (q_ap != q_wp) begin
          a_act <= 1'b1;
          ar_beat <= q_beat[QA'(q_ap)];
          ar_left <= q_beats[QA'(q_ap)];
        end
      end else if (ar_v) begin
        if (m_axi_arready) begin
          ar_v <= 1'b0;
          ar_beat <= ar_beat + BW'(ar_n);
          ar_left <= ar_left - 33'(ar_n);
        end
      end else if (ar_left != '0) begin
        ar_v <= 1'b1;
        ar_n <= burst_len(ar_beat[6:0], ar_left);
      end else begin                             // every burst of the request issued
        a_act <= 1'b0;
        q_ap <= q_ap + 1'b1;
      end
      // data: realign into chunks, request after request
      if (!r_act) begin
        if (q_rp != q_ap || a_act) begin         // a request whose bursts are (being) issued
          r_act <= 1'b1;
          rx_left <= q_beats[QA'(q_rp)];
          roff <= q_off[QA'(q_rp)];
          out_left <= q_len[QA'(q_rp)];
          have_prev <= 1'b0;
          flush <= 1'b0;
        end
      end else if (r_end) begin
        r_act <= 1'b0;
        q_rp <= q_rp + 1'b1;
      end else if (r_take) begin
        rx_left <= rx_left - 33'd1;
        prev <= m_axi_rdata;
        have_prev <= 1'b1;
        if (roff == '0 || have_prev) begin       // a chunk complete (aligned, or this beat ends it)
          o_v <= 1'b1;
          o_data <= (roff == '0) ? m_axi_rdata : shifted;
          o_cnt <= cnt_now;
          o_last <= out_left <= 33'd32;
          out_left <= out_left - 33'(cnt_now);
          // the last beat holds more bytes than this chunk took: one more chunk from it alone
          flush <= roff != '0 && rx_left == 33'd1 && out_left > 33'd32;
        end else if (rx_left == 33'd1) begin     // a single beat: its bytes are the whole chunk
          flush <= 1'b1;
        end
      end else if (flush && o_free) begin
        flush <= 1'b0;
        o_v <= 1'b1;
        o_data <= shifted;
        o_cnt <= cnt_now;
        o_last <= 1'b1;
        out_left <= '0;
      end
    end
  end
  assign m_axi_arid = ID_W'(RD_ID);
  assign m_axi_araddr = {ar_beat, 5'd0};
  assign m_axi_arlen = 8'(ar_n - 5'd1);
  assign m_axi_arsize = 3'd5;
  assign m_axi_arburst = 2'b01;
  assign m_axi_arvalid = ar_v;
  assign rd_valid_o = o_v;
  assign rd_data_o = o_data;
  assign rd_cnt_o = o_cnt;
  assign rd_last_o = o_last;

  // ================================================================ write
  logic            wr_busy, wdone;
  logic [BW-1:0]   aw_beat, w_beat;              // next beat: to announce / to send
  logic [32:0]     aw_left, w_left;              // beats still to announce / to send
  logic            aw_v;
  logic [4:0]      aw_n, w_n;                    // the burst's beats (W: still to send in the burst)
  logic [32:0]     b_left;                       // bursts announced, B not yet back (a write not posted)
  logic [32:0]     b_post;                       // posted bursts announced, B not yet back
  logic            post_q;                       // the active write is posted
  logic [32:0]     in_left;                      // bytes still to take
  logic [511:0]    st_d;                         // staging: two beats
  logic [63:0]     st_s;                         // their strobes
  logic [5:0]      st_pos;                       // the next byte's position in the staging
  logic            w_v;
  logic [255:0]    w_d;
  logic [31:0]     w_s;
  logic            w_l;
  wire  [32:0]     wr_beats = 33'((33'(wr_addr_i[4:0]) + 33'(wr_len_i) + 33'd31) >> 5);
  wire             w_free = !w_v || m_axi_wready;
  wire             in_take = wr_valid_i && wr_rdy_o;
  // a beat is ready in the staging: full, or the last one once every byte is in
  wire             st_full = st_pos >= 6'd32;
  wire             st_end = in_left == '0 && st_pos != '0;
  wire             emit = wr_busy && w_free && w_left != '0 && (st_full || st_end) && w_n != '0;
  assign wr_rdy_o = wr_busy && in_left != '0 && !st_full;
  // the staging's next state: a beat out shifts it by 32 bytes; a chunk in lands at st_pos (never both in
  // one clock: a full staging takes no chunk, a chunk is taken only before the end)
  logic [511:0] st_d_n;
  logic [63:0]  st_s_n;
  logic [5:0]   st_pos_n;
  always_comb begin
    st_d_n = st_d;
    st_s_n = st_s;
    st_pos_n = st_pos;
    if (emit) begin
      st_d_n = {256'd0, st_d[511:256]};
      st_s_n = {32'd0, st_s[63:32]};
      st_pos_n = (st_pos >= 6'd32) ? st_pos - 6'd32 : 6'd0;
    end else if (in_take) begin
      // the chunk's bytes past wr_cnt_i (a last chunk) are not taken: zero (no undefined bytes in W)
      st_d_n = st_d | (512'(wr_data_i & 256'((257'd1 << (8 * wr_cnt_i)) - 257'd1)) << (8 * st_pos));
      st_s_n = st_s | (64'((64'd1 << wr_cnt_i) - 64'd1) << st_pos);
      st_pos_n = st_pos + wr_cnt_i;
    end
  end
  assign wr_ready_o = !wr_busy && (wr_post_i || b_post == '0);
  // outstanding B responses are either all posted or all of the active write: a write that is not posted
  // starts only with no posted B outstanding, a posted one only after the write before it is done
  assign post_busy = b_post != '0 || (wr_busy && post_q);
  assign wr_idle_o = !post_busy;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_busy <= 1'b0;
      wdone <= 1'b0;
      aw_beat <= '0;
      w_beat <= '0;
      aw_left <= '0;
      w_left <= '0;
      aw_v <= 1'b0;
      aw_n <= '0;
      w_n <= '0;
      b_left <= '0;
      b_post <= '0;
      post_q <= 1'b0;
      in_left <= '0;
      st_d <= '0;
      st_s <= '0;
      st_pos <= '0;
      w_v <= 1'b0;
      w_d <= '0;
      w_s <= '0;
      w_l <= 1'b0;
    end else begin
      wdone <= 1'b0;
      if (w_v && m_axi_wready) w_v <= 1'b0;
      // posted bursts: counted from their AW to their B (posted B's come before any later write's)
      b_post <= b_post + 33'(aw_v && m_axi_awready && post_q) - 33'(m_axi_bvalid && b_post != '0);
      if (!wr_busy) begin
        if (wr_req_i && wr_ready_o) begin
          wr_busy <= 1'b1;
          post_q <= wr_post_i;
          aw_beat <= wr_addr_i[ADDR_W-1:5];
          w_beat <= wr_addr_i[ADDR_W-1:5];
          aw_left <= wr_beats;
          w_left <= wr_beats;
          w_n <= burst_len(wr_addr_i[11:5], wr_beats);
          b_left <= '0;
          in_left <= 33'(wr_len_i);
          st_d <= '0;
          st_s <= '0;
          st_pos <= 6'(wr_addr_i[4:0]);
        end
      end else begin
        // address channel
        if (aw_v) begin
          if (m_axi_awready) begin
            aw_v <= 1'b0;
            aw_beat <= aw_beat + BW'(aw_n);
            aw_left <= aw_left - 33'(aw_n);
          end
        end else if (aw_left != '0) begin
          aw_v <= 1'b1;
          aw_n <= burst_len(aw_beat[6:0], aw_left);
        end
        // staging: a chunk in or a beat out (st_*_n below)
        if (emit) begin
          w_v <= 1'b1;
          w_d <= st_d[255:0];
          w_s <= st_s[31:0];
          w_l <= w_n == 5'd1;
          w_beat <= w_beat + 1'b1;
          w_left <= w_left - 33'd1;
          w_n <= (w_n == 5'd1) ? burst_len(7'(w_beat + 1'b1), w_left - 33'd1) : w_n - 5'd1;
        end
        if (in_take) in_left <= in_left - 33'(wr_cnt_i);
        st_d <= st_d_n;
        st_s <= st_s_n;
        st_pos <= st_pos_n;
        // responses (a write not posted: its own; posted ones are counted in b_post)
        b_left <= b_left + 33'(aw_v && m_axi_awready && !post_q) - 33'(m_axi_bvalid && b_post == '0);
        if (aw_left == '0 && !aw_v && w_left == '0 && !w_v && (post_q || b_left == '0) && in_left == '0) begin
          wr_busy <= 1'b0;
          wdone <= 1'b1;
        end
      end
    end
  end
  assign m_axi_awid = ID_W'(WR_ID);
  assign m_axi_awaddr = {aw_beat, 5'd0};
  assign m_axi_awlen = 8'(aw_n - 5'd1);
  assign m_axi_awsize = 3'd5;
  assign m_axi_awburst = 2'b01;
  assign m_axi_awvalid = aw_v;
  assign m_axi_wdata = w_d;
  assign m_axi_wstrb = w_s;
  assign m_axi_wlast = w_l;
  assign m_axi_wvalid = w_v;
  assign m_axi_bready = 1'b1;
  assign wr_done_o = wdone;
  // not used: the responses, RLAST (the beats are counted)
  wire unused_ok = &{1'b0, m_axi_bid, m_axi_bresp, m_axi_rid, m_axi_rresp, m_axi_rlast, 1'b0};
endmodule
