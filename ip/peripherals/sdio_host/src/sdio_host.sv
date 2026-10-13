// ***************
// Filename: sdio_host.sv
// Author: FPGA Cores 4 U
// Description: SD / SDIO host controller (single-block transfers, 1-bit or
//   4-bit data bus, SD mode). The registers (cfg_* / sts_*
//   ports; sdio_host_top.sv is the block with its AXI4-Lite register map,
//   src/include/sdio_host_regs.sv, ID "SDIO" / VERSION / DATE at 0x00-0x08)
//   issue one command at a time - 0x10 CMD (write starts it): index[5:0],
//   response[7:6] (0 none, 1 short 48 bit, 2 long 136 bit), data
//   direction[9:8] (0 none, 1 read block, 2 write block), no_crc_check[10]
//   (for R3/R7-style responses without valid CRC7); 0x14 ARG; 0x18..0x24
//   RESP0..RESP3 (short response argument in RESP0, long response 127..0
//   in RESP3..RESP0); 0x28 STATUS (bit0 busy, bit1 cmd_done, bit2
//   dat_done, bit3 cmd_timeout, bit4 cmd_crc_err, bit5 dat_crc_err, bit6
//   dat_timeout, bit7 buf_err; write 1 to clear bits 1-7); 0x2C CTRL
//   (half_period[15:0] in system clocks, minimum 1, bus4[16], clk_en[17]);
//   0x30 BLKSIZE (bytes, 1..BUF_BYTES); 0x34 TIMEOUT (SD clocks for
//   data/busy timeout); 0x38 IRQ_EN (bit n enables STATUS bit n+1 for
//   irq_o). Data - a block buffer of BUF_BYTES bytes
//   decouples the free-running SD clock from AXI-Stream: for a write, fill
//   the buffer through s_axis (BLKSIZE bytes, only accepted while idle)
//   and then issue the write command; a read block is verified (CRC16 per
//   data line) and only then streamed out on m_axis (tlast on the final
//   byte), a block with a CRC error is discarded. The command engine
//   appends CRC7, checks the CRC7 of short responses, waits up to 80 SD
//   clocks for a response, and for writes handles the CRC status token and
//   the busy signal. SD signals - sd_clk_o (half period = CTRL.half_period
//   system clocks), cmd_o/cmd_oe_o/cmd_i and dat_o/dat_oe_o/dat_i[3:0] are
//   separate outputs and inputs (connect to tri-state buffers at the top
//   level, external pull-ups on CMD/DAT); outputs change on the falling
//   edge of sd_clk_o, inputs are double-registered and sampled on rising
//   edges. Clock - aclk; SD clock runs only while CTRL.clk_en=1 and must
//   be running for a command to progress (initialisation at 400 kHz needs
//   a half period of 125 at 100 MHz). Not supported - multi-block
//   transfers, SPI mode, UHS-I / 1.8 V, DMA. Reset - synchronous aresetn,
//   sd_clk low, all lines released. Latency - about 2*half_period system
//   clocks per SD clock; a 512 byte block takes about 1100 SD clocks in
//   4-bit mode and 4200 in 1-bit mode. Errors - cmd_timeout, cmd_crc_err,
//   dat_crc_err (also for a bad end bit or write CRC status), dat_timeout,
//   buf_err (bad BLKSIZE, write without a full buffer, or a command while
//   busy).
// Date: 2026-10-12
module sdio_host #(
  parameter int BUF_BYTES = 512
) (

  input  logic        aclk,
  input  logic        aresetn,
  // AXI-Stream block data
  input  logic [7:0]  s_axis_tdata,
  input  logic        s_axis_tvalid,
  output logic        s_axis_tready,
  output logic [7:0]  m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast,
  // SD pins
  output logic        sd_clk_o,
  output logic        cmd_o,
  output logic        cmd_oe_o,
  input  logic        cmd_i,
  output logic [3:0]  dat_o,
  output logic [3:0]  dat_oe_o,
  input  logic [3:0]  dat_i,
  output logic        irq_o,
  // register ports
  input  logic [10:0]  cfg_cmd,          // CMD
  input  logic         cfg_cmd_wr,       // CMD write pulse: start
  input  logic [31:0]  cfg_arg,          // ARG
  output logic [127:0] sts_resp,         // RESP[0..3]
  input  logic [7:0]   cfg_status,       // STATUS: data written ...
  input  logic         cfg_status_wr,    // ... and its write pulse
  output logic [7:0]   sts_status,       // STATUS: value read
  input  logic [17:0]  cfg_ctrl,         // CTRL
  input  logic [10:0]  cfg_blksize,      // BLKSIZE
  input  logic [31:0]  cfg_timeout,      // TIMEOUT
  input  logic [6:0]   cfg_irq_en        // IRQ_EN
);
  if (BUF_BYTES < 16 || BUF_BYTES > 1024) begin : g_bad $error("sdio_host: BUF_BYTES must be 16..1024"); end
  localparam int BW = $clog2(BUF_BYTES + 1);
  wire [31:0] r_arg = cfg_arg, r_ctrl = 32'(cfg_ctrl), r_blk = 32'(cfg_blksize), r_to = cfg_timeout, r_irqen = 32'(cfg_irq_en);
  wire bus4 = r_ctrl[16], clk_en = r_ctrl[17];
  wire [15:0] half = (r_ctrl[15:0] == 16'd0) ? 16'd1 : r_ctrl[15:0];

  // ---------------- SD clock and ticks ----------------
  logic sdclk;
  logic [15:0] hc;
  wire tick = clk_en & (hc == half - 1'b1);
  wire rt = tick & ~sdclk;                       // this aclk edge raises sd_clk
  wire ft = tick & sdclk;                        // this aclk edge lowers sd_clk
  assign sd_clk_o = sdclk;
  logic [1:0] cmd_s;
  logic cmdi;
  logic [3:0] d_s1, d_s;
  always_ff @(posedge aclk) begin
    cmd_s <= {cmd_s[0], cmd_i}; // 2-flop synchronizers on the input pins
    cmdi <= cmd_s[1];
    d_s1 <= dat_i;
    d_s <= d_s1;
  end

  function automatic logic [6:0] crc7_40(input logic [39:0] d);
    logic [6:0] c;
    c = 7'd0;
    for (int i = 39; i >= 0; i--) begin
      logic fb;
      fb = c[6] ^ d[i];
      c = {c[5:0], 1'b0};
      if (fb) c = c ^ 7'h09;
    end
    crc7_40 = c;
  endfunction
  function automatic logic [15:0] crc16_step(input logic [15:0] c, input logic b);
    logic fb;
    fb = c[15] ^ b;
    crc16_step = {c[14:0], 1'b0} ^ (fb ? 16'h1021 : 16'h0000);
  endfunction

  typedef enum logic [3:0] {S_IDLE, S_CMD_TX, S_CMD_WAIT, S_RESP, S_RESP_DONE, S_DAT_WAIT, S_DAT_RX, S_DAT_CRC, S_DAT_END,
                            S_WR_GAP, S_WR_TX, S_WR_STAT, S_WR_BUSY} st_t; st_t st;
  logic [7:0] mem [0:BUF_BYTES-1];
  logic [47:0] csr;
  logic [135:0] rsr;
  logic [13:0] nb;
  logic [31:0] cnt;
  logic [2:0] ph;
  logic [5:0] c_idx;
  logic [1:0] c_resp, c_dir;
  logic c_nocrc;
  logic [BW-1:0] blk, bidx, fill_cnt, out_cnt, out_idx;
  logic [7:0] acc;
  logic [2:0] bpos;
  logic [15:0] crc [0:3];
  logic [15:0] rcrc [0:3];
  logic [2:0] tok;
  logic wr_bad;
  logic [31:0] resp [0:3];
  logic f_cmd_done, f_dat_done, f_cto, f_ccrc, f_dcrc, f_dto, f_buf;
  logic [13:0] total_clks;
  logic [3:0] act;
  assign act = bus4 ? 4'hF : 4'h1;
  wire [BW-1:0] blk_w = r_blk[BW-1:0];
  wire blk_ok = (r_blk != 0) && (r_blk <= BUF_BYTES);
  assign total_clks = bus4 ? 14'(blk << 1) : 14'(blk << 3);
  assign s_axis_tready = (st == S_IDLE) && (out_cnt == 0) && (fill_cnt < BUF_BYTES);
  assign m_axis_tvalid = (out_cnt != 0);
  assign m_axis_tdata  = mem[out_idx];
  assign m_axis_tlast  = (out_cnt == 1);
  wire [7:0] cur_byte = mem[bidx];
  assign irq_o = |({f_buf, f_dto, f_dcrc, f_ccrc, f_cto, f_dat_done, f_cmd_done} & r_irqen[6:0]);
  logic [3:0] wr_bits;
  always_comb begin
    if (bus4) wr_bits = (bpos == 3'd0) ? cur_byte[7:4] : cur_byte[3:0];
    else      wr_bits = {3'b111, cur_byte[7 - bpos]};
  end
  wire start_cmd = cfg_cmd_wr;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      sdclk <= 1'b0;
      hc <= '0;
      st <= S_IDLE;
      cmd_o <= 1'b1;
      cmd_oe_o <= 1'b0;
      dat_o <= 4'hF;
      dat_oe_o <= 4'h0;
      f_cmd_done <= 0;
      f_dat_done <= 0;
      f_cto <= 0;
      f_ccrc <= 0;
      f_dcrc <= 0;
      f_dto <= 0;
      f_buf <= 0;
      out_cnt <= '0;
      out_idx <= '0;
      fill_cnt <= '0;
      nb <= '0;
      cnt <= '0;
      ph <= '0;
      csr <= '0;
      rsr <= '0;
      blk <= '0;
      bidx <= '0;
      acc <= '0;
      bpos <= '0;
      tok <= '0;
      wr_bad <= 1'b0;
      c_idx <= '0;
      c_resp <= '0;
      c_dir <= '0;
      c_nocrc <= 1'b0;
      for (int j = 0; j < 4; j++) begin
        crc[j] <= '0;
        rcrc[j] <= '0;
        resp[j] <= '0;
      end
    end else begin
      // ---- clock generation ----
      if (!clk_en) begin
        hc <= '0;
        sdclk <= 1'b0;
      end
      else if (tick) begin
        hc <= '0;
        sdclk <= ~sdclk;
      end
      else hc <= hc + 1'b1;
      // ---- status W1C ----
      if (cfg_status_wr) begin
        if (cfg_status[1]) f_cmd_done <= 0;
        if (cfg_status[2]) f_dat_done <= 0;
        if (cfg_status[3]) f_cto <= 0;
        if (cfg_status[4]) f_ccrc <= 0;
        if (cfg_status[5]) f_dcrc <= 0;
        if (cfg_status[6]) f_dto <= 0;
        if (cfg_status[7]) f_buf <= 0;
      end
      // ---- buffer fill (idle) and drain ----
      if (s_axis_tvalid && s_axis_tready) begin
        mem[fill_cnt[BW-1:0]] <= s_axis_tdata;
        fill_cnt <= fill_cnt + 1'b1;
      end
      if (m_axis_tvalid && m_axis_tready) begin
        out_idx <= out_idx + 1'b1;
        out_cnt <= out_cnt - 1'b1;
      end
      if (start_cmd && (st != S_IDLE || out_cnt != 0)) f_buf <= 1'b1;
      case (st)
        S_IDLE: if (start_cmd && out_cnt == 0) begin
          if ((cfg_cmd[9:8] != 2'd0 && !blk_ok) || (cfg_cmd[9:8] == 2'd2 && fill_cnt < blk_w)) f_buf <= 1'b1;
          else begin
            c_idx <= cfg_cmd[5:0];
            c_resp <= cfg_cmd[7:6];
            c_dir <= cfg_cmd[9:8];
            c_nocrc <= cfg_cmd[10];
            blk <= blk_w;
            csr <= {2'b01, cfg_cmd[5:0], r_arg, crc7_40({2'b01, cfg_cmd[5:0], r_arg}), 1'b1};
            nb <= '0;
            cnt <= '0;
            st <= S_CMD_TX;
            f_cmd_done <= 0;
            f_dat_done <= 0;
            f_cto <= 0;
            f_ccrc <= 0;
            f_dcrc <= 0;
            f_dto <= 0;
            if (cfg_cmd[9:8] != 2'd2) fill_cnt <= '0;                 // a read discards any staged bytes
          end
        end
        S_CMD_TX: if (ft) begin
          if (nb == 14'd48) begin
            cmd_oe_o <= 1'b0;
            cmd_o <= 1'b1;
            nb <= '0;
            cnt <= '0;
            st <= S_CMD_WAIT;
          end
          else begin
            cmd_o <= csr[47];
            cmd_oe_o <= 1'b1;
            csr <= {csr[46:0], 1'b1};
            nb <= nb + 1'b1;
          end
        end
        S_CMD_WAIT: if (rt) begin
          if (c_resp == 2'd0) begin
            f_cmd_done <= 1'b1;
            st <= S_IDLE;
          end
          else if (!cmdi) begin
            rsr <= 136'd0;
            nb <= 14'd1;
            st <= S_RESP;
          end
          else begin
            cnt <= cnt + 1'b1;
            if (cnt >= 32'd80) begin
              f_cto <= 1'b1;
              st <= S_IDLE;
            end
          end
        end
        S_RESP: if (rt) begin
          rsr <= {rsr[134:0], cmdi};
          nb <= nb + 1'b1;
          if (nb + 1'b1 == ((c_resp == 2'd2) ? 14'd136 : 14'd48)) st <= S_RESP_DONE;
        end
        S_RESP_DONE: begin
          if (c_resp == 2'd2) begin
            resp[0] <= rsr[31:0];
            resp[1] <= rsr[63:32];
            resp[2] <= rsr[95:64];
            resp[3] <= rsr[127:96];
            f_cmd_done <= 1'b1;
            st <= S_IDLE;
          end else begin
            resp[0] <= rsr[39:8];
            resp[1] <= '0;
            resp[2] <= '0;
            resp[3] <= '0;
            if (!rsr[0] || (!c_nocrc && rsr[7:1] != crc7_40(rsr[47:8]))) begin
              f_ccrc <= 1'b1;
              st <= S_IDLE;
            end
            else begin
              f_cmd_done <= 1'b1;
              cnt <= '0;
              nb <= '0;
              if (c_dir == 2'd1) st <= S_DAT_WAIT;
              else if (c_dir == 2'd2) begin st <= S_WR_GAP; end
              else st <= S_IDLE;
            end
          end
        end
        // ---------------- read block ----------------
        S_DAT_WAIT: if (rt) begin
          if (!d_s[0]) begin
            nb <= '0;
            bidx <= '0;
            bpos <= '0;
            acc <= '0;
            for (int j = 0; j < 4; j++) begin
              crc[j] <= '0;
              rcrc[j] <= '0;
            end
            st <= S_DAT_RX;
          end
          else begin
            cnt <= cnt + 1'b1;
            if (cnt >= r_to) begin
              f_dto <= 1'b1;
              st <= S_IDLE;
            end
          end
        end
        S_DAT_RX: if (rt) begin
          for (int j = 0; j < 4; j++) if (act[j]) crc[j] <= crc16_step(crc[j], d_s[j]);
          if (bus4) begin
            if (bpos == 3'd0) begin
              acc[7:4] <= d_s;
              bpos <= 3'd1;
            end
            else begin
              mem[bidx] <= {acc[7:4], d_s};
              bidx <= bidx + 1'b1;
              bpos <= 3'd0;
            end
          end else begin
            acc <= {acc[6:0], d_s[0]};
            if (bpos == 3'd7) begin
              mem[bidx] <= {acc[6:0], d_s[0]};
              bidx <= bidx + 1'b1;
              bpos <= 3'd0;
            end else bpos <= bpos + 1'b1;
          end
          nb <= nb + 1'b1;
          if (nb + 1'b1 == total_clks) begin
            nb <= '0;
            st <= S_DAT_CRC;
          end
        end
        S_DAT_CRC: if (rt) begin
          for (int j = 0; j < 4; j++) if (act[j]) rcrc[j] <= {rcrc[j][14:0], d_s[j]};
          nb <= nb + 1'b1;
          if (nb == 14'd15) st <= S_DAT_END;
        end
        S_DAT_END: if (rt) begin
          begin
            logic bad;
            bad = !d_s[0];
            for (int j = 0; j < 4; j++) if (act[j] && rcrc[j] != crc[j]) bad = 1'b1;
            if (bad) f_dcrc <= 1'b1;
            else begin
              out_cnt <= blk;
              out_idx <= '0;
              f_dat_done <= 1'b1;
            end
          end
          st <= S_IDLE;
        end
        // ---------------- write block ----------------
        S_WR_GAP: if (ft) begin
          nb <= nb + 1'b1;
          if (nb == 14'd3) begin
            nb <= '0;
            ph <= 3'd0;
            st <= S_WR_TX;
          end
        end
        S_WR_TX: if (ft) begin
          case (ph)
            3'd0: begin
              dat_o <= 4'h0;
              dat_oe_o <= act;
              for (int j = 0; j < 4; j++) crc[j] <= '0;
              bidx <= '0;
              bpos <= '0;
              nb <= '0;
              ph <= 3'd1;
            end
            3'd1: begin
              dat_o <= wr_bits;
              for (int j = 0; j < 4; j++) if (act[j]) crc[j] <= crc16_step(crc[j], wr_bits[j]);
              if (bus4) begin
                if (bpos == 3'd0) bpos <= 3'd1;
                else begin
                  bpos <= 3'd0;
                  bidx <= bidx + 1'b1;
                end
              end
              else begin
                if (bpos == 3'd7) begin
                  bpos <= 3'd0;
                  bidx <= bidx + 1'b1;
                end else bpos <= bpos + 1'b1;
              end
              nb <= nb + 1'b1;
              if (nb + 1'b1 == total_clks) begin
                nb <= '0;
                ph <= 3'd2;
              end
            end
            3'd2: begin
              for (int j = 0; j < 4; j++) begin
                dat_o[j] <= crc[j][15];
                crc[j] <= {crc[j][14:0], 1'b0};
              end
              nb <= nb + 1'b1;
              if (nb == 14'd15) ph <= 3'd3;
            end
            3'd3: begin
              dat_o <= 4'hF;
              ph <= 3'd4;
            end
            default: begin
              dat_oe_o <= 4'h0;
              st <= S_WR_STAT;
              nb <= '0;
              cnt <= '0;
              fill_cnt <= '0;
            end
          endcase
        end
        S_WR_STAT: if (rt) begin
          if (nb == 14'd0) begin
            if (!d_s[0]) nb <= 14'd1;
            else begin
              cnt <= cnt + 1'b1;
              if (cnt >= r_to) begin
                f_dto <= 1'b1;
                st <= S_IDLE;
              end
            end
          end else if (nb <= 14'd3) begin
            tok <= {tok[1:0], d_s[0]};
            nb <= nb + 1'b1;
          end
          else begin
            if (tok != 3'b010 || !d_s[0]) begin
              f_dcrc <= 1'b1;
              wr_bad <= 1'b1;
            end else wr_bad <= 1'b0;
            st <= S_WR_BUSY; // always wait for the card to leave busy
            nb <= '0;
            cnt <= '0;
          end
        end
        S_WR_BUSY: if (rt) begin
          if (nb < 14'd3) nb <= nb + 1'b1;                             // skip the samples that still show the end bit
          else if (d_s[0]) begin
            f_dat_done <= ~wr_bad;
            st <= S_IDLE;
          end
          else begin
            cnt <= cnt + 1'b1;
            if (cnt >= r_to) begin
              f_dto <= 1'b1;
              st <= S_IDLE;
            end
          end
        end
        default: st <= S_IDLE;
      endcase
    end
  end
  assign sts_resp = {resp[3], resp[2], resp[1], resp[0]};
  assign sts_status = {f_buf, f_dto, f_dcrc, f_ccrc, f_cto, f_dat_done, f_cmd_done, (st != S_IDLE) | (out_cnt != 0)};
endmodule
