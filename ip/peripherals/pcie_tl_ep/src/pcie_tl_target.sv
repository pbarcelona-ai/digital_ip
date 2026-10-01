// ***************
// Filename: pcie_tl_target.sv
// Author: FPGA Cores 4 U
// Description: PCIe transaction layer target. Parses TLPs from a DW stream
//   (3DW and 4DW headers), implements Type 0 configuration space (IDs,
//   command, BAR0 with size probing, completer ID capture), a BAR0 lower half
//   backed by block RAM with byte enables, and a BAR0 upper half that
//   forwards memory write payload to a DW stream. Memory reads and
//   configuration reads return CplD, configuration writes return Cpl,
//   unsupported non-posted requests return a UR completion, unsupported
//   posted requests are dropped. Version 1.0.0. Clock - the clock of the
//   parent block, all signals are synchronous to it. Reset - synchronous,
//   driven by the parent block. Latency - as documented in the parent block,
//   fixed and independent of data. Errors - none reported here, out-of-range
//   parameters stop elaboration or are handled by the parent block.
// Date: 2026-09-29
module pcie_tl_target #(
  parameter logic [15:0] VENDOR_ID  = 16'h1234,
  parameter logic [15:0] DEVICE_ID  = 16'h5678,
  parameter logic [23:0] CLASS_CODE = 24'h058000,
  parameter int          BAR_BITS   = 13,      // BAR0 size = 2**BAR_BITS bytes
  parameter int          RAM_DW     = 1024,    // RAM words (lower BAR half)
  parameter int          MAX_RD_DW  = 32       // largest memory read accepted
) (
  input  logic        clk,
  input  logic        rst_n,
  // Received TLP as DW stream
  input  logic [31:0] rx_dw,
  input  logic        rx_last,
  input  logic        rx_valid,
  output logic        rx_ready,
  // Completion TLP as DW stream
  output logic [31:0] cpl_dw,
  output logic        cpl_last,
  output logic        cpl_valid,
  input  logic        cpl_ready,
  // Stream window output (memory writes to BAR0 upper half)
  output logic [31:0] str_dw,
  output logic        str_last,
  output logic        str_valid,
  input  logic        str_ready,
  // Status
  output logic        mem_en_o,       // command[1]
  output logic        bus_master_o,   // command[2]
  output logic [15:0] cpl_id_o,       // completer ID {bus,dev,func}
  output logic [31:0] bar0_o,
  // One clock event pulses for counters
  output logic        p_rx_tlp,
  output logic        p_mwr,
  output logic        p_mrd,
  output logic        p_cfg,
  output logic        p_ur
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (BAR_BITS < 6 || BAR_BITS > 24) begin : g_chk_bar $error("pcie_tl_target: BAR_BITS must be 6..24"); end
  if (RAM_DW < 4) begin : g_chk_ram $error("pcie_tl_target: RAM_DW must be >= 4"); end
  if (MAX_RD_DW < 1) begin : g_chk_rd $error("pcie_tl_target: MAX_RD_DW must be >= 1"); end
  localparam int RAM_AW = $clog2(RAM_DW);

  // ---------------- Configuration space registers ----------------
  logic [15:0] command;
  logic [31:0] bar0;                   // only [31:BAR_BITS] are meaningful
  logic [15:0] cpl_id;
  wire  [31:0] bar_mask = ~((32'd1 << BAR_BITS) - 32'd1);
  assign mem_en_o     = command[1];
  assign bus_master_o = command[2];
  assign cpl_id_o     = cpl_id;
  assign bar0_o       = bar0 & bar_mask;

  // ---------------- Block RAM (simple dual port, byte enables) ----------------
  logic [31:0] ram [0:RAM_DW-1];
  logic        ram_we, ram_re;
  logic [3:0]  ram_be;
  logic [RAM_AW-1:0] ram_wa, ram_ra;
  logic [31:0] ram_wd, ram_q;
  always_ff @(posedge clk) begin
    if (ram_we)
      for (int b = 0; b < 4; b++)
        if (ram_be[b]) ram[ram_wa][b*8 +: 8] <= ram_wd[b*8 +: 8];
    if (ram_re) ram_q <= ram[ram_ra];
  end

  // ---------------- Request capture registers ----------------
  typedef enum logic [2:0] { R_H0, R_H1, R_H2, R_H3, R_DEC, R_DATA, R_DROP } rstate_t;
  rstate_t rstate;

  logic [2:0]  fmt;
  logic [4:0]  ttype;
  logic [9:0]  len;                  // payload / read length in DWs (0 -> 1024)
  logic [15:0] req_id;
  logic [7:0]  tag;
  logic [3:0]  first_be, last_be;
  logic [31:0] addr_hi, addr_lo;
  logic [9:0]  dw_cnt;
  logic [5:0]  cfg_reg;
  logic        hdr_last;             // TLP ended with its header
  logic        tgt_ram, tgt_str, tgt_cfg, hit;

  // Address decode of the captured request
  wire addr_hit = mem_en_o && (addr_hi == 32'd0) &&
                  ((addr_lo & bar_mask) == (bar0 & bar_mask));
  wire sel_str  = addr_lo[BAR_BITS-1];               // upper half = stream
  wire [RAM_AW-1:0] ram_base = addr_lo[RAM_AW+1:2];
  wire len_ok   = (len != 10'd0) && (len <= 10'(MAX_RD_DW));   // read length limit

  // Completion byte count and lower address
  wire [3:0] be_last_eff = (len == 10'd1) ? first_be : last_be;
  wire [1:0] first_off   = first_be[0] ? 2'd0 : first_be[1] ? 2'd1 :
                           first_be[2] ? 2'd2 : 2'd3;
  wire [1:0] last_trail  = be_last_eff[3] ? 2'd0 : be_last_eff[2] ? 2'd1 :
                           be_last_eff[1] ? 2'd2 : 2'd3;
  wire [11:0] byte_cnt   = {len, 2'b00} - {10'd0, first_off} - {10'd0, last_trail};
  wire [6:0]  low_addr   = {addr_lo[6:2], first_off};

  // Configuration space read data
  logic [31:0] cfg_rd;
  always_comb begin
    case (cfg_reg)
      6'd0:    cfg_rd = {DEVICE_ID, VENDOR_ID};
      6'd1:    cfg_rd = {16'h0000, command};
      6'd2:    cfg_rd = {CLASS_CODE, 8'h01};
      6'd3:    cfg_rd = 32'h0000_0000;              // header type 0
      6'd4:    cfg_rd = bar0 & bar_mask;
      default: cfg_rd = 32'd0;
    endcase
  end

  // ---------------- Completion sequencer ----------------
  typedef enum logic { C_IDLE, C_RUN } cstate_t;
  cstate_t     cstate;
  logic        c_start;                  // pulse from the request decoder
  logic [2:0]  c_status;                 // 0 = SC, 1 = UR
  logic        c_data, c_cfg;
  logic [9:0]  c_len;
  logic [11:0] c_bytes;
  logic [6:0]  c_low;
  logic [15:0] c_req;
  logic [7:0]  c_tag;
  logic [31:0] c_cfgdata;
  logic [RAM_AW-1:0] c_ptr;              // next RAM word to read
  logic [9:0]  c_issued, c_taken;        // data DWs read / emitted
  logic [1:0]  c_k;                      // 0,1,2 = header DW index, 3 = data
  logic        rd_pend;                  // ram_q holds an unconsumed DW

  wire c_busy   = (cstate != C_IDLE) | c_start;
  wire out_free = ~cpl_valid | cpl_ready;
  wire c_dataph = (cstate == C_RUN) && (c_k == 2'd3) && c_data && !c_cfg;
  wire consume  = c_dataph && rd_pend && out_free;
  wire issue    = c_dataph && (c_issued != c_len) && (!rd_pend || consume);
  assign ram_re = issue;
  assign ram_ra = c_ptr;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cstate <= C_IDLE; c_k <= '0; cpl_valid <= 1'b0; cpl_dw <= '0; cpl_last <= 1'b0;
      c_status <= '0; c_data <= 1'b0; c_cfg <= 1'b0; c_len <= '0; c_bytes <= '0;
      c_low <= '0; c_req <= '0; c_tag <= '0; c_cfgdata <= '0; c_ptr <= '0;
      c_issued <= '0; c_taken <= '0; rd_pend <= 1'b0;
    end else begin
      if (cpl_valid & cpl_ready) cpl_valid <= 1'b0;
      if (issue) begin c_ptr <= c_ptr + 1'b1; c_issued <= c_issued + 10'd1; end
      if (issue)        rd_pend <= 1'b1;             // data valid next cycle
      else if (consume) rd_pend <= 1'b0;
      case (cstate)
        C_IDLE: if (c_start) begin                   // latch the request
          c_status  <= (hit || tgt_cfg) ? 3'd0 : 3'd1;
          c_cfg     <= tgt_cfg;
          c_data    <= (hit || tgt_cfg) && !fmt[1];
          c_len     <= tgt_cfg ? 10'd1 : len;
          c_bytes   <= (hit || tgt_cfg) ? (tgt_cfg ? 12'd4 : byte_cnt) : 12'd4;
          c_low     <= tgt_cfg ? 7'd0 : low_addr;
          c_req     <= req_id;  c_tag <= tag;
          c_cfgdata <= cfg_rd;
          c_ptr     <= ram_base; c_issued <= '0; c_taken <= '0;
          c_k       <= '0; rd_pend <= 1'b0;
          cstate    <= C_RUN;
        end
        C_RUN: if (out_free) begin
          case (c_k)
            2'd0: begin                              // DW0: completion header
              cpl_dw <= {(c_data ? 3'b010 : 3'b000), 5'b01010, 1'b0, 3'b000,
                         4'b0000, 1'b0, 1'b0, 2'b00, 2'b00,
                         (c_data ? c_len : 10'd0)};
              cpl_valid <= 1'b1; cpl_last <= 1'b0; c_k <= 2'd1;
            end
            2'd1: begin                              // DW1: completer, status
              cpl_dw <= {cpl_id, c_status, 1'b0, c_bytes};
              cpl_valid <= 1'b1; c_k <= 2'd2;
            end
            2'd2: begin                              // DW2: requester, tag
              cpl_dw <= {c_req, c_tag, 1'b0, c_low};
              cpl_valid <= 1'b1;
              cpl_last  <= ~c_data;
              if (c_data) c_k <= 2'd3; else cstate <= C_IDLE;
            end
            default: begin                           // data DWs
              if (c_cfg) begin
                cpl_dw <= c_cfgdata; cpl_valid <= 1'b1; cpl_last <= 1'b1;
                cstate <= C_IDLE;
              end else if (rd_pend) begin
                cpl_dw <= ram_q; cpl_valid <= 1'b1;
                cpl_last <= (c_taken == c_len - 10'd1);
                c_taken <= c_taken + 10'd1;
                if (c_taken == c_len - 10'd1) cstate <= C_IDLE;
              end
            end
          endcase
        end
        default: cstate <= C_IDLE;
      endcase
    end
  end

  // ---------------- Request parser ----------------
  wire str_free = ~str_valid | str_ready;
  assign rx_ready = (rstate == R_DEC)  ? 1'b0 :
                    (rstate == R_DATA) ? (tgt_str ? str_free : 1'b1) : 1'b1;

  wire [RAM_AW-1:0] wr_word = ram_base + dw_cnt[RAM_AW-1:0];
  wire [3:0]        wr_be   = (dw_cnt == 10'd0)     ? first_be :
                              (dw_cnt == len - 10'd1) ? last_be : 4'hF;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rstate <= R_H0; fmt <= '0; ttype <= '0; len <= 10'd1; req_id <= '0; tag <= '0;
      first_be <= '0; last_be <= '0; addr_hi <= '0; addr_lo <= '0; dw_cnt <= '0;
      cfg_reg <= '0; hdr_last <= 1'b0; command <= '0; bar0 <= '0; cpl_id <= '0;
      tgt_ram <= 1'b0; tgt_str <= 1'b0; tgt_cfg <= 1'b0; hit <= 1'b0;
      c_start <= 1'b0; ram_we <= 1'b0; ram_be <= '0; ram_wa <= '0; ram_wd <= '0;
      str_dw <= '0; str_last <= 1'b0; str_valid <= 1'b0;
      p_rx_tlp <= 1'b0; p_mwr <= 1'b0; p_mrd <= 1'b0; p_cfg <= 1'b0; p_ur <= 1'b0;
    end else begin
      c_start <= 1'b0; ram_we <= 1'b0;
      p_rx_tlp <= 1'b0; p_mwr <= 1'b0; p_mrd <= 1'b0; p_cfg <= 1'b0; p_ur <= 1'b0;
      if (str_valid & str_ready) str_valid <= 1'b0;
      case (rstate)
        R_H0: if (rx_valid) begin
          fmt <= rx_dw[31:29]; ttype <= rx_dw[28:24];
          len <= rx_dw[9:0];                              // 0 means 1024
          p_rx_tlp <= 1'b1;
          if (!rx_last) rstate <= R_H1;                   // runt TLP ignored
        end
        R_H1: if (rx_valid) begin
          req_id <= rx_dw[31:16]; tag <= rx_dw[15:8];
          last_be <= rx_dw[7:4]; first_be <= rx_dw[3:0];
          rstate <= rx_last ? R_H0 : R_H2;
        end
        R_H2: if (rx_valid) begin
          dw_cnt <= '0; hdr_last <= rx_last;
          if (fmt[0]) begin                               // 4DW: address high
            addr_hi <= rx_dw;
            rstate  <= rx_last ? R_H0 : R_H3;
          end else begin                                  // 3DW: address / cfg
            addr_hi <= 32'd0; addr_lo <= {rx_dw[31:2], 2'b00};
            cfg_reg <= rx_dw[7:2];
            if (ttype == 5'b00100) cpl_id <= rx_dw[31:16];   // cfg: bus/dev/fn
            rstate  <= R_DEC;
          end
        end
        R_H3: if (rx_valid) begin
          addr_lo <= {rx_dw[31:2], 2'b00}; hdr_last <= rx_last; rstate <= R_DEC;
        end
        // Decode step (rx stalled): start completions when the sequencer is free
        R_DEC: begin
          if (ttype == 5'b00000) begin                     // memory request
            if (!fmt[1]) begin                             // memory read
              if (!c_busy) begin
                tgt_cfg <= 1'b0;
                hit     <= addr_hit && !sel_str && len_ok;
                c_start <= 1'b1; p_mrd <= 1'b1;
                p_ur    <= ~(addr_hit && !sel_str && len_ok);
                rstate  <= R_H0;
              end
            end else begin                                 // memory write
              tgt_cfg <= 1'b0; tgt_ram <= addr_hit && !sel_str;
              tgt_str <= addr_hit && sel_str; p_mwr <= 1'b1;
              rstate  <= hdr_last ? R_H0 : (addr_hit ? R_DATA : R_DROP);
            end
          end else if (ttype == 5'b00100 && !fmt[0]) begin   // config type 0
            if (!c_busy) begin
              tgt_cfg <= 1'b1; tgt_ram <= 1'b0; tgt_str <= 1'b0; hit <= 1'b0;
              c_start <= 1'b1; p_cfg <= 1'b1;
              rstate  <= (fmt[1] && !hdr_last) ? R_DATA : R_H0;
            end
          end else begin                                   // unsupported type
            tgt_cfg <= 1'b0; tgt_ram <= 1'b0; tgt_str <= 1'b0; hit <= 1'b0;
            if (!fmt[1] && ttype[4:3] == 2'b00) begin      // non-posted: UR
              if (!c_busy) begin c_start <= 1'b1; p_ur <= 1'b1; rstate <= R_H0; end
            end else rstate <= hdr_last ? R_H0 : R_DROP;   // posted: drop
          end
        end
        // ---- payload DWs ----
        R_DATA: if (rx_valid) begin
          if (tgt_cfg) begin                               // config write
            if (cfg_reg == 6'd1) begin
              if (first_be[0]) command[7:0]  <= rx_dw[7:0]  & 8'h06;
              if (first_be[1]) command[15:8] <= rx_dw[15:8] & 8'h04;
            end
            if (cfg_reg == 6'd4)
              for (int b = 0; b < 4; b++)
                if (first_be[b]) bar0[b*8 +: 8] <= rx_dw[b*8 +: 8];
          end else if (tgt_ram) begin
            ram_we <= 1'b1; ram_wa <= wr_word; ram_be <= wr_be; ram_wd <= rx_dw;
          end else if (tgt_str) begin
            str_dw <= rx_dw; str_last <= rx_last; str_valid <= 1'b1;
          end
          dw_cnt <= dw_cnt + 10'd1;
          if (rx_last) rstate <= R_H0;
        end
        R_DROP: if (rx_valid && rx_last) rstate <= R_H0;
        default: rstate <= R_H0;
      endcase
    end
  end
endmodule
