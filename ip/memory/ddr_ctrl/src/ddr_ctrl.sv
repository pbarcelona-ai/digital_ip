// ***************
// Filename: ddr_ctrl.sv
// Author: FPGA Cores 4 U
// Description: Generic DDR controller: NPORTS AXI4 slave ports in front of a
//   DFI-style command interface (ddr_mem's: one command per clock, read data
//   T_CL clocks after RD). Version 1.0.0. Golden model:
//   model/ddr_ctrl_model.py (clock exact; tb/python, with ddr_mem).
//   - AXI4: full-width transfers (AxSIZE = log2(DATA_W/8)), INCR bursts of up
//     to 256 beats, IDs passed through, the low address bits below a word
//     ignored, WLAST not checked (AxLEN counts the beats). Another size or
//     burst type answers SLVERR, a burst reaching beyond the memory
//     (2**(BANK_W+ROW_W+COL_W) words) DECERR; an error burst touches no memory
//     (reads return 0, writes take their W beats).
//   - Address map: word w = addr >> log2(DATA_W/8); col = w[COL_W-1:0], bank
//     the next BANK_W bits, row the next ROW_W bits (row-bank-column).
//   - One burst at a time, beats in order. Each clock, in this order: (1) a
//     refresh owed: PREA once every open bank is past T_RAS / T_WR / T_RTP,
//     REF once every bank is closed and past T_RP (both T_RFC after a REF),
//     nothing else; (2) a burst: an error beat per clock (read with credit,
//     write with WVALID), or for the beat's bank / row (not within T_RFC of a
//     REF): a hit past T_RCD issues RD (past T_WTR, with read credit) or WR
//     (WVALID: WREADY, write data to the memory), another open row PRE (past
//     T_RAS / T_WR / T_RTP), a closed bank ACT (past T_RP, T_RRD); (3) no
//     burst: the arbiter grants a request (ARREADY / AWREADY combinational on
//     the valid; index 2*port + write; a write only with room in its B FIFO;
//     PRIORITY 1 lowest index, 0 round robin after the last grant); the
//     burst starts the next clock.
//   - Refresh: every T_REFI clocks one more REF is owed (at most 15), each REF
//     takes one: on average one REF per T_REFI however late each is served.
//   - Reads: every read beat enters a T_CL-deep return pipe alongside the
//     memory and, at its end, its port's read FIFO (fallthrough_fifo,
//     RQ_DEPTH) with the memory word (0 for an error), ID, RRESP, RLAST; a read
//     beat needs credit (beats issued, not yet taken by RREADY) < RQ_DEPTH.
//     Writes: the last beat pushes {BID, BRESP} into the port's B FIFO.
//   - Statistics (32-bit, wrapping, the regs port's sts_*): read beats, write beats, ACTs, row
//     hits (memory beats issued without an ACT for that beat), REFs, error
//     bursts; CTRL[0] written with 1 clears them (an event in that clock is
//     not counted). STATUS: [0] a burst active, [4:1] refreshes owed.
//   Register map: src/include/ddr_ctrl_regs.json (ddr_ctrl_top.sv joins it,
//     ID "DDRC", to the regs port, ddr_ctrl_regs_if).
//   The bank state and timing ages are ddr_mem's (saturating at 255), so the
//   controller keeps every timing rule.
//   Parameters: NPORTS (1 ..), DATA_W, ADDR_W, ID_W, BANK_W, ROW_W, COL_W, the
//   timings in clocks (1 .. 254; T_REFI >= 2), PRIORITY, RQ_DEPTH, BQ_DEPTH
//   (powers of two, 2 .. 64).
//   Clock - clk (AXI and DFI). Reset - synchronous active low rst_n.
//   Clock-domain crossings - none. Latency - a read beat T_CL + 1 clocks from
//   RD to RVALID; a burst starts the clock after its grant.
// Date: 2026-10-21
module ddr_ctrl #(
  parameter int NPORTS   = 2,
  parameter int DATA_W   = 256,
  parameter int ADDR_W   = 32,
  parameter int ID_W     = 4,
  parameter int BANK_W   = 3,
  parameter int ROW_W    = 14,
  parameter int COL_W    = 8,
  parameter int T_RCD    = 4,
  parameter int T_RP     = 4,
  parameter int T_RAS    = 10,
  parameter int T_CL     = 5,
  parameter int T_WR     = 4,
  parameter int T_RTP    = 2,
  parameter int T_WTR    = 2,
  parameter int T_RRD    = 2,
  parameter int T_RFC    = 30,
  parameter int T_REFI   = 1950,
  parameter int PRIORITY = 0,                  // 0 round robin, 1 fixed (lowest index first)
  parameter int RQ_DEPTH = 16,                 // read FIFO words per port
  parameter int BQ_DEPTH = 2                   // write responses per port
) (
  input  logic                       clk,             // clock
  input  logic                       rst_n,           // synchronous, active low
  // AXI4 slave ports, packed by port (port p in bits [p*W +: W])
  input  logic [NPORTS*ID_W-1:0]     s_axi_awid,      // write address channel
  input  logic [NPORTS*ADDR_W-1:0]   s_axi_awaddr,
  input  logic [NPORTS*8-1:0]        s_axi_awlen,
  input  logic [NPORTS*3-1:0]        s_axi_awsize,
  input  logic [NPORTS*2-1:0]        s_axi_awburst,
  input  logic [NPORTS-1:0]          s_axi_awvalid,
  output logic [NPORTS-1:0]          s_axi_awready,
  input  logic [NPORTS*DATA_W-1:0]   s_axi_wdata,     // write data channel
  input  logic [NPORTS*DATA_W/8-1:0] s_axi_wstrb,
  input  logic [NPORTS-1:0]          s_axi_wlast,     // not checked
  input  logic [NPORTS-1:0]          s_axi_wvalid,
  output logic [NPORTS-1:0]          s_axi_wready,
  output logic [NPORTS*ID_W-1:0]     s_axi_bid,       // write response channel
  output logic [NPORTS*2-1:0]        s_axi_bresp,
  output logic [NPORTS-1:0]          s_axi_bvalid,
  input  logic [NPORTS-1:0]          s_axi_bready,
  input  logic [NPORTS*ID_W-1:0]     s_axi_arid,      // read address channel
  input  logic [NPORTS*ADDR_W-1:0]   s_axi_araddr,
  input  logic [NPORTS*8-1:0]        s_axi_arlen,
  input  logic [NPORTS*3-1:0]        s_axi_arsize,
  input  logic [NPORTS*2-1:0]        s_axi_arburst,
  input  logic [NPORTS-1:0]          s_axi_arvalid,
  output logic [NPORTS-1:0]          s_axi_arready,
  output logic [NPORTS*ID_W-1:0]     s_axi_rid,       // read data channel
  output logic [NPORTS*DATA_W-1:0]   s_axi_rdata,
  output logic [NPORTS*2-1:0]        s_axi_rresp,
  output logic [NPORTS-1:0]          s_axi_rlast,
  output logic [NPORTS-1:0]          s_axi_rvalid,
  input  logic [NPORTS-1:0]          s_axi_rready,
  // DFI-style command interface (ddr_mem)
  output logic [2:0]                 dfi_cmd_o,       // 0 NOP 1 ACT 2 RD 3 WR 4 PRE 5 PREA 6 REF
  output logic [BANK_W-1:0]          dfi_bank_o,
  output logic [ROW_W-1:0]           dfi_row_o,
  output logic [COL_W-1:0]           dfi_col_o,
  output logic [DATA_W-1:0]          dfi_wrdata_o,
  output logic [DATA_W/8-1:0]        dfi_wrstrb_o,
  input  logic                       dfi_rddata_valid_i,   // the memory's read word (T_CL after RD)
  input  logic [DATA_W-1:0]          dfi_rddata_i,
  // registers: CTRL (cfg_ctrl / cfg_ctrl_wr: clear the statistics), STATUS, RD_BEATS, WR_BEATS, ACTS, HITS,
  // REFS, ERRS (sts_*); ddr_ctrl_top.sv joins the register map src/include/ddr_ctrl_regs.sv
  // regs: ddr_ctrl_regs_if.core (src/include/ddr_ctrl_regs_if.sv)
  ddr_ctrl_regs_if.core regs
);
  localparam int NB      = 1 << BANK_W;
  localparam int AGE_MAX = 255;
  localparam int OFF     = $clog2(DATA_W / 8);
  localparam int WAW     = ADDR_W - OFF;               // word address bits
  localparam int MW      = BANK_W + ROW_W + COL_W;     // memory word address bits
  localparam int NREQ    = 2 * NPORTS;
  localparam int RQW     = DATA_W + ID_W + 3;
  localparam int CRW     = $clog2(RQ_DEPTH) + 1;
  localparam int PW      = $clog2(NPORTS > 1 ? NPORTS : 2);   // port index bits
  localparam int GW      = $clog2(NREQ);                      // request index bits
  localparam logic [2:0] C_NOP = 3'd0, C_ACT = 3'd1, C_RD = 3'd2, C_WR = 3'd3, C_PRE = 3'd4, C_PREA = 3'd5,
                         C_REF = 3'd6;
  localparam logic [1:0] R_OKAY = 2'd0, R_SLVERR = 2'd2, R_DECERR = 2'd3;
  if (T_RCD < 1 || T_RCD >= AGE_MAX || T_RP < 1 || T_RP >= AGE_MAX || T_RAS < 1 || T_RAS >= AGE_MAX ||
      T_CL < 1 || T_CL >= AGE_MAX || T_WR < 1 || T_WR >= AGE_MAX || T_RTP < 1 || T_RTP >= AGE_MAX ||
      T_WTR < 1 || T_WTR >= AGE_MAX || T_RRD < 1 || T_RRD >= AGE_MAX || T_RFC < 1 || T_RFC >= AGE_MAX ||
      T_REFI < 2 || NPORTS < 1 || MW > WAW || DATA_W < 8 || (DATA_W & (DATA_W - 1)) != 0) begin : g_bad
    $error("ddr_ctrl: timings 1 .. 254, T_REFI >= 2, DATA_W a power of two, the memory within ADDR_W");
  end

  // ---------------- bank state and timing ages (as ddr_mem)
  logic [NB-1:0]    open_q;
  logic [ROW_W-1:0] row_q [NB];
  logic [7:0]       age_act [NB], age_pre [NB], age_wr [NB], age_rd [NB];
  logic [7:0]       g_act, g_wr, g_ref;
  logic [$clog2(T_REFI)-1:0] ref_timer;
  logic [3:0]       owed;

  // ---------------- the burst
  logic              busy, dir_q, beat_act;
  logic [PW-1:0] port_q;
  logic [ID_W-1:0]   id_q;
  logic [WAW-1:0]    word_q;
  logic [8:0]        left_q;
  logic [1:0]        resp_q;
  logic [GW-1:0]    last_grant;

  // ---------------- per port: read credit, FIFO levels
  logic [CRW-1:0]    cred [NPORTS];
  logic [$clog2(BQ_DEPTH):0] bq_lvl [NPORTS];

  function automatic logic [7:0] sat(input logic [7:0] a);
    sat = (a == 8'(AGE_MAX)) ? a : a + 8'd1;
  endfunction
  function automatic logic pre_ok(input logic [7:0] a_act, input logic [7:0] a_wr, input logic [7:0] a_rd);
    pre_ok = a_act >= 8'(T_RAS) && a_wr >= 8'(T_WR) && a_rd >= 8'(T_RTP);
  endfunction

  // ---------------- this clock's decision
  wire [BANK_W-1:0] cur_bank = word_q[COL_W +: BANK_W];
  wire [ROW_W-1:0]  cur_row  = word_q[COL_W + BANK_W +: ROW_W];
  wire [COL_W-1:0]  cur_col  = word_q[COL_W-1:0];
  logic             any_open, all_pre_ok, all_rp;
  logic             beat, rbeat, grant_v;
  logic [GW-1:0]    grant;
  logic [NREQ-1:0]  req;
  logic [GW-1:0]    arb_idx;                    // arbitration loop index (0 .. NREQ-1)
  always_comb begin
    arb_idx = '0;
    any_open = open_q != '0;
    all_pre_ok = 1'b1;
    all_rp = 1'b1;
    for (int b = 0; b < NB; b++) begin
      if (open_q[b] && !pre_ok(age_act[b], age_wr[b], age_rd[b])) all_pre_ok = 1'b0;
      if (age_pre[b] < 8'(T_RP)) all_rp = 1'b0;
    end
    for (int p = 0; p < NPORTS; p++) begin
      req[2*p]     = s_axi_arvalid[p];
      req[2*p + 1] = s_axi_awvalid[p] && bq_lvl[p] < ($clog2(BQ_DEPTH)+1)'(BQ_DEPTH);
    end
    dfi_cmd_o = C_NOP;
    dfi_bank_o = '0;
    dfi_row_o = '0;
    dfi_col_o = '0;
    dfi_wrdata_o = '0;
    dfi_wrstrb_o = '0;
    s_axi_arready = '0;
    s_axi_awready = '0;
    s_axi_wready = '0;
    beat = 1'b0;
    rbeat = 1'b0;
    grant_v = 1'b0;
    grant = '0;
    if (owed != '0) begin
      if (g_ref >= 8'(T_RFC)) begin
        if (any_open && all_pre_ok) dfi_cmd_o = C_PREA;
        else if (!any_open && all_rp) dfi_cmd_o = C_REF;
      end
    end else if (busy) begin
      if (resp_q != R_OKAY) begin
        if (!dir_q && cred[port_q] < CRW'(RQ_DEPTH)) begin
          beat = 1'b1;
          rbeat = 1'b1;
        end else if (dir_q && s_axi_wvalid[port_q]) begin
          beat = 1'b1;
          s_axi_wready[port_q] = 1'b1;
        end
      end else if (g_ref >= 8'(T_RFC)) begin
        if (open_q[cur_bank] && row_q[cur_bank] == cur_row) begin
          if (age_act[cur_bank] >= 8'(T_RCD)) begin
            if (!dir_q) begin
              if (g_wr >= 8'(T_WTR) && cred[port_q] < CRW'(RQ_DEPTH)) begin
                dfi_cmd_o = C_RD;
                dfi_bank_o = cur_bank;
                dfi_col_o = cur_col;
                beat = 1'b1;
                rbeat = 1'b1;
              end
            end else if (s_axi_wvalid[port_q]) begin
              dfi_cmd_o = C_WR;
              dfi_bank_o = cur_bank;
              dfi_col_o = cur_col;
              dfi_wrdata_o = s_axi_wdata[port_q*DATA_W +: DATA_W];
              dfi_wrstrb_o = s_axi_wstrb[port_q*DATA_W/8 +: DATA_W/8];
              beat = 1'b1;
              s_axi_wready[port_q] = 1'b1;
            end
          end
        end else if (open_q[cur_bank]) begin
          if (pre_ok(age_act[cur_bank], age_wr[cur_bank], age_rd[cur_bank])) begin
            dfi_cmd_o = C_PRE;
            dfi_bank_o = cur_bank;
          end
        end else if (age_pre[cur_bank] >= 8'(T_RP) && g_act >= 8'(T_RRD)) begin
          dfi_cmd_o = C_ACT;
          dfi_bank_o = cur_bank;
          dfi_row_o = cur_row;
        end
      end
    end else begin
      for (int k = NREQ - 1; k >= 0; k--) begin   // the first eligible index in arbitration order
        arb_idx = GW'((PRIORITY != 0) ? k : (int'(last_grant) + 1 + k) % NREQ);
        if (req[arb_idx]) begin
          grant_v = 1'b1;
          grant = arb_idx;
        end
      end
      if (grant_v) begin
        if (grant[0]) s_axi_awready[g_port] = 1'b1;
        else s_axi_arready[g_port] = 1'b1;
      end
    end
  end

  // the granted request's fields
  wire              g_wr_req = grant[0];
  wire [PW-1:0] g_port = PW'(grant >> 1);
  wire [ADDR_W-1:0] g_addr  = g_wr_req ? s_axi_awaddr[g_port*ADDR_W +: ADDR_W] : s_axi_araddr[g_port*ADDR_W +: ADDR_W];
  wire [7:0]        g_len   = g_wr_req ? s_axi_awlen[g_port*8 +: 8] : s_axi_arlen[g_port*8 +: 8];
  wire [2:0]        g_size  = g_wr_req ? s_axi_awsize[g_port*3 +: 3] : s_axi_arsize[g_port*3 +: 3];
  wire [1:0]        g_burst = g_wr_req ? s_axi_awburst[g_port*2 +: 2] : s_axi_arburst[g_port*2 +: 2];
  wire [ID_W-1:0]   g_id    = g_wr_req ? s_axi_awid[g_port*ID_W +: ID_W] : s_axi_arid[g_port*ID_W +: ID_W];
  wire [WAW-1:0]    g_word  = g_addr[ADDR_W-1:OFF];
  wire [WAW:0]      g_end   = {1'b0, g_word} + (WAW+1)'(g_len);
  wire [1:0]        g_resp  = (g_size != 3'(OFF) || g_burst != 2'b01) ? R_SLVERR :
                              (g_end >= (WAW+1)'(1) << MW) ? R_DECERR : R_OKAY;

  // ---------------- read return pipe (alongside the memory's T_CL)
  logic                 pv [T_CL];
  logic [PW-1:0] pport [T_CL];
  logic [ID_W-1:0]      pid [T_CL];
  logic                 plast [T_CL], pmem [T_CL];
  logic [1:0]           presp [T_CL];
  wire                  last_beat = (left_q == 9'd1);

  // ---------------- per-port FIFOs
  logic [NPORTS-1:0] rpop;
  for (genvar p = 0; p < NPORTS; p++) begin : g_port_fifos
    logic           rq_push, rq_rdy, bq_push, bq_rdy;
    logic [RQW-1:0] rq_in, rq_out;
    logic [ID_W+1:0] bq_out;
    logic [CRW-1:0] rq_lvl;
    assign rq_push = pv[T_CL-1] && pport[T_CL-1] == p;
    assign rq_in   = {plast[T_CL-1], presp[T_CL-1], pid[T_CL-1], pmem[T_CL-1] ? dfi_rddata_i : '0};
    fallthrough_fifo #(
      .WIDTH(RQW),
      .DEPTH(RQ_DEPTH)
    ) u_rq (
      .clk,
      .rst_n,
      .s_data_i(rq_in),
      .s_valid_i(rq_push),
      .s_ready_o(rq_rdy),
      .m_data_o(rq_out),
      .m_valid_o(s_axi_rvalid[p]),
      .m_ready_i(s_axi_rready[p]),
      .level_o(rq_lvl)
    );
    assign s_axi_rdata[p*DATA_W +: DATA_W] = rq_out[DATA_W-1:0];
    assign s_axi_rid[p*ID_W +: ID_W]       = rq_out[DATA_W +: ID_W];
    assign s_axi_rresp[p*2 +: 2]           = rq_out[DATA_W + ID_W +: 2];
    assign s_axi_rlast[p]                  = rq_out[DATA_W + ID_W + 2];
    assign rpop[p] = s_axi_rvalid[p] && s_axi_rready[p];
    assign bq_push = beat && dir_q && port_q == PW'(p) && last_beat;
    fallthrough_fifo #(
      .WIDTH(ID_W + 2),
      .DEPTH(BQ_DEPTH)
    ) u_bq (
      .clk,
      .rst_n,
      .s_data_i({resp_q, id_q}),
      .s_valid_i(bq_push),
      .s_ready_o(bq_rdy),
      .m_data_o(bq_out),
      .m_valid_o(s_axi_bvalid[p]),
      .m_ready_i(s_axi_bready[p]),
      .level_o(bq_lvl[p])
    );
    assign s_axi_bid[p*ID_W +: ID_W] = bq_out[ID_W-1:0];
    assign s_axi_bresp[p*2 +: 2]     = bq_out[ID_W +: 2];
    // the credits keep both FIFOs from filling; the read level equals the credit minus the pipe
    wire unused_fifo = &{1'b0, rq_rdy, bq_rdy, rq_lvl, 1'b0};
  end

  // statistics (STATUS and the counters) and their clear
  logic [31:0] stat_rd_beats, stat_wr_beats, stat_acts, stat_hits, stat_refs, stat_errs;
  wire stat_clr = regs.cfg_ctrl_wr && regs.cfg_ctrl;
  assign regs.sts_status   = {owed, busy};
  assign regs.sts_rd_beats = stat_rd_beats;
  assign regs.sts_wr_beats = stat_wr_beats;
  assign regs.sts_acts     = stat_acts;
  assign regs.sts_hits     = stat_hits;
  assign regs.sts_refs     = stat_refs;
  assign regs.sts_errs     = stat_errs;

  // ---------------- state
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      open_q <= '0;
      for (int b = 0; b < NB; b++) begin
        row_q[b] <= '0;
        age_act[b] <= 8'(AGE_MAX);
        age_pre[b] <= 8'(AGE_MAX);
        age_wr[b] <= 8'(AGE_MAX);
        age_rd[b] <= 8'(AGE_MAX);
      end
      g_act <= 8'(AGE_MAX);
      g_wr <= 8'(AGE_MAX);
      g_ref <= 8'(AGE_MAX);
      ref_timer <= '0;
      owed <= '0;
      busy <= 1'b0;
      dir_q <= 1'b0;
      port_q <= '0;
      id_q <= '0;
      word_q <= '0;
      left_q <= '0;
      resp_q <= R_OKAY;
      beat_act <= 1'b0;
      last_grant <= GW'(NREQ - 1);
      for (int p = 0; p < NPORTS; p++) cred[p] <= '0;
      for (int s = 0; s < T_CL; s++) begin
        pv[s] <= 1'b0;
        pport[s] <= '0;
        pid[s] <= '0;
        plast[s] <= 1'b0;
        pmem[s] <= 1'b0;
        presp[s] <= R_OKAY;
      end
      stat_rd_beats <= '0;
      stat_wr_beats <= '0;
      stat_acts <= '0;
      stat_hits <= '0;
      stat_refs <= '0;
      stat_errs <= '0;
    end else begin
      // read credits
      for (int p = 0; p < NPORTS; p++)
        cred[p] <= cred[p] + CRW'(rbeat && port_q == PW'(p)) - CRW'(rpop[p]);
      // return pipe
      pv[0] <= rbeat;
      pport[0] <= port_q;
      pid[0] <= id_q;
      plast[0] <= last_beat;
      pmem[0] <= (resp_q == R_OKAY);
      presp[0] <= resp_q;
      for (int s = 1; s < T_CL; s++) begin
        pv[s] <= pv[s-1];
        pport[s] <= pport[s-1];
        pid[s] <= pid[s-1];
        plast[s] <= plast[s-1];
        pmem[s] <= pmem[s-1];
        presp[s] <= presp[s-1];
      end
      // statistics (CTRL[0] clears them)
      if (dfi_cmd_o == C_RD) stat_rd_beats <= stat_rd_beats + 32'd1;
      if (dfi_cmd_o == C_WR) stat_wr_beats <= stat_wr_beats + 32'd1;
      if ((dfi_cmd_o == C_RD || dfi_cmd_o == C_WR) && !beat_act) stat_hits <= stat_hits + 32'd1;
      if (dfi_cmd_o == C_ACT) stat_acts <= stat_acts + 32'd1;
      if (dfi_cmd_o == C_REF) stat_refs <= stat_refs + 32'd1;
      // bank state and ages
      for (int b = 0; b < NB; b++) begin
        age_act[b] <= sat(age_act[b]);
        age_pre[b] <= sat(age_pre[b]);
        age_wr[b] <= sat(age_wr[b]);
        age_rd[b] <= sat(age_rd[b]);
      end
      g_act <= sat(g_act);
      g_wr <= sat(g_wr);
      g_ref <= sat(g_ref);
      unique case (dfi_cmd_o)
        C_ACT: begin
          open_q[dfi_bank_o] <= 1'b1;
          row_q[dfi_bank_o] <= dfi_row_o;
          age_act[dfi_bank_o] <= '0;
          g_act <= '0;
        end
        C_WR: begin
          age_wr[dfi_bank_o] <= '0;
          g_wr <= '0;
        end
        C_RD: age_rd[dfi_bank_o] <= '0;
        C_PRE: begin
          open_q[dfi_bank_o] <= 1'b0;
          age_pre[dfi_bank_o] <= '0;
        end
        C_PREA: begin
          for (int b = 0; b < NB; b++) begin
            if (open_q[b]) begin
              open_q[b] <= 1'b0;
              age_pre[b] <= '0;
            end
          end
        end
        C_REF: g_ref <= '0;
        default: ;
      endcase
      // refresh schedule
      if (ref_timer == ($clog2(T_REFI))'(T_REFI - 1)) begin
        ref_timer <= '0;
        if (dfi_cmd_o != C_REF && owed != 4'd15) owed <= owed + 4'd1;
      end else begin
        ref_timer <= ref_timer + 1'b1;
        if (dfi_cmd_o == C_REF) owed <= owed - 4'd1;
      end
      // the burst: a beat, then a grant
      beat_act <= (dfi_cmd_o == C_ACT) ? 1'b1 : (beat ? 1'b0 : beat_act);
      if (beat) begin
        word_q <= word_q + 1'b1;
        left_q <= left_q - 9'd1;
        if (last_beat) busy <= 1'b0;
      end
      if (grant_v) begin
        busy <= 1'b1;
        dir_q <= g_wr_req;
        port_q <= g_port;
        id_q <= g_id;
        word_q <= g_word;
        left_q <= {1'b0, g_len} + 9'd1;
        resp_q <= g_resp;
        beat_act <= 1'b0;
        last_grant <= grant;
        if (g_resp != R_OKAY) stat_errs <= stat_errs + 32'd1;
      end
      if (stat_clr) begin
        stat_rd_beats <= '0;
        stat_wr_beats <= '0;
        stat_acts <= '0;
        stat_hits <= '0;
        stat_refs <= '0;
        stat_errs <= '0;
      end
    end
  end
  // not used: WLAST (AxLEN counts the beats), the memory's read valid (the return pipe runs alongside its
  // T_CL), the address bits below a word
  wire unused_ok = &{1'b0, s_axi_wlast, dfi_rddata_valid_i, g_addr[OFF-1:0], 1'b0};
endmodule
