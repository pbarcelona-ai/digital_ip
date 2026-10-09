// ***************
// Filename: packet_parser.sv
// Author: FPGA Cores 4 U
// Description: AXI-Stream packet parser and filter. Version 1.0.0.
//   Captures the first HDR_BYTES of every packet (HDR_BYTES must be a
//   multiple of the stream width so headers are beat aligned) into hdr_o
//   and pulses hdr_valid_o when the header is complete, then either strips
//   the header (STRIP=1) or forwards it (STRIP=0) and forwards the
//   payload. A run-time filter compares the header with cfg_value_i under
//   cfg_mask_i; with drop_nomatch_i set, packets that do not match are
//   consumed and their payload is discarded (drop_o pulses at the last
//   beat), so only accepted packets reach the master port. With STRIP=0
//   the header beats are forwarded before the match is known and only the
//   payload is filtered. Every packet also reports its byte length (tkeep
//   aware) on len_o / len_valid_o, and packets that end before the header
//   is complete are flagged with runt_o and produce no output. Clock -
//   aclk. Reset - synchronous aresetn, idle, outputs low. Latency - 0
//   clocks (combinational valid/ready pass-through of accepted payload
//   beats); hdr_o and flags are registered, 1 clock after the header's
//   last beat. Errors - runt_o, drop_o; HDR_BYTES not a multiple of
//   DATA_W/8 rejected at elaboration.
// Date: 2026-09-29
module packet_parser #(
  parameter int DATA_W    = 32,
  parameter int HDR_BYTES = 8,
  parameter bit STRIP     = 1'b1
) (
  input  logic                       aclk,
  input  logic                       aresetn,
  input  logic [DATA_W-1:0]          s_axis_tdata,
  input  logic [DATA_W/8-1:0]        s_axis_tkeep,
  input  logic                       s_axis_tlast,
  input  logic                       s_axis_tvalid,
  output logic                       s_axis_tready,
  output logic [DATA_W-1:0]          m_axis_tdata,
  output logic [DATA_W/8-1:0]        m_axis_tkeep,
  output logic                       m_axis_tlast,
  output logic                       m_axis_tvalid,
  input  logic                       m_axis_tready,
  // header and status
  output logic [HDR_BYTES*8-1:0]     hdr_o,
  output logic                       hdr_valid_o,
  output logic                       match_o,
  input  logic [HDR_BYTES*8-1:0]     cfg_mask_i,
  input  logic [HDR_BYTES*8-1:0]     cfg_value_i,
  input  logic                       drop_nomatch_i,
  output logic [15:0]                len_o,
  output logic                       len_valid_o,
  output logic                       runt_o,
  output logic                       drop_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam int DB = DATA_W / 8;
  localparam int HB = HDR_BYTES / DB;
  if (DATA_W % 8 != 0 || HDR_BYTES < DB || (HDR_BYTES % DB) != 0) begin : g_bad $error("packet_parser: HDR_BYTES must be a multiple of DATA_W/8"); end
  logic [$clog2(HB+1)-1:0] hb;
  logic [HDR_BYTES*8-1:0] hreg, hnow;
  logic pass_r, pass_c, match_c;
  logic [15:0] cnt;
  wire in_hdr = (hb < HB);
  wire last_hdr_beat = in_hdr && (hb == HB - 1);
  always_comb begin
    hnow = hreg;
    hnow[hb*DATA_W +: DATA_W] = s_axis_tdata;
    match_c = ((hnow & cfg_mask_i) == (cfg_value_i & cfg_mask_i));
    pass_c  = STRIP ? (~drop_nomatch_i | match_c) : 1'b1;     // filtering only applies when the header is stripped
  end
  wire short_end = s_axis_tlast & in_hdr & (~last_hdr_beat | ~(&s_axis_tkeep));   // packet ended before a full header
  wire pass_now = last_hdr_beat ? pass_c : pass_r;
  // data path (combinational handshake)
  wire fwd_hdr = in_hdr & ~STRIP;
  wire fwd_pay = ~in_hdr & pass_r;
  assign m_axis_tvalid = s_axis_tvalid & (fwd_hdr | fwd_pay);
  assign s_axis_tready = (fwd_hdr | fwd_pay) ? m_axis_tready : 1'b1;
  assign m_axis_tdata  = s_axis_tdata;
  assign m_axis_tkeep = s_axis_tkeep;
  assign m_axis_tlast = s_axis_tlast;
  wire acc = s_axis_tvalid & s_axis_tready;
  wire [15:0] beat_bytes = 16'($countones(s_axis_tkeep));
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      hb <= '0;
      hreg <= '0;
      pass_r <= 1'b1;
      cnt <= '0;
      hdr_o <= '0;
      hdr_valid_o <= 1'b0;
      match_o <= 1'b0;
      len_o <= '0;
      len_valid_o <= 1'b0;
      runt_o <= 1'b0;
      drop_o <= 1'b0;
    end else begin
      hdr_valid_o <= 1'b0;
      len_valid_o <= 1'b0;
      runt_o <= 1'b0;
      drop_o <= 1'b0;
      if (acc) begin
        cnt <= cnt + beat_bytes;
        if (in_hdr) begin
          hreg[hb*DATA_W +: DATA_W] <= s_axis_tdata;
          if (last_hdr_beat && !short_end) begin
            hdr_o <= hnow;
            hdr_valid_o <= 1'b1;
            match_o <= match_c;
            pass_r <= pass_c;
            hb <= HB[$clog2(HB+1)-1:0];
          end else hb <= hb + 1'b1;
          if (short_end) runt_o <= 1'b1;
        end
        if (s_axis_tlast) begin
          hb <= '0;
          pass_r <= 1'b1;
          cnt <= '0;
          if (!short_end) begin
            len_o <= cnt + beat_bytes;
            len_valid_o <= 1'b1;
          end
          if (!pass_now && !short_end) drop_o <= 1'b1;
        end
      end
    end
  end
endmodule
