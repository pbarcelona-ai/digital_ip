// ***************
// Filename: mipi_tx_engine.sv
// Author: FPGA Cores 4 U
// Description: MIPI CSI-2 / DSI transmit packet engine. Version 1.0.0. Turns
//   packet commands into HS bursts on NLANES lanes of a D-PHY transmitter
//   (PPI style: hs_req_o asks for HS mode, the PHY raises tx_ready_i once
//   the start-of-transmission sequence is done and then takes NLANES bytes
//   every byte clock; byte i of a word goes to lane i, as CSI-2 and DSI
//   distribute bytes). The analog D-PHY is vendor IP.
//   Command (cmd_i, valid / ready), fields MIPI_* below:
//     SHORT      - header {DI, data[7:0], data[15:8], ECC}
//     LONG_LINE  - header {DI, WC, ECC}, payload = one buffered line of
//                  `data` pixels read from the line buffer (lb_*), packed
//                  as fmt: 0 RGB888 B,G,R per pixel (CSI-2 0x24),
//                  1 RGB888 R,G,B (DSI 0x3E), 2 YUV422 8-bit U,Y0,V,Y1
//                  (CSI-2 0x1E; U / V are the rounded average of the pair;
//                  the line width must be even);
//                  then the CRC-16 checksum
//     LONG_BYTES - header {DI, WC = data, ECC}, payload = `data` bytes from
//                  the byte input pl_* (at most 64), then the checksum
//     GAP        - no packet, only the LP time below
//   eotp appends the DSI End of Transmission packet (08 0F 0F 01) to the
//   same burst; gap holds LP state for that many byte clocks after it.
//   Header ECC and CRC-16 (x^16 + x^12 + x^5 + 1, init 0xFFFF, LSB first)
//   are the CSI-2 / DSI ones; the ECC reproduces the specified EoTp ECC.
//   lane_data_o / lane_valid_o carry the bytes sent, one clock after the
//   PHY accepted them (tx_ready_i). A burst starts when its bytes are queued (short / byte packets) or when
//   24 bytes are queued (line packets, whose payload is produced at least as
//   fast as the lanes take it), so a burst never pauses; underflow_o flags
//   a violation. Line buffer read - lb_addr_o (pixel pair index, pairs
//   {odd, even} in 48 bits) with lb_data_i one clock later. Clock - D-PHY
//   byte clock. Reset - synchronous rst_n (active low).
// Date: 2026-10-02
module mipi_tx_engine #(
  parameter int NLANES = 2,                      // 1, 2 or 4
  parameter int MAX_W  = 2048
) (
  input  logic                  clk,
  input  logic                  rst_n,
  // Commands
  input  logic [45:0]           cmd_i,
  input  logic                  cmd_valid_i,
  output logic                  cmd_ready_o,
  // Line buffer read port
  output logic                  lb_buf_o,
  output logic [$clog2(MAX_W/2)-1:0] lb_addr_o,
  input  logic [47:0]           lb_data_i,
  output logic                  lb_done_o,       // pulse: finished with buffer lb_buf_o
  // Payload bytes for LONG_BYTES
  input  logic [7:0]            pl_data_i,
  input  logic                  pl_valid_i,
  output logic                  pl_ready_o,
  // D-PHY PPI transmit
  output logic [NLANES*8-1:0]   lane_data_o,
  output logic [NLANES-1:0]     lane_valid_o,    // byte accepted on this lane this clock
  output logic                  hs_req_o,
  input  logic                  tx_ready_i,
  output logic                  busy_o,
  output logic                  underflow_o
);
  if (NLANES != 1 && NLANES != 2 && NLANES != 4) begin : g_bad $error("mipi_tx_engine: NLANES must be 1, 2 or 4"); end
  localparam int AW = $clog2(MAX_W / 2);
  localparam int QCAP = 80, QW = 7;              // byte queue
  localparam int START_TH = 24;

  // ---------------- command fields
  wire [1:0]  c_type = cmd_i[1:0];               // 0 SHORT 1 LONG_LINE 2 LONG_BYTES 3 GAP
  wire [7:0]  c_di   = cmd_i[9:2];
  wire [15:0] c_data = cmd_i[25:10];             // short data / pixels / WC
  wire [1:0]  c_fmt  = cmd_i[27:26];
  wire        c_buf  = cmd_i[28];
  wire [15:0] c_gap  = cmd_i[44:29];
  wire        c_eotp = cmd_i[45];

  function automatic logic [5:0] ecc6(input logic [23:0] d);
    logic [5:0] p;
    p[0] = d[0]^d[1]^d[2]^d[4]^d[5]^d[7]^d[10]^d[11]^d[13]^d[16]^d[20]^d[21]^d[22]^d[23];
    p[1] = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[12]^d[14]^d[17]^d[20]^d[21]^d[22]^d[23];
    p[2] = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[11]^d[12]^d[15]^d[18]^d[20]^d[21]^d[22];
    p[3] = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[13]^d[14]^d[15]^d[19]^d[20]^d[21]^d[23];
    p[4] = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[16]^d[17]^d[18]^d[19]^d[20]^d[22]^d[23];
    p[5] = d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^d[21]^d[22]^d[23];
    ecc6 = p;
  endfunction
  function automatic logic [15:0] crc_byte(input logic [15:0] c, input logic [7:0] b);
    logic [15:0] r; r = c;
    for (int i = 0; i < 8; i++) r = (r >> 1) ^ ((r[0] ^ b[i]) ? 16'h8408 : 16'h0000);
    crc_byte = r;
  endfunction

  // ---------------- byte queue
  logic [7:0] q [QCAP]; logic [QW-1:0] wp, rp; logic [QW:0] cnt;
  logic [7:0] fb [6]; logic [2:0] fn;            // bytes appended this clock
  logic burst, all_enq;
  wire  [2:0] wbytes = (cnt >= NLANES) ? 3'(NLANES) : 3'(cnt);
  wire  pop   = burst && tx_ready_i && (cnt >= NLANES || all_enq) && cnt != 0;
  wire  [2:0] popn = pop ? wbytes : 3'd0;
  wire  [QW:0] cnt_after = cnt - popn;
  wire  space6 = (cnt_after + 6 <= QCAP);

  // ---------------- fill sequencer
  typedef enum logic [2:0] {F_IDLE, F_HDR, F_LINE, F_BYTES, F_CRC, F_EOTP, F_DRAIN, F_GAP} fst_e;
  fst_e fst;
  logic [1:0] k_type, k_fmt; logic [7:0] k_di; logic [15:0] k_data, k_gap, wc, rem, crc; logic k_buf, k_eotp;
  logic [AW-1:0] ra; logic [15:0] gap_cnt;
  logic consume;                                 // a line-buffer word is used this clock

  wire [23:0] pe = lb_data_i[23:0], po = lb_data_i[47:24];
  function automatic logic [7:0] avg(input logic [7:0] a, input logic [7:0] b);
    logic [8:0] s; s = a + b + 9'd1; avg = s[8:1];
  endfunction

  always_comb begin
    logic [23:0] h, p;                           // scratch: header word, current pixel
    h = {(k_type == 2'd0) ? k_data : wc, k_di}; p = '0;
    fn = '0; for (int i = 0; i < 6; i++) fb[i] = 8'h00;
    consume = 1'b0;
    case (fst)
      F_HDR: begin
        fb[0] = h[7:0]; fb[1] = h[15:8]; fb[2] = h[23:16]; fb[3] = {2'b00, ecc6(h)}; fn = 3'd4;
      end
      F_LINE: if (space6) begin
        consume = 1'b1;
        if (k_fmt == 2'd2) begin                 // YUV422: 4 bytes per pixel pair
          fb[0] = avg(pe[23:16], po[23:16]); fb[1] = pe[15:8]; fb[2] = avg(pe[7:0], po[7:0]); fb[3] = po[15:8];
          fn = 3'd4;
        end else begin
          for (int k = 0; k < 2; k++) begin
            p = k ? po : pe;
            if (k_fmt == 2'd0) begin fb[3*k] = p[23:16]; fb[3*k+1] = p[15:8]; fb[3*k+2] = p[7:0]; end
            else               begin fb[3*k] = p[7:0];   fb[3*k+1] = p[15:8]; fb[3*k+2] = p[23:16]; end
          end
          fn = (rem >= 16'd6) ? 3'd6 : 3'(rem);
        end
      end
      F_BYTES: if (space6 && pl_valid_i) begin fb[0] = pl_data_i; fn = 3'd1; end
      F_CRC: if (space6) begin fb[0] = crc[7:0]; fb[1] = crc[15:8]; fn = 3'd2; end
      F_EOTP: if (space6) begin fb[0] = 8'h08; fb[1] = 8'h0F; fb[2] = 8'h0F; fb[3] = 8'h01; fn = 3'd4; end
      default: ;
    endcase
  end
  assign pl_ready_o = (fst == F_BYTES) && space6;
  assign lb_buf_o   = k_buf;
  assign lb_addr_o  = (fst == F_HDR) ? '0 : (consume ? ra + 1'b1 : ra);
  assign cmd_ready_o = (fst == F_IDLE);
  assign busy_o      = (fst != F_IDLE) || burst;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fst <= F_IDLE; k_type <= '0; k_fmt <= '0; k_di <= '0; k_data <= '0; k_gap <= '0; k_buf <= 1'b0; k_eotp <= 1'b0;
      wc <= '0; rem <= '0; crc <= 16'hFFFF; ra <= '0; gap_cnt <= '0; lb_done_o <= 1'b0;
      wp <= '0; rp <= '0; cnt <= '0; burst <= 1'b0; all_enq <= 1'b0; underflow_o <= 1'b0;
      hs_req_o <= 1'b0; lane_valid_o <= '0; lane_data_o <= '0;
    end else begin
      lb_done_o <= 1'b0; underflow_o <= 1'b0;
      // ---- fill sequencer
      case (fst)
        F_IDLE: if (cmd_valid_i) begin
          k_type <= c_type; k_di <= c_di; k_data <= c_data; k_fmt <= c_fmt; k_buf <= c_buf; k_gap <= c_gap; k_eotp <= c_eotp;
          wc  <= (c_type == 2'd1) ? ((c_fmt == 2'd2) ? 16'(c_data * 2) : 16'(c_data * 3)) : c_data;
          rem <= (c_type == 2'd1) ? ((c_fmt == 2'd2) ? 16'(c_data * 2) : 16'(c_data * 3)) : c_data;
          crc <= 16'hFFFF; all_enq <= 1'b0;
          if (c_type == 2'd3) begin gap_cnt <= c_gap; fst <= F_GAP; end
          else fst <= F_HDR;
        end
        F_HDR: begin
          ra <= '0;
          if (k_type == 2'd0) fst <= fst_e'(k_eotp ? F_EOTP : F_DRAIN);
          else if (wc == 0) fst <= F_CRC;
          else fst <= fst_e'((k_type == 2'd1) ? F_LINE : F_BYTES);
        end
        F_LINE, F_BYTES: if (fn != 0) begin
          logic [15:0] c; c = crc;
          for (int i = 0; i < 6; i++) if (3'(i) < fn) c = crc_byte(c, fb[i]);
          crc <= c; rem <= rem - fn;
          if (consume) ra <= ra + 1'b1;
          if (rem == 16'(fn)) fst <= F_CRC;
        end
        F_CRC:  if (fn != 0) fst <= fst_e'(k_eotp ? F_EOTP : F_DRAIN);
        F_EOTP: if (fn != 0) fst <= F_DRAIN;
        F_DRAIN: begin
          all_enq <= 1'b1;
          if (all_enq && !burst && cnt == 0) begin
            if (k_type == 2'd1) lb_done_o <= 1'b1;
            gap_cnt <= k_gap; fst <= F_GAP;
          end
        end
        F_GAP: if (gap_cnt == 0) fst <= F_IDLE; else gap_cnt <= gap_cnt - 1'b1;
        default: fst <= F_IDLE;
      endcase

      // ---- byte queue: pop for the lanes, append from the sequencer
      begin
        logic [QW-1:0] w;
        w = wp;
        for (int i = 0; i < 6; i++) if (3'(i) < fn) begin q[w] <= fb[i]; w = (w == QW'(QCAP - 1)) ? '0 : w + 1'b1; end
        wp <= w;
        cnt <= cnt_after + fn;
      end

      // ---- output: one word of up to NLANES bytes per accepted clock
      lane_valid_o <= '0;
      if (pop) begin
        logic [QW-1:0] r; r = rp;
        for (int l = 0; l < NLANES; l++) begin
          lane_data_o[8*l +: 8] <= q[r];
          lane_valid_o[l] <= (3'(l) < wbytes);
          if (3'(l) < wbytes) r = (r == QW'(QCAP - 1)) ? '0 : r + 1'b1;
        end
        rp <= r;
      end
      // hs_req_o is high from the burst start through the clock of its last word
      if (!burst && cnt != 0 && (all_enq || (k_type == 2'd1 && cnt >= START_TH))) begin burst <= 1'b1; hs_req_o <= 1'b1; end
      else if (burst && all_enq && cnt_after == 0 && pop) burst <= 1'b0;
      else if (!burst) hs_req_o <= 1'b0;
      if (burst && tx_ready_i && !all_enq && cnt < NLANES) underflow_o <= 1'b1;
    end
  end
endmodule
