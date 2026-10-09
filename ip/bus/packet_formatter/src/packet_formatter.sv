// ***************
// Filename: packet_formatter.sv
// Author: FPGA Cores 4 U
// Description: AXI-Stream packet formatter. Version 1.0.0. Builds outgoing
//   packets from a payload stream - a header of HDR_BYTES (sampled from
//   hdr_i when the first payload beat arrives, must be a multiple of the
//   stream width) is prepended, zero pad beats are appended until the
//   packet has at least MIN_BEATS beats, and an optional trailer beat
//   (trailer_i, sampled with the header) can be appended. tlast is moved
//   to the final inserted beat. Padding or a trailer requires the payload
//   length to be a multiple of the stream width (full tkeep on the last
//   payload beat); otherwise align_err_o pulses and the packet is sent
//   without tail. It is the inverse of packet_parser with STRIP=1. Clock -
//   aclk. Reset - synchronous aresetn, idle. Latency - 1 clock to start a
//   packet (header sampling), then one beat per clock; header beats stall
//   the payload input. Errors - align_err_o; misaligned HDR_BYTES rejected
//   at elaboration.
// Date: 2026-09-29
module packet_formatter #(
  parameter int DATA_W    = 32,
  parameter int HDR_BYTES = 8,
  parameter bit TRAILER   = 1'b0,
  parameter int MIN_BEATS = 0
) (
  input  logic                       aclk,
  input  logic                       aresetn,
  input  logic [HDR_BYTES*8-1:0]     hdr_i,
  input  logic [DATA_W-1:0]          trailer_i,
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
  output logic                       align_err_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam int DB = DATA_W / 8;
  localparam int HB = HDR_BYTES / DB;
  if (DATA_W % 8 != 0 || HDR_BYTES < DB || (HDR_BYTES % DB) != 0) begin : g_bad $error("packet_formatter: HDR_BYTES must be a multiple of DATA_W/8"); end
  typedef enum logic [1:0] {S_IDLE, S_HDR, S_PAY, S_TAIL} st_t;
  st_t st;
  logic [HDR_BYTES*8-1:0] hreg;
  logic [DATA_W-1:0] treg;
  logic [$clog2(HB+1)-1:0] hb;
  logic [15:0] beats;
  wire full_keep = &s_axis_tkeep;
  wire tail_wanted = TRAILER || (16'(beats + 1) < MIN_BEATS);
  wire tail_needed = s_axis_tlast & full_keep & tail_wanted;
  wire is_pad   = (16'(beats + (TRAILER ? 1 : 0)) < MIN_BEATS);
  wire last_tail = TRAILER ? ~is_pad : (16'(beats + 1) >= MIN_BEATS);
  always_comb begin
    s_axis_tready = 1'b0;
    m_axis_tvalid = 1'b0;
    m_axis_tdata = '0;
    m_axis_tkeep = '0;
    m_axis_tlast = 1'b0;
    case (st)
      S_HDR: begin
        m_axis_tvalid = 1'b1;
        m_axis_tdata = hreg[hb*DATA_W +: DATA_W];
        m_axis_tkeep = '1;
      end
      S_PAY: begin
        m_axis_tvalid = s_axis_tvalid;
        s_axis_tready = m_axis_tready;
        m_axis_tdata = s_axis_tdata;
        m_axis_tkeep = s_axis_tkeep;
        m_axis_tlast = s_axis_tlast & ~tail_needed;
      end
      S_TAIL: begin
        m_axis_tvalid = 1'b1;
        m_axis_tdata = is_pad ? '0 : treg;
        m_axis_tkeep = '1;
        m_axis_tlast = last_tail;
      end
      default: ;
    endcase
  end
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      st <= S_IDLE;
      hreg <= '0;
      treg <= '0;
      hb <= '0;
      beats <= '0;
      align_err_o <= 1'b0;
    end
    else begin
      align_err_o <= 1'b0;
      case (st)
        S_IDLE: if (s_axis_tvalid) begin
          hreg <= hdr_i;
          treg <= trailer_i;
          hb <= '0;
          beats <= '0;
          st <= S_HDR;
        end
        S_HDR: if (m_axis_tready) begin
          beats <= beats + 1'b1;
          if (hb == HB - 1) st <= S_PAY;
          else hb <= hb + 1'b1;
        end
        S_PAY: if (s_axis_tvalid && m_axis_tready) begin
          beats <= beats + 1'b1;
          if (s_axis_tlast) begin
            if (tail_needed) st <= S_TAIL;
            else begin
              st <= S_IDLE;
              if (tail_wanted && !full_keep) align_err_o <= 1'b1;
            end
          end
        end
        S_TAIL: if (m_axis_tready) begin
          beats <= beats + 1'b1;
          if (last_tail) st <= S_IDLE;
        end
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule
