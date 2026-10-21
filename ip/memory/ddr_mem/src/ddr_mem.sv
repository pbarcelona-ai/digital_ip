// ***************
// Filename: ddr_mem.sv
// Author: FPGA Cores 4 U
// Description: Generic DDR memory for simulation (a behavioural model of an
//   external SDRAM, not synthesizable logic) behind a DFI-style command
//   interface, one command per clock (controller clock = DFI clock, 1:1),
//   with the timing checks of a JEDEC SDRAM. Version 1.0.0. Golden model:
//   model/ddr_mem_model.py (clock exact; tb/python).
//   - Commands (cmd_i): 0 NOP, 1 ACT (open row_i in bank_i), 2 RD (bank_i,
//     col_i), 3 WR (bank_i, col_i, wrdata_i, the bytes with wrstrb_i set),
//     4 PRE (close bank_i; a no-op for a closed bank), 5 PREA (close every
//     bank), 6 REF (refresh; every bank closed), 7 illegal.
//   - Word address: {open row, bank, col} = (row << (BANK_W + COL_W)) |
//     (bank << COL_W) | col; it must be below MEM_WORDS. Unwritten words
//     read 0; a RD / WR to a closed bank or beyond MEM_WORDS reads 0 /
//     writes nothing.
//   - A RD in clock n gives rddata_valid_o with the word in clock n + T_CL
//     (the word before a WR of the same clock).
//   - Timing checks (ages in clocks since a bank's last ACT / PRE / WR / RD
//     and since the last ACT, WR, REF of any bank, saturating at 255; every
//     timing parameter 1 .. 254): 1 ACT to an open bank, 2 RD / WR to a
//     closed bank, 3 RD / WR before T_RCD, 4 ACT before T_RP after the
//     bank's PRE or REF before T_RP after any PRE, 5 PRE before T_RAS, 6 PRE
//     before T_WR after a WR or T_RTP after a RD, 7 ACT before T_RRD after
//     any ACT, 8 RD before T_WTR after any WR, 9 REF with a bank open, 10 a
//     command before T_RFC after a REF, 11 refresh overdue (more than
//     REF_MAX clocks since reset or the last REF; once until the next REF),
//     12 address beyond MEM_WORDS, 13 illegal command. PREA checks 5 / 6 for
//     every open bank. The command is still applied.
//   - err_o (sticky) at the first violation, err_code_o the smallest code of
//     that clock, err_cnt_o the clocks with a violation (saturating).
//   Parameters: DATA_W (multiple of 8), BANK_W, ROW_W, COL_W, MEM_WORDS (the
//   words stored), the timings in clocks, REF_MAX.
//   Clock - clk. Reset - synchronous active low rst_n (bank state, checks,
//   read pipeline; the contents are kept). Clock-domain crossings - none.
//   Latency - read data T_CL clocks after the RD; all outputs registered.
// Date: 2026-10-21
module ddr_mem #(
  parameter int DATA_W    = 256,               // bits per column word (multiple of 8)
  parameter int BANK_W    = 3,                 // log2 banks
  parameter int ROW_W     = 14,                // row address bits
  parameter int COL_W     = 8,                 // column (word) address bits
  parameter int MEM_WORDS = 1 << 16,           // words stored
  parameter int T_RCD     = 4,                 // ACT to RD / WR
  parameter int T_RP      = 4,                 // PRE to ACT (and to REF)
  parameter int T_RAS     = 10,                // ACT to PRE
  parameter int T_CL      = 5,                 // RD to data
  parameter int T_WR      = 4,                 // WR to PRE
  parameter int T_RTP     = 2,                 // RD to PRE
  parameter int T_WTR     = 2,                 // WR to RD
  parameter int T_RRD     = 2,                 // ACT to ACT (any banks)
  parameter int T_RFC     = 30,                // REF to the next command
  parameter int REF_MAX   = 9 * 1950           // longest time without a REF
) (
  input  logic                clk,             // clock
  input  logic                rst_n,           // synchronous, active low
  input  logic [2:0]          cmd_i,           // command (see the header)
  input  logic [BANK_W-1:0]   bank_i,          // bank of ACT / RD / WR / PRE
  input  logic [ROW_W-1:0]    row_i,           // row of ACT
  input  logic [COL_W-1:0]    col_i,           // column of RD / WR
  input  logic [DATA_W-1:0]   wrdata_i,        // WR data
  input  logic [DATA_W/8-1:0] wrstrb_i,        // WR byte enables
  output logic                rddata_valid_o,  // a RD's word (T_CL clocks after it)
  output logic [DATA_W-1:0]   rddata_o,        // the word
  output logic                err_o,           // sticky: a timing / protocol violation
  output logic [3:0]          err_code_o,      // the first violation's code
  output logic [15:0]         err_cnt_o        // clocks with a violation
);
`ifdef SYNTHESIS
  initial $error("ddr_mem is a simulation model of an external memory");
`endif
  localparam int NB      = 1 << BANK_W;
  localparam int AGE_MAX = 255;
  localparam int AW      = BANK_W + ROW_W + COL_W;
  localparam logic [2:0] C_NOP = 3'd0, C_ACT = 3'd1, C_RD = 3'd2, C_WR = 3'd3, C_PRE = 3'd4, C_PREA = 3'd5,
                         C_REF = 3'd6;
  if (T_RCD < 1 || T_RCD >= AGE_MAX || T_RP < 1 || T_RP >= AGE_MAX || T_RAS < 1 || T_RAS >= AGE_MAX ||
      T_CL < 1 || T_CL >= AGE_MAX || T_WR < 1 || T_WR >= AGE_MAX || T_RTP < 1 || T_RTP >= AGE_MAX ||
      T_WTR < 1 || T_WTR >= AGE_MAX || T_RRD < 1 || T_RRD >= AGE_MAX || T_RFC < 1 || T_RFC >= AGE_MAX ||
      DATA_W % 8 != 0 || MEM_WORDS < 2 || (MEM_WORDS & (MEM_WORDS - 1)) != 0 ||
      $clog2(MEM_WORDS) > BANK_W + ROW_W + COL_W) begin : g_bad
    $error("ddr_mem: timings 1 .. 254, DATA_W a multiple of 8, MEM_WORDS a power of two within the address space");
  end

  logic [DATA_W-1:0] mem [0:MEM_WORDS-1];
  initial begin
    for (int i = 0; i < MEM_WORDS; i++) mem[i] = '0;   // unwritten words read 0
  end

  logic [NB-1:0]     open_q;
  logic [ROW_W-1:0]  row_q [NB];
  logic [7:0]        age_act [NB], age_pre [NB], age_wr [NB], age_rd [NB];
  logic [7:0]        g_act, g_wr, g_ref;
  logic [24:0]       ref_cnt;
  logic              overdue;
  logic [T_CL-1:0]   pipe_v;                  // read pipeline: stage 0 the clock after the RD, T_CL-1 the output
  logic [DATA_W-1:0] pipe_d [T_CL];
  assign rddata_valid_o = pipe_v[T_CL-1];
  assign rddata_o       = pipe_d[T_CL-1];

  function automatic logic [7:0] sat(input logic [7:0] a);
    sat = (a == 8'(AGE_MAX)) ? a : a + 8'd1;
  endfunction

  // ---- this clock's checks, address and read word
  logic [13:0]      viol;                       // viol[k]: violation code k
  logic             addr_ok;
  logic [AW-1:0]    addr;
  logic [7:0]       min_pre;
  always_comb begin
    viol = '0;
    addr = {row_q[bank_i], bank_i, col_i};
    addr_ok = 1'b0;
    min_pre = 8'(AGE_MAX);
    for (int b = 0; b < NB; b++) if (age_pre[b] < min_pre) min_pre = age_pre[b];
    if (cmd_i != C_NOP && g_ref < 8'(T_RFC)) viol[10] = 1'b1;
    unique case (cmd_i)
      C_NOP: ;
      C_ACT: begin
        if (open_q[bank_i]) viol[1] = 1'b1;
        if (age_pre[bank_i] < 8'(T_RP)) viol[4] = 1'b1;
        if (g_act < 8'(T_RRD)) viol[7] = 1'b1;
      end
      C_RD, C_WR: begin
        if (!open_q[bank_i]) viol[2] = 1'b1;
        else begin
          if (age_act[bank_i] < 8'(T_RCD)) viol[3] = 1'b1;
          if (32'(addr) >= 32'(MEM_WORDS)) viol[12] = 1'b1;
          else addr_ok = 1'b1;
        end
        if (cmd_i == C_RD && g_wr < 8'(T_WTR)) viol[8] = 1'b1;
      end
      C_PRE: begin
        if (open_q[bank_i]) begin
          if (age_act[bank_i] < 8'(T_RAS)) viol[5] = 1'b1;
          if (age_wr[bank_i] < 8'(T_WR) || age_rd[bank_i] < 8'(T_RTP)) viol[6] = 1'b1;
        end
      end
      C_PREA: begin
        for (int b = 0; b < NB; b++) begin
          if (open_q[b]) begin
            if (age_act[b] < 8'(T_RAS)) viol[5] = 1'b1;
            if (age_wr[b] < 8'(T_WR) || age_rd[b] < 8'(T_RTP)) viol[6] = 1'b1;
          end
        end
      end
      C_REF: begin
        if (open_q != '0) viol[9] = 1'b1;
        if (min_pre < 8'(T_RP)) viol[4] = 1'b1;
      end
      default: viol[13] = 1'b1;
    endcase
    if (cmd_i != C_REF && !overdue && ref_cnt + 25'd1 > 25'(REF_MAX)) viol[11] = 1'b1;
  end
  wire [DATA_W-1:0] rd_word = (cmd_i == C_RD && addr_ok) ? mem[addr[$clog2(MEM_WORDS)-1:0]] : '0;
  logic [3:0] first_code;
  always_comb begin
    first_code = 4'd0;
    for (int k = 13; k >= 1; k--) if (viol[k]) first_code = 4'(k);
  end

  // ---- state
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
      ref_cnt <= '0;
      overdue <= 1'b0;
      pipe_v <= '0;
      for (int i = 0; i < T_CL; i++) pipe_d[i] <= '0;
      err_o <= 1'b0;
      err_code_o <= '0;
      err_cnt_o <= '0;
    end else begin
      // read pipeline
      pipe_v[0] <= (cmd_i == C_RD);
      pipe_d[0] <= rd_word;
      for (int i = 1; i < T_CL; i++) begin
        pipe_v[i] <= pipe_v[i - 1];
        pipe_d[i] <= pipe_d[i - 1];
      end
      // ages
      for (int b = 0; b < NB; b++) begin
        age_act[b] <= sat(age_act[b]);
        age_pre[b] <= sat(age_pre[b]);
        age_wr[b] <= sat(age_wr[b]);
        age_rd[b] <= sat(age_rd[b]);
      end
      g_act <= sat(g_act);
      g_wr <= sat(g_wr);
      g_ref <= sat(g_ref);
      // refresh deadline
      if (cmd_i == C_REF) begin
        ref_cnt <= '0;
        overdue <= 1'b0;
      end else begin
        if (ref_cnt != {25{1'b1}}) ref_cnt <= ref_cnt + 25'd1;
        if (viol[11]) overdue <= 1'b1;
      end
      // commands
      unique case (cmd_i)
        C_ACT: begin
          open_q[bank_i] <= 1'b1;
          row_q[bank_i] <= row_i;
          age_act[bank_i] <= '0;
          g_act <= '0;
        end
        C_WR: begin
          age_wr[bank_i] <= '0;
          g_wr <= '0;
          if (addr_ok) begin
            for (int i = 0; i < DATA_W / 8; i++)
              if (wrstrb_i[i]) mem[addr[$clog2(MEM_WORDS)-1:0]][8*i +: 8] <= wrdata_i[8*i +: 8];
          end
        end
        C_RD: age_rd[bank_i] <= '0;
        C_PRE: begin
          if (open_q[bank_i]) begin
            open_q[bank_i] <= 1'b0;
            age_pre[bank_i] <= '0;
          end
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
      if (viol != '0) begin
        if (!err_o) begin
          err_o <= 1'b1;
          err_code_o <= first_code;
        end
        if (err_cnt_o != 16'hFFFF) err_cnt_o <= err_cnt_o + 16'd1;
      end
    end
  end
endmodule
