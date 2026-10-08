// ***************
// Filename: csi2_rx.sv
// Author: FPGA Cores 4 U
// Description: MIPI CSI-2 receiver, protocol layer. Version 1.0.0. Takes the
//   per-lane HS byte streams of a D-PHY receiver (PPI style: one byte per
//   lane per byte clock, lane_valid high during the HS burst, sync byte
//   already stripped; the analog D-PHY itself is vendor IP) and produces the
//   payload of the selected long packets as an AXI-Stream of NLANES bytes.
//     - Lane deskew: per-lane 8-byte FIFOs absorb up to 7 byte clocks of
//       skew between lanes; lanes are merged byte 0 = lane 0.
//     - Packet header: 6-bit ECC checked; single-bit errors corrected
//       (ecc_corrected_o), multi-bit errors drop the packet (ecc_error_o).
//     - Short packets: frame start / end (data types 0x00 / 0x01) reported.
//     - Long packets with virtual channel vc_i and data type dt_i are
//       streamed; others (embedded data, other VCs) are dropped. The
//       CRC-16 of every long packet is checked (crc_error_o).
//   One packet per HS burst (the usual sensor behaviour); bytes after a
//   packet's checksum up to the end of the burst are ignored.
//   Output - m_axis_tdata byte i is payload byte i of the word, tkeep is
//   contiguous from bit 0, tlast ends each packet (one image line), tuser
//   marks the first word after frame start. There is no back-pressure on
//   a sensor: the output is valid for one clock, and a word not accepted
//   (m_axis_tready low) is lost and flagged on overflow_o - put a FIFO or
//   axis_async_bridge behind this block. Status outputs are one-clock
//   pulses. Clock - byte clock only. Reset - synchronous rst_n (active
//   low). Latency - about 4 byte clocks.
// Date: 2026-10-01
module csi2_rx #(
  parameter int NLANES = 2                     // 1, 2 or 4
) (
  input  logic                  clk,           // D-PHY byte clock
  input  logic                  rst_n,
  // D-PHY PPI receive (HS mode)
  input  logic [NLANES*8-1:0]   lane_data_i,   // byte of lane i in [8i +: 8]
  input  logic [NLANES-1:0]     lane_valid_i,
  // Configuration (change only between frames)
  input  logic [1:0]            vc_i,          // virtual channel to receive
  input  logic [5:0]            dt_i,          // data type to stream, e.g. 0x2B RAW10
  // Payload stream
  output logic [NLANES*8-1:0]   m_axis_tdata,
  output logic [NLANES-1:0]     m_axis_tkeep,
  output logic                  m_axis_tlast,
  output logic                  m_axis_tuser,
  output logic                  m_axis_tvalid,
  input  logic                  m_axis_tready, // only checked for overflow_o
  // Status pulses
  output logic                  frame_start_o,
  output logic                  frame_end_o,
  output logic                  line_o,        // a selected long packet ended
  output logic                  ecc_corrected_o,
  output logic                  ecc_error_o,
  output logic                  crc_error_o,
  output logic                  overflow_o
);
  if (NLANES != 1 && NLANES != 2 && NLANES != 4) begin : g_bad $error("csi2_rx: NLANES must be 1, 2 or 4"); end
  localparam int W = NLANES;

  // ---------------------------------------------------------------- deskew
  // A lane is "done" once its burst has started and ended. A merged word is
  // read when every lane either has a byte or is done.
  logic [7:0] lf_mem [NLANES][8];
  logic [2:0] lf_wp [NLANES], lf_rp [NLANES];
  logic [3:0] lf_cnt [NLANES];
  logic [NLANES-1:0] started, done, nonempty;
  logic [NLANES-1:0] lane_valid_q;

  always_comb for (int i = 0; i < NLANES; i++) nonempty[i] = (lf_cnt[i] != 0);
  wire all_ready = &(nonempty | done);
  wire mw_valid  = all_ready && |nonempty;                     // merged word available
  wire burst_end = &done && !(|nonempty);                      // every lane drained

  logic [W*8-1:0] mw_data; logic [W-1:0] mw_keep;
  always_comb for (int i = 0; i < NLANES; i++) begin
    mw_data[8*i +: 8] = lf_mem[i][lf_rp[i]];
    mw_keep[i]        = nonempty[i];
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < NLANES; i++) begin lf_wp[i] <= '0; lf_rp[i] <= '0; lf_cnt[i] <= '0; end
      started <= '0; done <= '0; lane_valid_q <= '0;
    end else begin
      lane_valid_q <= lane_valid_i;
      for (int i = 0; i < NLANES; i++) begin : lane_fifo
        logic push, pop;
        push = lane_valid_i[i] && lf_cnt[i] != 4'd8;
        pop  = mw_valid && nonempty[i];
        if (push) begin lf_mem[i][lf_wp[i]] <= lane_data_i[8*i +: 8]; lf_wp[i] <= lf_wp[i] + 1'b1; end
        if (pop) lf_rp[i] <= lf_rp[i] + 1'b1;
        lf_cnt[i] <= lf_cnt[i] + {3'd0, push} - {3'd0, pop};
        if (lane_valid_i[i]) started[i] <= 1'b1;
        if (started[i] && !lane_valid_i[i] && lane_valid_q[i]) done[i] <= 1'b1;
      end
      if (burst_end) begin started <= '0; done <= '0; end
    end
  end

  // ---------------------------------------------------------------- header ECC
  // CSI-2 ECC over the 24 header bits {WC[15:8], WC[7:0], DI}; P6 = P7 = 0.
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

  // CRC-16 (x^16 + x^12 + x^5 + 1, LSB first, init 0xFFFF) over one byte
  function automatic logic [15:0] crc_byte(input logic [15:0] c, input logic [7:0] b);
    logic [15:0] r; r = c;
    for (int i = 0; i < 8; i++) r = (r >> 1) ^ ((r[0] ^ b[i]) ? 16'h8408 : 16'h0000);
    crc_byte = r;
  endfunction

  // ---------------------------------------------------------------- packet layer
  // The header is 4 bytes and W divides 4, so a packet's header fills whole
  // words and its payload starts at byte 0 of a word. Each word is handled
  // byte by byte (unrolled), tracking the parser state across the bytes.
  typedef enum logic [2:0] {P_HDR, P_PAY, P_CRC, P_DRAIN} pst_e;
  pst_e pst;
  logic [31:0] hdr; logic [1:0] hcnt;
  logic [15:0] left, crc, crc_rx; logic crc_hi;
  logic        sel, sof_pend;

  // Next-state of one word, computed combinationally
  pst_e n_pst; logic [31:0] n_hdr; logic [1:0] n_hcnt; logic [15:0] n_left, n_crc, n_crc_rx; logic n_crc_hi, n_sel, n_sof;
  logic [W-1:0] o_keep; logic o_last, o_any;
  logic e_fs, e_fe, e_line, e_corr, e_err, e_crc;
  always_comb begin
    logic [23:0] d; logic [5:0] syn, dt; logic [1:0] vc; logic ok; logic [7:0] b;   // per-byte scratch
    d = '0; syn = '0; dt = '0; vc = '0; ok = 1'b0; b = '0;
    n_pst = pst; n_hdr = hdr; n_hcnt = hcnt; n_left = left; n_crc = crc; n_crc_rx = crc_rx; n_crc_hi = crc_hi;
    n_sel = sel; n_sof = sof_pend;
    o_keep = '0; o_last = 1'b0; o_any = 1'b0;
    e_fs = 1'b0; e_fe = 1'b0; e_line = 1'b0; e_corr = 1'b0; e_err = 1'b0; e_crc = 1'b0;
    for (int i = 0; i < W; i++) begin
      b = mw_data[8*i +: 8];
      if (mw_valid && mw_keep[i]) begin
        case (n_pst)
          P_HDR: begin
            n_hdr[8*n_hcnt +: 8] = b;
            if (n_hcnt == 2'd3) begin
              d = n_hdr[23:0]; syn = ecc6(d) ^ n_hdr[29:24]; ok = 1'b1;
              if (syn != 0) begin
                ok = 1'b0;
                for (int k = 0; k < 24; k++) if (syn == ecc6(24'd1 << k)) begin d[k] = ~d[k]; ok = 1'b1; end
                for (int k = 0; k < 6; k++)  if (syn == (6'd1 << k)) ok = 1'b1;     // error in the ECC byte
                if (ok) e_corr = 1'b1; else e_err = 1'b1;
              end
              dt = d[5:0]; vc = d[7:6];
              if (!ok) n_pst = P_DRAIN;
              else if (dt < 6'h10) begin                                        // short packet
                if (vc == vc_i && dt == 6'h00) begin e_fs = 1'b1; n_sof = 1'b1; end
                if (vc == vc_i && dt == 6'h01) e_fe = 1'b1;
                n_pst = P_DRAIN;
              end else begin                                                    // long packet
                n_sel = (vc == vc_i) && (dt == dt_i);
                n_left = d[23:8]; n_crc = 16'hFFFF; n_crc_hi = 1'b0;
                n_pst = pst_e'((d[23:8] == 0) ? P_CRC : P_PAY);
              end
            end
            n_hcnt = n_hcnt + 1'b1;
          end
          P_PAY: begin
            n_crc = crc_byte(n_crc, b);
            if (n_sel) begin o_keep[i] = 1'b1; o_any = 1'b1; end
            n_left = n_left - 1'b1;
            if (n_left == 0) begin o_last = n_sel; n_pst = P_CRC; end
          end
          P_CRC: begin
            if (!n_crc_hi) begin n_crc_rx[7:0] = b; n_crc_hi = 1'b1; end
            else begin
              n_crc_rx[15:8] = b;
              if ({b, n_crc_rx[7:0]} != n_crc) e_crc = 1'b1;
              if (n_sel) e_line = 1'b1;
              n_pst = P_DRAIN;
            end
          end
          default: ;                                                           // P_DRAIN: ignore
        endcase
      end
    end
    if (burst_end) begin
      if (n_pst == P_PAY || n_pst == P_CRC) e_crc = 1'b1;                       // truncated packet
      n_pst = P_HDR; n_hcnt = 2'd0; n_sel = 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pst <= P_HDR; hdr <= '0; hcnt <= '0; left <= '0; crc <= 16'hFFFF; crc_rx <= '0; crc_hi <= 1'b0; sel <= 1'b0; sof_pend <= 1'b0;
      m_axis_tvalid <= 1'b0; m_axis_tdata <= '0; m_axis_tkeep <= '0; m_axis_tlast <= 1'b0; m_axis_tuser <= 1'b0;
      frame_start_o <= 1'b0; frame_end_o <= 1'b0; line_o <= 1'b0; ecc_corrected_o <= 1'b0; ecc_error_o <= 1'b0;
      crc_error_o <= 1'b0; overflow_o <= 1'b0;
    end else begin
      pst <= n_pst; hdr <= n_hdr; hcnt <= n_hcnt; left <= n_left; crc <= n_crc; crc_rx <= n_crc_rx; crc_hi <= n_crc_hi;
      sel <= n_sel; sof_pend <= (o_any) ? 1'b0 : n_sof;
      m_axis_tvalid <= o_any; m_axis_tdata <= mw_data; m_axis_tkeep <= o_keep; m_axis_tlast <= o_last;
      m_axis_tuser  <= o_any && n_sof;
      frame_start_o <= e_fs; frame_end_o <= e_fe; line_o <= e_line;
      ecc_corrected_o <= e_corr; ecc_error_o <= e_err; crc_error_o <= e_crc;
      overflow_o <= m_axis_tvalid && !m_axis_tready;
    end
  end
endmodule
